---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocr_core: register file, key load through the registers, encryption and decryption
-- against pycryptodome with keys of several slots, generated IVs, context errors, zeroize, error
-- injection with the EDAC monitor, interrupt, throughput, reset, and two cores in series; with
-- DenseOutput_g the same tests with the dense output.
--
-- Documentation: hdl/ocr_core/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library uvvm_vvc_framework;
    use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

library bitvis_vip_axilite;
    context bitvis_vip_axilite.vvc_context;

library vunit_lib;
    context vunit_lib.vunit_run_context;

library work;
    use work.ocr_pkg.all;
    use work.ocr_regs_pkg.all;
    use work.ocr_tb_pkg.all;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;
    use work.ocr_tb_axi_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_core_tb is
    generic (
        runner_cfg      : string;
        DataWidth_g     : positive := 32;
        KeyBits_g       : positive := 256;
        NumKeys_g       : positive := 4;
        ReleaseBuffer_g : boolean  := false;
        ReleaseBytes_g  : positive := 4096;
        DenseOutput_g   : boolean  := false;
        Series_g        : boolean  := false;
        VecDir_g        : string
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_core_tb is

    constant ClkPeriod_c : time    := 10 ns;
    constant A_c         : natural := 0;
    constant B_c         : natural := 1;
    -- Core A: message source, context source, message sink, status sink; core B: channels 4 to 6
    constant All_c       : std_logic_vector(TbChannels_c - 1 downto 0) := x"0F";
    constant Series_c    : std_logic_vector(TbChannels_c - 1 downto 0) := x"7B";
    constant MaxGaps_c   : natural                                     := 40;
    constant Units_c     : natural                                     := aesDefaultUnits(KeyBits_g, DataWidth_g);
    constant Digit_c     : natural                                     := ghashDefaultDigit(DataWidth_g);

    signal Clk  : std_logic;
    signal Rst  : std_logic := '1';
    signal IrqA : std_logic;

begin

    test_runner_watchdog(runner, 50 ms);

    p_main : process is
        variable D_v    : std_logic_vector(31 downto 0);
        variable Sts_v  : std_logic_vector(31 downto 0);
        variable Fix_v  : std_logic_vector(31 downto 0);
        variable Cnt_v  : std_logic_vector(63 downto 0);
        variable N_v    : natural;
        variable Gen_v  : natural;
        variable M_v    : natural;
        variable Sec_v  : natural;
        variable Ded_v  : natural;
        variable Span_v : natural;
        variable T_v    : time;

        procedure syncClk is
        begin
            wait until rising_edge(Clk);
            wait for 1 ns;
        end procedure;

        -- Waits for the erasure of the key table after the reset
        procedure waitIdle (idx : natural) is
        begin

            loop
                regRead(AXILITE_VVCT, idx, RegStatus_c, D_v);
                exit when D_v(StatusBusy_c) = '0';
            end loop;

        end procedure;

        -- Number of messages of set 0 with a status code (and a direction for code 0)
        impure function countCode (
            code : natural;
            dec  : integer := -1) return natural is
            variable R_v : natural := 0;
        begin

            for m in 0 to OcrVec_v.msgCount(0) - 1 loop
                if OcrVec_v.stsCode(0, m) = code and
                   (dec < 0 or (dec = 1) = OcrVec_v.msgDec(0, m)) then
                    R_v := R_v + 1;
                end if;
            end loop;

            return R_v;
        end function;

        -- Dense output: the output beats that the packing saves (sectioned minus dense beats) plus one beat per
        -- message (the packer may stall its input for the last beat of a message), computed from the expected sections
        impure function packSlack return natural is
            variable R_v   : natural := 0;
            variable Sec_v : natural;
            variable Tot_v : natural;
        begin
            if not DenseOutput_g then
                return 0;
            end if;

            for m in 0 to OcrVec_v.msgCount(0) - 1 loop
                Sec_v := 0;
                Tot_v := 0;

                for s in 0 to OcrVec_v.outCount(0, m) - 1 loop
                    Sec_v := Sec_v + tbBeats(OcrVec_v.outLen(0, m, s), DataWidth_g / 8);
                    Tot_v := Tot_v + OcrVec_v.outLen(0, m, s);
                end loop;

                R_v := R_v + Sec_v - tbBeats(Tot_v, DataWidth_g / 8) + 1;
            end loop;

            return R_v;
        end function;

        -- All messages of a vector file through core A, with its keys loaded through the registers
        procedure runSet (
            name  : string;
            stall : real;
            load  : boolean := true) is
        begin
            tbLoad(0, VecDir_g & "/" & name);
            if load then
                regLoadAll(AXILITE_VVCT, A_c, 0, KeyBits_g);
            end if;

            for ch in 0 to 3 loop
                tbSetStall(0, ch, stall);
                OcrVec_v.clearStats(0, ch);
            end loop;

            OcrVec_v.setSkipFailed(0, ChSink_c, ReleaseBuffer_g);
            tbStart(0, All_c);
            tbWaitDone(0, ChSink_c, 10 ms, name);
            tbWaitDone(0, ChSts_c, 10 ms, name);
            N_v := OcrVec_v.msgCount(0);
            check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "messages checked at the output of " & name);
            check_value(OcrVec_v.cursor(0, ChSts_c), N_v, ERROR, "status checked of " & name);
        end procedure;

        -- Throughput measurement: the messages of a vector file without stall cycles; Span_v is the number of cycles of
        -- channel ch (the output of encryptions, the input of decryptions) from the last beat of the first message to
        -- the last beat of the last message
        procedure measureSet (
            name : string;
            ch   : natural) is
        begin
            tbLoad(0, VecDir_g & "/" & name);
            regLoadAll(AXILITE_VVCT, A_c, 0, KeyBits_g);

            for c in 0 to 3 loop
                tbSetStall(0, c, 0.0);
                OcrVec_v.clearStats(0, c);
            end loop;

            tbStart(0, All_c);

            while OcrVec_v.cursor(0, ch) < 1 loop
                syncClk;
            end loop;

            -- The last beat of the first message was in the cycle before
            OcrVec_v.clearStats(0, ch);
            T_v    := now - 1 ns;
            tbWaitDone(0, ChSink_c, 10 ms, name);
            tbWaitDone(0, ChSts_c, 10 ms, name);
            N_v    := OcrVec_v.msgCount(0);
            check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "messages checked at the output of " & name);
            check_value(OcrVec_v.cursor(0, ChSts_c), N_v, ERROR, "status checked of " & name);
            T_v    := OcrVec_v.lastTime(0, ch) - T_v;
            Span_v := T_v / ClkPeriod_c;
        end procedure;

        -- Beats of message m in the input sections (input) or in the sectioned output sections (output)
        impure function msgBeats (
            m    : natural;
            what : string) return natural is
            variable R_v : natural := 0;
        begin
            if what = "input" then

                for s in 0 to OcrVec_v.inCount(0, m) - 1 loop
                    R_v := R_v + tbBeats(OcrVec_v.inLen(0, m, s), DataWidth_g / 8);
                end loop;

            else

                for s in 0 to OcrVec_v.outCount(0, m) - 1 loop
                    R_v := R_v + tbBeats(OcrVec_v.outLen(0, m, s), DataWidth_g / 8);
                end loop;

            end if;
            return R_v;
        end function;

        -- Output cycles of encryption m in a back-to-back sequence (CO-PF-03): its sectioned output beats; with the
        -- dense output one more when its last beat does not fit into the output beat with the bytes before it
        impure function outCycles (m : natural) return natural is
            constant Bytes_c : positive := DataWidth_g / 8;
            variable Res_v   : natural  := 0;
            variable Tot_v   : natural  := 0;
            variable Len_v   : natural;
        begin

            for s in 0 to OcrVec_v.outCount(0, m) - 1 loop
                Len_v := OcrVec_v.outLen(0, m, s);

                for b in 0 to tbBeats(Len_v, Bytes_c) - 1 loop
                    Tot_v := Res_v + minimum(Bytes_c, Len_v - b * Bytes_c);
                    Res_v := Tot_v mod Bytes_c;
                end loop;

            end loop;

            if DenseOutput_g and Tot_v > Bytes_c then
                return msgBeats(m, "output") + 1;
            end if;
            return msgBeats(m, "output");
        end function;

        -- Release buffer (CO-PF-04): bound of the cycles of message m at the bottleneck side (B beats there, the
        -- output of an encryption or the input of a decryption), M sectioned output beats in a buffer of D beats:
        -- max(B + 2, 3 M - D + 4)
        impure function relCycles (m : natural) return natural is
            constant D_c : natural := ReleaseBytes_g / (DataWidth_g / 8);
            variable B_v : natural;
            variable M_v : natural;
        begin
            M_v := msgBeats(m, "output");
            if OcrVec_v.msgDec(0, m) then
                B_v := msgBeats(m, "input");
            else
                B_v := outCycles(m);
            end if;
            if 3 * M_v + 4 > D_c + B_v + 2 then
                return 3 * M_v + 4 - D_c;
            end if;
            return B_v + 2;
        end function;

        -- Sum over the messages after the first one of the expected cycles (ivgen) or of the bound of the release
        -- buffer (release)
        impure function sumCycles (what : string) return natural is
            variable R_v : natural := 0;
        begin

            for m in 1 to OcrVec_v.msgCount(0) - 1 loop
                if what = "release" then
                    R_v := R_v + relCycles(m);
                else
                    R_v := R_v + outCycles(m);
                end if;
            end loop;

            return R_v;
        end function;

        procedure checkCounter (
            addr : natural;
            n    : natural;
            msg  : string) is
        begin
            regCheck(AXILITE_VVCT, A_c, addr, std_logic_vector(to_unsigned(n, 32)), msg);
        end procedure;

        -- The invocation counters of the generator slots after the messages of set 0
        procedure checkIvCounters is
        begin

            for k in 0 to OcrVec_v.keyCount(0) - 1 loop
                if OcrVec_v.keyIvGen(0, k) then
                    Gen_v := 0;

                    for m in 0 to OcrVec_v.msgCount(0) - 1 loop
                        if OcrVec_v.msgSlot(0, m) = OcrVec_v.keySlot(0, k) and OcrVec_v.msgIvGen(0, m) and
                           OcrVec_v.stsCode(0, m) = 0 then
                            Gen_v := Gen_v + 1;
                        end if;
                    end loop;

                    regQuery(AXILITE_VVCT, A_c, OcrVec_v.keySlot(0, k), Sts_v, Fix_v, Cnt_v);
                    check_value(Sts_v(SlotStatusValid_c), '1', ERROR, "slot valid");
                    check_value(Cnt_v, std_logic_vector(unsigned(OcrVec_v.keyCounter(0, k)) + Gen_v), ERROR,
                                "invocation counter of slot " & to_string(OcrVec_v.keySlot(0, k)));
                end if;
            end loop;

        end procedure;

    -- Test sequence
    begin
        test_runner_setup(runner, runner_cfg);
        await_uvvm_initialization(VOID);
        disable_log_msg(ALL_MESSAGES);
        enable_log_msg(ID_LOG_HDR);
        enable_log_msg(ID_SEQUENCER);
        shared_axilite_vvc_config(A_c).bfm_config.max_wait_cycles := 10000;
        if Series_g then
            shared_axilite_vvc_config(B_c).bfm_config.max_wait_cycles := 10000;
        end if;
        wait for 5 * ClkPeriod_c;
        syncClk;
        Rst <= '0';
        waitIdle(A_c);

        if run("test_registers") then
            -- MG-1: identification, generics, reset values, write-only registers
            regCheck(AXILITE_VVCT, A_c, RegId_c, RegMapId_c, "ID");
            D_v                                                         := (others => '0');
            D_v(GenericsDataBytesHi_c downto GenericsDataBytesLo_c)     := std_logic_vector(to_unsigned(DataWidth_g / 8, 5));
            D_v(GenericsKeyBitsHi_c downto GenericsKeyBitsLo_c)         := std_logic_vector(to_unsigned(KeyBits_g, 9));
            D_v(GenericsNumKeysHi_c downto GenericsNumKeysLo_c)         := std_logic_vector(to_unsigned(NumKeys_g, 9));
            D_v(GenericsRelease_c)                                      := tbSl(ReleaseBuffer_g);
            D_v(GenericsAesUnitsHi_c downto GenericsAesUnitsLo_c)       := std_logic_vector(to_unsigned(Units_c, 4));
            D_v(GenericsDense_c)                                        := tbSl(DenseOutput_g);
            regCheck(AXILITE_VVCT, A_c, RegGenerics_c, D_v, "GENERICS");
            D_v                                                         := (others => '0');
            D_v(Generics2GhashDigitHi_c downto Generics2GhashDigitLo_c) := std_logic_vector(to_unsigned(Digit_c, 8));
            D_v(Generics2LenBitsHi_c downto Generics2LenBitsLo_c)       := std_logic_vector(to_unsigned(32, 6));
            regCheck(AXILITE_VVCT, A_c, RegGenerics2_c, D_v, "GENERICS2");
            if ReleaseBuffer_g then
                regCheck(AXILITE_VVCT, A_c, RegReleaseBytes_c, std_logic_vector(to_unsigned(ReleaseBytes_g, 32)),
                         "RELEASE_BYTES");
            else
                regCheck(AXILITE_VVCT, A_c, RegReleaseBytes_c, x"00000000", "RELEASE_BYTES");
            end if;
            regCheck(AXILITE_VVCT, A_c, RegEvents_c, x"00000000", "EVENTS after the reset");
            regCheck(AXILITE_VVCT, A_c, RegIrqEn_c, x"00000000", "IRQ_EN after the reset");
            regWrite(AXILITE_VVCT, A_c, RegIrqEn_c, x"000007FF");
            regCheck(AXILITE_VVCT, A_c, RegIrqEn_c, x"000007FF", "IRQ_EN");
            -- Keys and IV fields can never be read
            regWrite(AXILITE_VVCT, A_c, RegKeyBase_c, x"01234567");
            regWrite(AXILITE_VVCT, A_c, RegIvFixed_c, x"89ABCDEF");
            regCheck(AXILITE_VVCT, A_c, RegKeyBase_c, x"00000000", "KEY0 reads as zero");
            regCheck(AXILITE_VVCT, A_c, RegIvFixed_c, x"00000000", "IV_FIXED reads as zero");

            for c in 0 to 9 loop
                checkCounter(RegEncryptions_c + 4 * c, 0, "counter " & to_string(c) & " after the reset");
            end loop;

        elsif run("test_key_load") then
            -- KT-2 through MG-1: load, LOAD_DONE, slot query; an unloaded slot is invalid
            tbLoad(0, VecDir_g & "/mixed.txt");
            regLoadAll(AXILITE_VVCT, A_c, 0, KeyBits_g);
            regRead(AXILITE_VVCT, A_c, RegEvents_c, D_v);
            check_value(D_v(EventsLoadDone_c), '1', ERROR, "LOAD_DONE event");

            for k in 0 to OcrVec_v.keyCount(0) - 1 loop
                regQuery(AXILITE_VVCT, A_c, OcrVec_v.keySlot(0, k), Sts_v, Fix_v, Cnt_v);
                check_value(Sts_v(SlotStatusValid_c), '1', ERROR, "slot valid");
                check_value(Sts_v(SlotStatusIvGen_c), tbSl(OcrVec_v.keyIvGen(0, k)), ERROR, "IV construction");
                check_value(Fix_v, OcrVec_v.keyFixed(0, k), ERROR, "fixed field");
                check_value(Cnt_v, OcrVec_v.keyCounter(0, k), ERROR, "invocation counter");
            end loop;

            regQuery(AXILITE_VVCT, A_c, NumKeys_g - 1, Sts_v, Fix_v, Cnt_v);
            if NumKeys_g > OcrVec_v.keyCount(0) then
                check_value(Sts_v(SlotStatusValid_c), '0', ERROR, "unloaded slot invalid");
            end if;
            regQuery(AXILITE_VVCT, A_c, 255, Sts_v, Fix_v, Cnt_v);
            if NumKeys_g < 256 then
                check_value(Sts_v(SlotStatusValid_c), '0', ERROR, "slot beyond the key table invalid");
            end if;

        elsif run("test_messages") then
            -- GCM-AE and GCM-AD of messages with keys of several slots; counters per status code
            runSet("mixed.txt", 0.2);
            checkCounter(RegEncryptions_c, countCode(0, 0), "ENCRYPTIONS");
            checkCounter(RegDecryptions_c, countCode(0, 1), "DECRYPTIONS");
            checkCounter(RegErrAuth_c, countCode(1), "ERR_AUTH");
            if countCode(1) > 0 then
                regRead(AXILITE_VVCT, A_c, RegEvents_c, D_v);
                check_value(D_v(EventsAuth_c), '1', ERROR, "AUTH event");
            end if;

        elsif run("test_iv_generation") then
            -- KT-4: generated IVs in front of the AAD; the invocation counters advance
            runSet("ivgen.txt", 0.2);
            checkIvCounters;
            checkCounter(RegEncryptions_c, OcrVec_v.msgCount(0), "ENCRYPTIONS");

        elsif run("test_context_errors") then
            -- KT-3: unloaded slot, slot out of range, wrong IV source, exhausted invocation counter
            runSet("errors.txt", 0.1);
            checkCounter(RegErrKey_c, countCode(3), "ERR_KEY");
            checkCounter(RegErrIvMode_c, countCode(4), "ERR_IV_MODE");
            checkCounter(RegErrIvExhausted_c, countCode(5), "ERR_IV_EXHAUSTED");
            regRead(AXILITE_VVCT, A_c, RegEvents_c, D_v);
            check_value(D_v(EventsIvMode_c), '1', ERROR, "IV_MODE event");
            check_value(D_v(EventsIvExhausted_c), '1', ERROR, "IV_EXHAUSTED event");
            regQuery(AXILITE_VVCT, A_c, 1, Sts_v, Fix_v, Cnt_v);
            check_value(Sts_v(SlotStatusExhausted_c), '1', ERROR, "slot 1 exhausted");

        elsif run("test_zeroize") then
            -- KT-1: zeroize erases every slot; messages fail with KEY; a new load works
            tbLoad(0, VecDir_g & "/mixed.txt");
            regLoadAll(AXILITE_VVCT, A_c, 0, KeyBits_g);
            regWrite(AXILITE_VVCT, A_c, RegCtrl_c, x"00000001");
            waitIdle(A_c);

            for k in 0 to OcrVec_v.keyCount(0) - 1 loop
                regQuery(AXILITE_VVCT, A_c, OcrVec_v.keySlot(0, k), Sts_v, Fix_v, Cnt_v);
                check_value(Sts_v(SlotStatusValid_c), '0', ERROR, "slot erased");
                check_value(Cnt_v, (63 downto 0 => '0'), ERROR, "counter erased");
            end loop;

            runSet("zeroized.txt", 0.0, false);
            checkCounter(RegErrKey_c, OcrVec_v.msgCount(0), "ERR_KEY");
            runSet("mixed.txt", 0.1);

        elsif run("test_ecc") then
            -- MG-2: single and double errors in every buffer of the data path through ECC_INJECT
            tbLoad(0, VecDir_g & "/ecc.txt");
            regLoadAll(AXILITE_VVCT, A_c, 0, KeyBits_g);
            OcrVec_v.setSkipFailed(0, ChSink_c, ReleaseBuffer_g);
            N_v := OcrVec_v.msgCount(0);
            -- Stall cycles at the outputs: an error is counted once, also while its entry waits
            tbSetStall(0, ChSink_c, 0.5);
            tbSetStall(0, ChSts_c, 0.5);

            for m in 0 to N_v - 1 loop
                D_v                                                 := (others => '0');
                D_v(EccInjectTargetHi_c downto EccInjectTargetLo_c) := std_logic_vector(to_unsigned(m / 4, 5));
                if m mod 2 = 0 then
                    D_v(EccInjectSingle_c) := '1';
                else
                    D_v(EccInjectDouble_c) := '1';
                end if;
                regWrite(AXILITE_VVCT, A_c, RegEccInject_c, D_v);
                tbStart(0, All_c, m + 1);
                tbWaitDone(0, ChSink_c, 1 ms, "message " & to_string(m));
                tbWaitDone(0, ChSts_c, 1 ms, "status " & to_string(m));
            end loop;

            -- Every buffer counted one single and one double error per direction
            for c in 0 to N_v / 4 - 1 loop
                regWrite(AXILITE_VVCT, A_c, RegEccSelect_c, std_logic_vector(to_unsigned(c, 32)));
                regCheck(AXILITE_VVCT, A_c, RegEccCount_c, x"00020002", "SEC and DED count of channel " & to_string(c));
            end loop;

            regRead(AXILITE_VVCT, A_c, RegEccStatus_c, D_v);
            check_value(D_v(N_v / 4 - 1 downto 0), (N_v / 4 - 1 downto 0 => '1'), ERROR, "DED flags");
            regRead(AXILITE_VVCT, A_c, RegEvents_c, D_v);
            check_value(D_v(EventsEccSec_c), '1', ERROR, "ECC_SEC event");
            check_value(D_v(EventsEccDed_c), '1', ERROR, "ECC_DED event");
            -- Any write to ECC_STATUS clears the monitor
            regWrite(AXILITE_VVCT, A_c, RegEccStatus_c, x"00000000");
            regCheck(AXILITE_VVCT, A_c, RegEccStatus_c, x"00000000", "DED flags cleared");
            regWrite(AXILITE_VVCT, A_c, RegEccSelect_c, x"00000000");
            regCheck(AXILITE_VVCT, A_c, RegEccCount_c, x"00000000", "counts cleared");

        elsif run("test_ecc_key_table") then
            -- MG-2 and KT-1 through the core: single and double errors in the key, H and IV word of a load and in a job
            tbLoad(0, VecDir_g & "/kt_ecc.txt");

            for m in 0 to 7 loop
                D_v                                                 := (others => '0');
                D_v(EccInjectTargetHi_c downto EccInjectTargetLo_c) := std_logic_vector(to_unsigned(16 + m / 2, 5));
                if m mod 2 = 0 then
                    D_v(EccInjectSingle_c) := '1';
                else
                    D_v(EccInjectDouble_c) := '1';
                end if;
                if m / 2 = 3 then
                    -- Job FIFO: the error goes into the job of the next message
                    regLoadKey(AXILITE_VVCT, A_c, 0, 0, KeyBits_g);
                    regWrite(AXILITE_VVCT, A_c, RegEccInject_c, D_v);
                else
                    -- Memories: the error goes into the word that the next load writes
                    regWrite(AXILITE_VVCT, A_c, RegEccInject_c, D_v);
                    regLoadKey(AXILITE_VVCT, A_c, 0, 0, KeyBits_g);
                end if;
                tbStart(0, All_c, m + 1);
                tbWaitDone(0, ChSink_c, 1 ms, "message " & to_string(m));
                tbWaitDone(0, ChSts_c, 1 ms, "status " & to_string(m));
            end loop;

            -- Key, H and IV memory: the error is found by the read (channels 11 to 13) or by the scrubber (14 to 16)
            for w in 0 to 2 loop
                Sec_v := 0;
                Ded_v := 0;

                for c in 0 to 1 loop
                    regWrite(AXILITE_VVCT, A_c, RegEccSelect_c, std_logic_vector(to_unsigned(11 + w + 3 * c, 32)));
                    regRead(AXILITE_VVCT, A_c, RegEccCount_c, D_v);
                    Sec_v := Sec_v + to_integer(unsigned(D_v(EccCountSecHi_c downto EccCountSecLo_c)));
                    Ded_v := Ded_v + to_integer(unsigned(D_v(EccCountDedHi_c downto EccCountDedLo_c)));
                end loop;

                check_value(Sec_v >= 1, ERROR, "single error of key table memory " & to_string(w));
                check_value(Ded_v >= 1, ERROR, "double error of key table memory " & to_string(w));
            end loop;

            regWrite(AXILITE_VVCT, A_c, RegEccSelect_c, std_logic_vector(to_unsigned(17, 32)));
            regCheck(AXILITE_VVCT, A_c, RegEccCount_c, x"00010001", "SEC and DED count of the job FIFO");
            regRead(AXILITE_VVCT, A_c, RegEccStatus_c, D_v);
            check_value(D_v(17), '1', ERROR, "DED flag of the job FIFO");
            checkCounter(RegErrEcc_c, 4, "ERR_ECC");
            checkCounter(RegEncryptions_c, 4, "ENCRYPTIONS");

        elsif run("test_irq") then
            -- MG-1: an enabled event drives Irq until it is cleared
            tbLoad(0, VecDir_g & "/mixed.txt");
            regLoadAll(AXILITE_VVCT, A_c, 0, KeyBits_g);
            check_value(IrqA, '0', ERROR, "no interrupt without enable");
            regWrite(AXILITE_VVCT, A_c, RegIrqEn_c, std_logic_vector(to_unsigned(2 ** EventsLoadDone_c, 32)));
            syncClk;
            syncClk;
            check_value(IrqA, '1', ERROR, "interrupt of LOAD_DONE");
            regCheck(AXILITE_VVCT, A_c, RegIrqStatus_c, x"00000001", "IRQ_STATUS");
            regWrite(AXILITE_VVCT, A_c, RegEvents_c, std_logic_vector(to_unsigned(2 ** EventsLoadDone_c, 32)));
            syncClk;
            syncClk;
            check_value(IrqA, '0', ERROR, "interrupt cleared");

        elsif run("test_throughput_encrypt") then
            -- Back-to-back encryptions through the core: the output transfers a beat in every cycle
            runSet("tp_enc.txt", 0.0);
            log(ID_SEQUENCER, "output beats " & to_string(OcrVec_v.beats(0, ChSink_c)) & ", gaps " &
                to_string(OcrVec_v.gaps(0, ChSink_c)) & ", slack of the dense output " & to_string(packSlack));
            -- The release buffer stalls its read side one cycle per message (CO-PF-04)
            if ReleaseBuffer_g then
                N_v := MaxGaps_c + packSlack + OcrVec_v.msgCount(0);
            else
                N_v := MaxGaps_c + packSlack;
            end if;
            check_value(OcrVec_v.gaps(0, ChSink_c) <= N_v, ERROR, "cycles without output beat");

        elsif run("test_throughput_decrypt") then
            -- Back-to-back decryptions through the core: the input accepts a beat in every cycle
            runSet("tp_dec.txt", 0.0);
            log(ID_SEQUENCER, "input beats " & to_string(OcrVec_v.beats(0, ChSource_c)) & ", gaps " &
                to_string(OcrVec_v.gaps(0, ChSource_c)));
            -- The dense output stalls at most one cycle per message
            if DenseOutput_g then
                N_v := MaxGaps_c + OcrVec_v.msgCount(0);
            else
                N_v := MaxGaps_c;
            end if;
            check_value(OcrVec_v.gaps(0, ChSource_c) <= N_v, ERROR, "cycles without input beat");

        elsif run("test_throughput_release") then

            -- Release buffer: back-to-back messages of half the buffer and longer, encryptions at the output and
            -- decryptions at the input; every message takes at most max(B + 2, 3 M - D + 4) cycles
            for f in 0 to 3 loop

                case f is
                    when 0 => measureSet("rel_enc_half.txt", ChSink_c);
                    when 1 => measureSet("rel_enc_long.txt", ChSink_c);
                    when 2 => measureSet("rel_dec_half.txt", ChSource_c);
                    when others => measureSet("rel_dec_long.txt", ChSource_c);
                end case;

                log(ID_SEQUENCER, "set " & to_string(f) & ": sectioned output beats of a message " &
                    to_string(msgBeats(0, "output")) & ", input beats " & to_string(msgBeats(0, "input")) &
                    ", buffer beats " & to_string(ReleaseBytes_g / (DataWidth_g / 8)) & ", cycles after the first " &
                    "message " & to_string(Span_v) & ", bound " & to_string(sumCycles("release")));
                check_value(Span_v <= sumCycles("release"), ERROR, "cycles of the messages after the first one");
            end loop;

        elsif run("test_throughput_ivgen") then

            -- Back-to-back encryptions with generated IVs of the shape of framer chunks (4 bytes of AAD): after the first
            -- message every message takes exactly its output beats, plus the extra beat of the packer
            for f in 0 to 1 loop
                if f = 0 then
                    measureSet("chunk_256.txt", ChSink_c);
                else
                    measureSet("chunk_1024.txt", ChSink_c);
                end if;
                log(ID_SEQUENCER, "set " & to_string(f) & ": output beats of a message " &
                    to_string(msgBeats(0, "output")) & ", cycles after the first message " & to_string(Span_v) &
                    ", expected " & to_string(sumCycles("ivgen")));
                check_value(Span_v, sumCycles("ivgen"), ERROR, "cycles of the messages after the first one");
            end loop;

        elsif run("test_reset") then
            -- A reset while messages are in the core erases the keys; after a new load the messages are correct
            tbLoad(0, VecDir_g & "/mixed.txt");
            regLoadAll(AXILITE_VVCT, A_c, 0, KeyBits_g);
            N_v := OcrVec_v.msgCount(0);
            tbStart(0, All_c);

            for i in 0 to 300 loop
                syncClk;
            end loop;

            for ch in 0 to 3 loop
                OcrVec_v.setLimit(0, ch, OcrVec_v.cursor(0, ch) + 1);
                OcrVec_v.setAbort(0, ch);
            end loop;

            Rst <= '1';
            syncClk;
            syncClk;
            Rst <= '0';
            waitIdle(A_c);
            regQuery(AXILITE_VVCT, A_c, OcrVec_v.keySlot(0, 0), Sts_v, Fix_v, Cnt_v);
            check_value(Sts_v(SlotStatusValid_c), '0', ERROR, "keys erased by the reset");
            regLoadAll(AXILITE_VVCT, A_c, 0, KeyBits_g);
            M_v := OcrVec_v.cursor(0, ChSource_c);

            for ch in 0 to 3 loop
                OcrVec_v.setCursor(0, ch, M_v);
                OcrVec_v.clearAbort(0, ch);
            end loop;

            tbStart(0, All_c);
            tbWaitDone(0, ChSink_c, 10 ms, "messages after the reset");
            tbWaitDone(0, ChSts_c, 10 ms, "messages after the reset");
            check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "messages after the reset");

        elsif run("test_series") then
            -- Two cores in series: core B decrypts the output of core A and gives back the input of core A
            tbLoad(0, VecDir_g & "/series.txt");
            regLoadAll(AXILITE_VVCT, A_c, 0, KeyBits_g);
            regLoadAll(AXILITE_VVCT, B_c, 0, KeyBits_g);
            tbSetStall(0, ChSource_c, 0.1);
            tbSetStall(0, 5, 0.2);
            tbStart(0, Series_c);
            tbWaitDone(0, 5, 10 ms, "decrypted messages");
            tbWaitDone(0, 6, 10 ms, "status of core B");
            tbWaitDone(0, ChSts_c, 10 ms, "status of core A");
            check_value(OcrVec_v.cursor(0, 5), OcrVec_v.msgCount(0), ERROR, "messages of core B");
            regCheck(AXILITE_VVCT, B_c, RegDecryptions_c, std_logic_vector(to_unsigned(OcrVec_v.msgCount(0), 32)),
                     "DECRYPTIONS of core B");
        end if;

        ocrTestEnd(runner);
        wait;
    end process;

    i_th : entity work.ocr_core_th
        generic map (
            DataWidth_g     => DataWidth_g,
            KeyBits_g       => KeyBits_g,
            NumKeys_g       => NumKeys_g,
            ReleaseBuffer_g => ReleaseBuffer_g,
            ReleaseBytes_g  => ReleaseBytes_g,
            DenseOutput_g   => DenseOutput_g,
            Series_g        => Series_g
        )
        port map (
            Clk  => Clk,
            Rst  => Rst,
            IrqA => IrqA
        );

end architecture;
