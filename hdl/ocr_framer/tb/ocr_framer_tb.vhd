---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocr_framer: chunks and their positions, contexts, back-pressure, throughput, error
-- injection and reset of the framer alone, and the encryption of packets by the framer and ocr_core
-- with the dense output against pycryptodome.
--
-- Documentation: hdl/ocr_framer/docs/verification_plan.md

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
entity ocr_framer_tb is
    generic (
        runner_cfg     : string;
        DataWidth_g    : positive := 32;
        KeyBits_g      : positive := 256;
        NumKeys_g      : positive := 4;
        ChunkBytes_g   : positive := 64;
        BufferChunks_g : positive := 2;
        Core_g         : boolean  := false;
        VecDir_g       : string
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_framer_tb is

    constant ClkPeriod_c : time     := 10 ns;
    constant Bytes_c     : positive := DataWidth_g / 8;
    constant SlotBits_c  : positive := slotBits(NumKeys_g);
    constant AadBeats_c  : positive := (4 + Bytes_c - 1) / Bytes_c;
    -- Framer and core: cycles of the initial latency without beat (the bound of ocr_core)
    constant Latency_c   : natural := 40;
    -- Framer alone: message source, context checker, message sink; with the core: source, message and status sink
    constant Alone_c     : std_logic_vector(TbChannels_c - 1 downto 0) := x"07";
    constant WithCore_c  : std_logic_vector(TbChannels_c - 1 downto 0) := x"0D";

    signal Clk            : std_logic;
    signal Rst            : std_logic                                 := '1';
    signal CfgSlot        : std_logic_vector(SlotBits_c - 1 downto 0) := (others => '0');
    signal ErrInj_Sel     : std_logic                                 := '0';
    signal ErrInj_BitFlip : std_logic_vector(1 downto 0)              := (others => '0');
    signal ErrInj_Valid   : std_logic                                 := '0';
    signal Ecc_Sec        : std_logic_vector(1 downto 0);
    signal Ecc_Ded        : std_logic_vector(1 downto 0);

    type CntArr_t is array (0 to 1) of natural;

    signal SecCnt : CntArr_t := (others => 0);
    signal DedCnt : CntArr_t := (others => 0);

begin

    test_runner_watchdog(runner, 50 ms);

    -- ECC events per buffer
    p_ecc : process (Clk) is
    begin
        if rising_edge(Clk) then

            for b in 0 to 1 loop
                if Ecc_Sec(b) = '1' then
                    SecCnt(b) <= SecCnt(b) + 1;
                end if;
                if Ecc_Ded(b) = '1' then
                    DedCnt(b) <= DedCnt(b) + 1;
                end if;
            end loop;

        end if;
    end process;

    p_main : process is
        variable N_v   : natural;
        variable M_v   : natural;
        variable Sts_v : std_logic_vector(31 downto 0);
        variable Fix_v : std_logic_vector(31 downto 0);
        variable Cnt_v : std_logic_vector(63 downto 0);
        variable T_v   : time;

        -- The sequencer acts 1 ns after the clock edge, after the models
        procedure syncClk is
        begin
            wait until rising_edge(Clk);
            wait for 1 ns;
        end procedure;

        impure function models return std_logic_vector is
        begin
            if Core_g then
                return WithCore_c;
            end if;
            return Alone_c;
        end function;

        -- Checks that every message of the set was received (and with the core its status; without it its context)
        procedure checkDone (name : string) is
        begin
            N_v := OcrVec_v.msgCount(0);
            check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "messages checked at the output of " & name);
            if Core_g then
                tbWaitDone(0, ChSts_c, 10 ms, name);
                check_value(OcrVec_v.cursor(0, ChSts_c), N_v, ERROR, "status checked of " & name);
            else
                check_value(OcrVec_v.beats(0, ChCtx_c), N_v, ERROR, "contexts of " & name);
            end if;
        end procedure;

        -- All packets of a vector file with stall probabilities at the input, at the outputs and at the contexts
        procedure runSet (
            name     : string;
            stallIn  : real;
            stallOut : real;
            stallCtx : real    := 0.0;
            load     : boolean := true) is
        begin
            tbLoad(0, VecDir_g & "/" & name);
            if Core_g and load then
                regLoadAll(AXILITE_VVCT, 0, 0, KeyBits_g);
            end if;
            tbSetStall(0, ChSource_c, stallIn);
            tbSetStall(0, ChCtx_c, stallCtx);
            tbSetStall(0, ChSink_c, stallOut);
            tbSetStall(0, ChSts_c, stallOut);

            for ch in 0 to 3 loop
                OcrVec_v.clearStats(0, ch);
            end loop;

            tbStart(0, models);
            tbWaitDone(0, ChSink_c, 20 ms, name);
            checkDone(name);
        end procedure;

        -- Number of chunks of the set (messages)
        impure function chunks return natural is
        begin
            return OcrVec_v.msgCount(0);
        end function;

        -- Framer and core: clock cycles of a chunk of n bytes with an always ready output (FR-IN-02): the IV, AAD, DATA
        -- and TAG beats of the encryption, plus one cycle of the packer when n is not a multiple of the beat
        impure function chunkCycles (n : natural) return natural is
        begin
            if n mod Bytes_c /= 0 then
                return tbBeats(12, Bytes_c) + AadBeats_c + tbBeats(n, Bytes_c) + 16 / Bytes_c + 1;
            end if;
            return tbBeats(12, Bytes_c) + AadBeats_c + tbBeats(n, Bytes_c) + 16 / Bytes_c;
        end function;

        -- Sum over the chunks from first on of the cycles of a chunk (cycles), of the cycles minus the input beats
        -- (input) or of the cycles minus the dense output beats (output)
        impure function chunkSum (
            what  : string;
            first : natural := 0) return natural is
            variable R_v   : natural := 0;
            variable Len_v : natural;
        begin

            for m in first to chunks - 1 loop
                Len_v := OcrVec_v.inLen(0, m, 0);
                if what = "output" then
                    R_v := R_v + chunkCycles(Len_v) - tbBeats(32 + Len_v, Bytes_c);
                elsif what = "input" then
                    R_v := R_v + chunkCycles(Len_v) - tbBeats(Len_v, Bytes_c);
                else
                    R_v := R_v + chunkCycles(Len_v);
                end if;
            end loop;

            return R_v;
        end function;

        -- Error injection into buffer sel: "01" single, "11" double error into the next word written
        procedure inject (
            sel : std_logic;
            pat : std_logic_vector(1 downto 0)) is
        begin
            ErrInj_Sel     <= sel;
            ErrInj_BitFlip <= pat;
            ErrInj_Valid   <= '1';
            syncClk;
            ErrInj_Valid   <= '0';
            syncClk;
        end procedure;

    -- Test sequence
    begin
        test_runner_setup(runner, runner_cfg);
        await_uvvm_initialization(VOID);
        disable_log_msg(ALL_MESSAGES);
        enable_log_msg(ID_LOG_HDR);
        enable_log_msg(ID_SEQUENCER);
        if Core_g then
            shared_axilite_vvc_config(0).bfm_config.max_wait_cycles := 10000;
        else
            -- The contexts carry the configured slot
            CfgSlot <= std_logic_vector(to_unsigned(NumKeys_g - 1, SlotBits_c));
        end if;
        wait for 5 * ClkPeriod_c;
        syncClk;
        Rst <= '0';
        syncClk;
        if Core_g then

            loop
                regRead(AXILITE_VVCT, 0, RegStatus_c, Sts_v);
                exit when Sts_v(StatusBusy_c) = '0';
            end loop;

        end if;

        while test_suite loop

            if run("test_chunks") then
                -- Packets of every length: chunk positions in the AAD, chunk bytes in the DATA section, one context per
                -- chunk; random stall cycles everywhere
                runSet("chunks.txt", 0.3, 0.3, 0.3);

            elsif run("test_backpressure") then
                -- A slow sink and a slow context receiver, then a slow source
                runSet("chunks.txt", 0.0, 0.8, 0.8);
                runSet("chunks.txt", 0.8, 0.0, 0.0);
                -- A context receiver that takes nothing: the framer stops taking chunks once it owes the maximum number
                -- of contexts, and resumes when the contexts are taken
                tbLoad(0, VecDir_g & "/chunks.txt");
                tbSetStall(0, ChSource_c, 0.0);
                tbSetStall(0, ChSink_c, 0.0);
                tbSetStall(0, ChCtx_c, 1.0);

                for ch in 0 to 3 loop
                    OcrVec_v.clearStats(0, ch);
                end loop;

                tbStart(0, models);

                for i in 0 to 3000 loop
                    syncClk;
                end loop;

                check_value(OcrVec_v.cursor(0, ChSink_c) < chunks, ERROR, "the framer waits for its contexts");
                check_value(OcrVec_v.beats(0, ChCtx_c), 0, ERROR, "no context taken");
                tbSetStall(0, ChCtx_c, 0.0);
                tbWaitDone(0, ChSink_c, 20 ms, "chunks after the contexts were taken");
                checkDone("chunks.txt");

            elsif run("test_throughput") then
                -- With an always ready sink the input pauses at most AadBeats + 2 cycles per chunk: the output carries
                -- the AAD in addition to the chunk, and the buffer frees a chunk when it was read completely
                runSet("long.txt", 0.0, 0.0);
                log(ID_SEQUENCER, "input beats " & to_string(OcrVec_v.beats(0, ChSource_c)) & ", gaps " &
                    to_string(OcrVec_v.gaps(0, ChSource_c)) & ", chunks " & to_string(chunks));
                check_value(OcrVec_v.gaps(0, ChSource_c) <= chunks * (AadBeats_c + 2), ERROR,
                            "cycles without input beat");

            elsif run("test_ecc") then
                -- Per buffer a single error (corrected, the chunk is correct) and a double error (the chunk carries the
                -- IV section code), one chunk at a time
                tbLoad(0, VecDir_g & "/ecc.txt");
                N_v := OcrVec_v.msgCount(0);

                for m in 0 to N_v - 1 loop
                    -- Messages m mod 4: single and double error in the chunk buffer, then in the position FIFO
                    if m mod 4 = 0 then
                        inject('0', "01");
                    elsif m mod 4 = 1 then
                        inject('0', "11");
                    elsif m mod 4 = 2 then
                        inject('1', "01");
                    else
                        inject('1', "11");
                    end if;
                    tbStart(0, models, m + 1);
                    tbWaitDone(0, ChSink_c, 1 ms, "chunk " & to_string(m));
                end loop;

                checkDone("ecc.txt");
                syncClk;
                check_value(SecCnt(0), (N_v + 3) / 4, ERROR, "single errors of the chunk buffer");
                check_value(DedCnt(0), (N_v + 2) / 4, ERROR, "double errors of the chunk buffer");
                check_value(SecCnt(1), (N_v + 1) / 4, ERROR, "single errors of the position FIFO");
                check_value(DedCnt(1), N_v / 4, ERROR, "double errors of the position FIFO");

            elsif run("test_reset") then
                -- A reset in the middle of a packet; afterwards the packets from the next packet start on are correct
                tbLoad(0, VecDir_g & "/chunks.txt");
                N_v := OcrVec_v.msgCount(0);
                tbSetStall(0, ChSource_c, 0.1);
                tbSetStall(0, ChCtx_c, 0.2);
                tbSetStall(0, ChSink_c, 0.3);
                tbStart(0, models);

                for i in 0 to 400 loop
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

                for i in 0 to 20 loop
                    syncClk;
                end loop;

                -- Restart with the first chunk of the next packet
                M_v := OcrVec_v.cursor(0, ChSource_c);

                while M_v > 0 and M_v < N_v and not tbFlag(OcrVec_v.msgFlags(0, M_v - 1), FlagImgEnd_c) loop
                    M_v := M_v + 1;
                end loop;

                for ch in 0 to 3 loop
                    OcrVec_v.setCursor(0, ch, M_v);
                    OcrVec_v.clearAbort(0, ch);
                    OcrVec_v.clearStats(0, ch);
                end loop;

                tbStart(0, models);
                tbWaitDone(0, ChSink_c, 10 ms, "packets after the reset");
                check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "chunks after the reset");
                check_value(OcrVec_v.beats(0, ChCtx_c), N_v - M_v, ERROR, "contexts after the reset");

            elsif run("test_encrypt") then
                -- Framer and core: every chunk is one encryption with the next generated IV of the slot; the dense
                -- output carries IV, AAD, ciphertext and tag without gaps (against pycryptodome)
                runSet("enc_core.txt", 0.2, 0.2);
                regQuery(AXILITE_VVCT, 0, 0, Sts_v, Fix_v, Cnt_v);
                check_value(Cnt_v, std_logic_vector(unsigned(OcrVec_v.keyCounter(0, 0)) + chunks), ERROR,
                            "invocation counter of the slot");

            elsif run("test_ecc_core") then
                -- Framer and core: a double error in a buffer of the framer fails the message of the chunk with FORMAT,
                -- an error flag and a zero tag; a single error is corrected
                tbLoad(0, VecDir_g & "/ecc_core.txt");
                regLoadAll(AXILITE_VVCT, 0, 0, KeyBits_g);
                N_v := OcrVec_v.msgCount(0);

                for m in 0 to N_v - 1 loop
                    if m mod 4 = 0 then
                        inject('0', "01");
                    elsif m mod 4 = 1 then
                        inject('0', "11");
                    elsif m mod 4 = 2 then
                        inject('1', "01");
                    else
                        inject('1', "11");
                    end if;
                    tbStart(0, models, m + 1);
                    tbWaitDone(0, ChSink_c, 1 ms, "chunk " & to_string(m));
                    tbWaitDone(0, ChSts_c, 1 ms, "status of chunk " & to_string(m));
                end loop;

                checkDone("ecc_core.txt");
                regCheck(AXILITE_VVCT, 0, RegErrFormat_c, std_logic_vector(to_unsigned(N_v / 2, 32)), "ERR_FORMAT");

            elsif run("test_throughput_core") then
                -- Framer and core without stall cycles: from the end of the first chunk at the output (latency: its IV
                -- leaves before the chunk is buffered completely) every chunk takes exactly the cycles of its
                -- encryption at the core; the input pauses for the beats that the core adds, the dense output for the
                -- beats that the packing saves
                tbLoad(0, VecDir_g & "/tp_core.txt");
                regLoadAll(AXILITE_VVCT, 0, 0, KeyBits_g);

                for ch in 0 to 3 loop
                    tbSetStall(0, ch, 0.0);
                    OcrVec_v.clearStats(0, ch);
                end loop;

                tbStart(0, models);

                while OcrVec_v.cursor(0, ChSink_c) < 1 loop
                    syncClk;
                end loop;

                -- The last beat of the first chunk was in the cycle before
                OcrVec_v.clearStats(0, ChSink_c);
                T_v := now - 1 ns;
                tbWaitDone(0, ChSink_c, 20 ms, "tp_core.txt");
                checkDone("tp_core.txt");
                T_v := OcrVec_v.lastTime(0, ChSink_c) - T_v;
                N_v := T_v / ClkPeriod_c;
                log(ID_SEQUENCER, "chunks " & to_string(chunks) & ", cycles of a chunk of " & to_string(ChunkBytes_g) &
                    " bytes " & to_string(chunkCycles(ChunkBytes_g)) & ", output cycles after the first chunk " &
                    to_string(N_v) & ", expected " & to_string(chunkSum("cycles", 1)));
                log(ID_SEQUENCER, "input beats " & to_string(OcrVec_v.beats(0, ChSource_c)) & ", gaps " &
                    to_string(OcrVec_v.gaps(0, ChSource_c)) & ", cycles minus beats " & to_string(chunkSum("input")));
                log(ID_SEQUENCER, "output beats after the first chunk " & to_string(OcrVec_v.beats(0, ChSink_c)) &
                    ", gaps " & to_string(OcrVec_v.gaps(0, ChSink_c)) & ", cycles minus beats " &
                    to_string(chunkSum("output", 1)));
                check_value(N_v, chunkSum("cycles", 1), ERROR, "output cycles of the chunks after the first one");
                check_value(OcrVec_v.gaps(0, ChSink_c), chunkSum("output", 1), ERROR, "cycles without output beat");
                check_value(OcrVec_v.gaps(0, ChSource_c) <= Latency_c + chunkSum("input"), ERROR,
                            "cycles without input beat");
            end if;

        end loop;

        ocrTestEnd(runner);
        wait;
    end process;

    i_th : entity work.ocr_framer_th
        generic map (
            DataWidth_g    => DataWidth_g,
            KeyBits_g      => KeyBits_g,
            NumKeys_g      => NumKeys_g,
            ChunkBytes_g   => ChunkBytes_g,
            BufferChunks_g => BufferChunks_g,
            Core_g         => Core_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            CfgSlot        => CfgSlot,
            ErrInj_Sel     => ErrInj_Sel,
            ErrInj_BitFlip => ErrInj_BitFlip,
            ErrInj_Valid   => ErrInj_Valid,
            Ecc_Sec        => Ecc_Sec,
            Ecc_Ded        => Ecc_Ded
        );

end architecture;
