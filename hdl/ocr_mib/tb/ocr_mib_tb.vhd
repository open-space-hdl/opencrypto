---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocr_mib: reset values and generics, key load through the self-clearing staging
-- registers, zeroize, slot query, counters and events of the status codes, interrupt, EDAC monitor
-- and error injection.
--
-- Documentation: hdl/ocr_mib/docs/verification_plan.md

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
    use work.ocr_tb_axi_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_mib_tb is
    generic (
        runner_cfg : string
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_mib_tb is

    constant ClkPeriod_c : time                           := 10 ns;
    constant KeyBits_c   : positive                       := 256;
    constant NumKeys_c   : positive                       := 4;
    constant SlotBits_c  : positive                       := slotBits(NumKeys_c);
    constant Axi_c       : natural                        := 0;
    constant Key_c       : std_logic_vector(255 downto 0) :=
        x"603DEB1015CA71BE2B73AEF0857D77811F352C073B6108D72D9810A30914DFF4";

    signal Clk               : std_logic;
    signal Rst               : std_logic                     := '1';
    signal Irq               : std_logic;
    signal M_Load_Valid      : std_logic;
    signal M_Load_Ready      : std_logic                     := '0';
    signal M_Load_Slot       : std_logic_vector(SlotBits_c - 1 downto 0);
    signal M_Load_Key        : std_logic_vector(KeyBits_c - 1 downto 0);
    signal M_Load_IvGen      : std_logic;
    signal M_Load_Fixed      : std_logic_vector(31 downto 0);
    signal M_Load_Counter    : std_logic_vector(63 downto 0);
    signal Zeroize           : std_logic;
    signal Kt_Busy           : std_logic                     := '0';
    signal M_Query_Valid     : std_logic;
    signal M_Query_Ready     : std_logic                     := '0';
    signal M_Query_Slot      : std_logic_vector(SlotBits_c - 1 downto 0);
    signal S_Query_Valid     : std_logic                     := '0';
    signal S_Query_KeyValid  : std_logic                     := '0';
    signal S_Query_IvGen     : std_logic                     := '0';
    signal S_Query_Exhausted : std_logic                     := '0';
    signal S_Query_Fixed     : std_logic_vector(31 downto 0) := (others => '0');
    signal S_Query_Counter   : std_logic_vector(63 downto 0) := (others => '0');
    signal S_Query_Ded       : std_logic                     := '0';
    signal Evt_Valid         : std_logic                     := '0';
    signal Evt_Code          : Status_t                      := (others => '0');
    signal Evt_Decrypt       : std_logic                     := '0';
    signal Ecc_Sec           : std_logic_vector(17 downto 0) := (others => '0');
    signal Ecc_Ded           : std_logic_vector(17 downto 0) := (others => '0');
    signal Gcm_ErrInj_Sel    : std_logic_vector(3 downto 0);
    signal Kt_ErrInj_Sel     : std_logic_vector(1 downto 0);
    signal ErrInj_BitFlip    : std_logic_vector(1 downto 0);
    signal Gcm_ErrInj_Valid  : std_logic;
    signal Kt_ErrInj_Valid   : std_logic;
    signal GcmInjCnt         : natural                       := 0;
    signal KtInjCnt          : natural                       := 0;
    signal ZeroCnt           : natural                       := 0;

begin

    test_runner_watchdog(runner, 5 ms);

    -- Error injection and zeroize strobes
    p_inj : process (Clk) is
    begin
        if rising_edge(Clk) then
            if Gcm_ErrInj_Valid = '1' then
                GcmInjCnt <= GcmInjCnt + 1;
            end if;
            if Kt_ErrInj_Valid = '1' then
                KtInjCnt <= KtInjCnt + 1;
            end if;
            if Zeroize = '1' then
                ZeroCnt <= ZeroCnt + 1;
            end if;
        end if;
    end process;

    p_main : process is
        variable D_v : std_logic_vector(31 downto 0);
        variable N_v : natural;

        procedure syncClk is
        begin
            wait until rising_edge(Clk);
            wait for 1 ns;
        end procedure;

        procedure wr (
            addr : natural;
            data : std_logic_vector(31 downto 0)) is
        begin
            regWrite(AXILITE_VVCT, Axi_c, addr, data);
        end procedure;

        procedure chk (
            addr : natural;
            data : std_logic_vector(31 downto 0);
            msg  : string) is
        begin
            regCheck(AXILITE_VVCT, Axi_c, addr, data, msg);
        end procedure;

        -- One status event of the data path
        procedure event (
            code : natural;
            dec  : std_logic) is
        begin
            Evt_Code    <= std_logic_vector(to_unsigned(code, 4));
            Evt_Decrypt <= dec;
            Evt_Valid   <= '1';
            syncClk;
            Evt_Valid   <= '0';
        end procedure;

        -- Writes the key, the IV fields and starts the load of a slot
        procedure startLoad (
            slot  : natural;
            ivgen : std_logic;
            key   : boolean) is
            variable C_v : std_logic_vector(31 downto 0) := (others => '0');
        begin
            if key then

                for i in 0 to 7 loop
                    wr(RegKeyBase_c + 4 * i, Key_c(255 - 32 * i downto 224 - 32 * i));
                end loop;

                wr(RegIvFixed_c, x"11223344");
                wr(RegIvCountLo_c, x"55667788");
                wr(RegIvCountHi_c, x"99AABBCC");
            end if;
            C_v(KeyLoadStart_c)                         := '1';
            C_v(KeyLoadIvGen_c)                         := ivgen;
            C_v(KeyLoadSlotHi_c downto KeyLoadSlotLo_c) := std_logic_vector(to_unsigned(slot, 8));
            wr(RegKeyLoad_c, C_v);
        end procedure;

    -- Test sequence
    begin
        test_runner_setup(runner, runner_cfg);
        await_uvvm_initialization(VOID);
        disable_log_msg(ALL_MESSAGES);
        enable_log_msg(ID_LOG_HDR);
        shared_axilite_vvc_config(Axi_c).bfm_config.max_wait_cycles := 1000;
        wait for 5 * ClkPeriod_c;
        syncClk;
        Rst                                                         <= '0';
        syncClk;

        if run("test_reset_values") then
            -- Identification, generics, reset values of all registers with a fixed reset value
            chk(RegId_c, RegMapId_c, "ID");
            D_v                                                         := (others => '0');
            D_v(GenericsDataBytesHi_c downto GenericsDataBytesLo_c)     := std_logic_vector(to_unsigned(8, 5));
            D_v(GenericsKeyBitsHi_c downto GenericsKeyBitsLo_c)         := std_logic_vector(to_unsigned(256, 9));
            D_v(GenericsNumKeysHi_c downto GenericsNumKeysLo_c)         := std_logic_vector(to_unsigned(4, 9));
            D_v(GenericsRelease_c)                                      := '1';
            D_v(GenericsAesUnitsHi_c downto GenericsAesUnitsLo_c)       := std_logic_vector(to_unsigned(10, 4));
            chk(RegGenerics_c, D_v, "GENERICS");
            D_v                                                         := (others => '0');
            D_v(Generics2GhashDigitHi_c downto Generics2GhashDigitLo_c) := std_logic_vector(to_unsigned(128, 8));
            D_v(Generics2LenBitsHi_c downto Generics2LenBitsLo_c)       := std_logic_vector(to_unsigned(20, 6));
            chk(RegGenerics2_c, D_v, "GENERICS2");
            chk(RegReleaseBytes_c, std_logic_vector(to_unsigned(2048, 32)), "RELEASE_BYTES");
            chk(RegCtrl_c, x"00000000", "CTRL");
            chk(RegStatus_c, x"00000000", "STATUS");
            chk(RegEvents_c, x"00000000", "EVENTS");
            chk(RegIrqEn_c, x"00000000", "IRQ_EN");
            chk(RegIrqStatus_c, x"00000000", "IRQ_STATUS");
            chk(RegSlotQuery_c, x"00000000", "SLOT_QUERY");
            chk(RegSlotStatus_c, x"00000000", "SLOT_STATUS");

            for c in 0 to 9 loop
                chk(RegEncryptions_c + 4 * c, x"00000000", "counter " & to_string(c));
            end loop;

            chk(RegEccStatus_c, x"00000000", "ECC_STATUS");
            chk(RegEccSelect_c, x"00000000", "ECC_SELECT");
            chk(RegEccCount_c, x"00000000", "ECC_COUNT");
            -- Addresses without register read as zero, writes to them have no effect
            wr(16#24#, x"FFFFFFFF");
            wr(16#FC#, x"FFFFFFFF");
            chk(16#24#, x"00000000", "address 0x24");
            chk(16#FC#, x"00000000", "address 0xFC");
            chk(RegEvents_c, x"00000000", "EVENTS after writes to unused addresses");
            chk(RegIrqEn_c, x"00000000", "IRQ_EN after writes to unused addresses");
            -- The busy flag of the key table
            Kt_Busy <= '1';
            chk(RegStatus_c, x"00000001", "STATUS busy");
            Kt_Busy <= '0';

        elsif run("test_key_load") then
            -- The load presents the staged key until the key table takes it; the staging registers clear
            startLoad(2, '1', true);
            check_value(M_Load_Valid, '1', ERROR, "load request");
            check_value(M_Load_Key, Key_c, ERROR, "key of the load");
            check_value(to_integer(unsigned(M_Load_Slot)), 2, ERROR, "slot of the load");
            check_value(M_Load_IvGen, '1', ERROR, "IV construction of the load");
            check_value(M_Load_Fixed, x"11223344", ERROR, "fixed field of the load");
            check_value(M_Load_Counter, x"99AABBCC55667788", ERROR, "counter of the load");
            chk(RegStatus_c, x"00000001", "STATUS busy while the load waits");
            -- Key words and IV fields never read back
            chk(RegKeyBase_c, x"00000000", "KEY0 reads as zero");
            chk(RegIvFixed_c, x"00000000", "IV_FIXED reads as zero");
            M_Load_Ready <= '1';
            Kt_Busy      <= '1';
            syncClk;
            M_Load_Ready <= '0';
            check_value(M_Load_Valid, '0', ERROR, "load taken");
            check_value(M_Load_Key = (M_Load_Key'range => '0'), ERROR, "staged key cleared");
            check_value(M_Load_Counter = (M_Load_Counter'range => '0'), ERROR, "staged counter cleared");
            chk(RegStatus_c, x"00000001", "STATUS busy during the load");
            Kt_Busy      <= '0';
            syncClk;
            syncClk;
            regRead(AXILITE_VVCT, Axi_c, RegEvents_c, D_v);
            check_value(D_v(EventsLoadDone_c), '1', ERROR, "LOAD_DONE event");
            chk(RegStatus_c, x"00000000", "STATUS idle");
            -- A load of a slot beyond the key table is ignored
            startLoad(7, '0', true);
            syncClk;
            check_value(M_Load_Valid, '0', ERROR, "no load of slot 7");
            -- KEY_LOAD without START starts no load
            wr(RegKeyLoad_c, x"00000001");
            syncClk;
            check_value(M_Load_Valid, '0', ERROR, "no load without START");
            -- A start while the key table runs a load is ignored
            startLoad(1, '0', true);
            M_Load_Ready <= '1';
            Kt_Busy      <= '1';
            syncClk;
            M_Load_Ready <= '0';
            startLoad(2, '0', false);
            syncClk;
            check_value(M_Load_Valid, '0', ERROR, "no load while a load runs");
            Kt_Busy      <= '0';
            syncClk;
            syncClk;
            check_value(M_Load_Valid, '0', ERROR, "the ignored start is not executed later");

        elsif run("test_zeroize") then
            -- ZEROIZE: one command to the key table; the staging registers are erased
            startLoad(0, '0', true);
            M_Load_Ready <= '1';
            syncClk;
            M_Load_Ready <= '0';

            for i in 0 to 7 loop
                wr(RegKeyBase_c + 4 * i, Key_c(255 - 32 * i downto 224 - 32 * i));
            end loop;

            wr(RegCtrl_c, x"00000001");
            syncClk;
            check_value(ZeroCnt, 1, ERROR, "one zeroize command");
            startLoad(1, '0', false);
            check_value(M_Load_Valid, '1', ERROR, "load request after zeroize");
            check_value(M_Load_Key = (M_Load_Key'range => '0'), ERROR, "staged key erased by zeroize");
            M_Load_Ready <= '1';
            syncClk;
            M_Load_Ready <= '0';

        elsif run("test_query") then
            -- SLOT_QUERY: request to the key table, PENDING until the answer, no key in any register
            wr(RegSlotQuery_c, x"00000003");
            check_value(M_Query_Valid, '1', ERROR, "query request");
            check_value(to_integer(unsigned(M_Query_Slot)), 3, ERROR, "query slot");
            chk(RegSlotStatus_c, x"00000010", "SLOT_STATUS pending");
            M_Query_Ready     <= '1';
            syncClk;
            M_Query_Ready     <= '0';
            S_Query_Valid     <= '1';
            S_Query_KeyValid  <= '1';
            S_Query_IvGen     <= '1';
            S_Query_Exhausted <= '0';
            S_Query_Ded       <= '0';
            S_Query_Fixed     <= x"DEADBEEF";
            S_Query_Counter   <= x"0123456789ABCDEF";
            syncClk;
            S_Query_Valid     <= '0';
            chk(RegSlotStatus_c, x"00000003", "SLOT_STATUS valid, generated IVs");
            chk(RegSlotFixed_c, x"DEADBEEF", "SLOT_FIXED");
            chk(RegSlotCountLo_c, x"89ABCDEF", "SLOT_COUNT_LO");
            chk(RegSlotCountHi_c, x"01234567", "SLOT_COUNT_HI");
            chk(RegSlotQuery_c, x"00000003", "SLOT_QUERY");
            -- A slot beyond the key table reads as erased
            wr(RegSlotQuery_c, x"00000009");
            M_Query_Ready     <= '1';
            syncClk;
            M_Query_Ready     <= '0';
            S_Query_Valid     <= '1';
            S_Query_Exhausted <= '1';
            S_Query_Ded       <= '1';
            syncClk;
            S_Query_Valid     <= '0';
            chk(RegSlotStatus_c, x"00000000", "SLOT_STATUS of slot 9");
            chk(RegSlotFixed_c, x"00000000", "SLOT_FIXED of slot 9");

        elsif run("test_counters") then
            -- One counter per status code and per direction for OK; one event flag per error code
            N_v := 0;

            for code in 0 to 8 loop

                for i in 0 to code loop
                    event(code, '0');
                end loop;

            end loop;

            event(0, '1');
            event(0, '1');
            chk(RegEncryptions_c, std_logic_vector(to_unsigned(1, 32)), "ENCRYPTIONS");
            chk(RegDecryptions_c, std_logic_vector(to_unsigned(2, 32)), "DECRYPTIONS");

            for code in 1 to 8 loop
                chk(RegErrAuth_c + 4 * (code - 1), std_logic_vector(to_unsigned(code + 1, 32)),
                    "counter of code " & to_string(code));
            end loop;

            chk(RegEvents_c, x"000000FF", "EVENTS of the codes");
            -- RC: a write clears a counter; CLEAR clears all; W1C clears event flags
            wr(RegErrAuth_c, x"00000000");
            chk(RegErrAuth_c, x"00000000", "ERR_AUTH cleared");
            chk(RegErrFormat_c, std_logic_vector(to_unsigned(3, 32)), "ERR_FORMAT kept");
            wr(RegCtrl_c, x"00000002");

            for c in 0 to 9 loop
                chk(RegEncryptions_c + 4 * c, x"00000000", "counter " & to_string(c) & " cleared");
            end loop;

            wr(RegEvents_c, x"00000005");
            chk(RegEvents_c, x"000000FA", "EVENTS after W1C");
            -- A write clears its counter only
            event(0, '0');
            event(0, '1');

            for code in 1 to 8 loop
                event(code, '0');
            end loop;

            for c in 0 to 9 loop
                wr(RegEncryptions_c + 4 * c, x"00000000");
                chk(RegEncryptions_c + 4 * c, x"00000000", "counter " & to_string(c) & " cleared by a write");
                if c < 9 then
                    chk(RegEncryptions_c + 4 * (c + 1), x"00000001", "counter " & to_string(c + 1) & " kept");
                end if;
            end loop;

            -- Codes without meaning change no counter and no event flag
            wr(RegEvents_c, x"000007FF");

            for code in 9 to 15 loop
                event(code, '0');
            end loop;

            for c in 0 to 9 loop
                chk(RegEncryptions_c + 4 * c, x"00000000", "counter " & to_string(c) & " after invalid codes");
            end loop;

            chk(RegEvents_c, x"00000000", "EVENTS after invalid codes");

        elsif run("test_irq") then
            -- Irq is the OR of the enabled event flags
            event(1, '1');
            syncClk;
            check_value(Irq, '0', ERROR, "no interrupt without enable");
            wr(RegIrqEn_c, x"00000001");
            syncClk;
            check_value(Irq, '1', ERROR, "interrupt of AUTH");
            chk(RegIrqStatus_c, x"00000001", "IRQ_STATUS");
            wr(RegEvents_c, x"00000001");
            syncClk;
            check_value(Irq, '0', ERROR, "interrupt cleared");
            Ecc_Ded(5) <= '1';
            syncClk;
            Ecc_Ded(5) <= '0';
            wr(RegIrqEn_c, std_logic_vector(to_unsigned(2 ** EventsEccDed_c, 32)));
            syncClk;
            check_value(Irq, '1', ERROR, "interrupt of ECC_DED");

        elsif run("test_ecc") then

            -- EDAC monitor: SEC and DED counters per channel, DED flags, clearing
            for c in 0 to 17 loop

                for i in 0 to c mod 3 loop
                    Ecc_Sec(c) <= '1';
                    syncClk;
                    Ecc_Sec(c) <= '0';
                end loop;

                if c mod 2 = 1 then
                    Ecc_Ded(c) <= '1';
                    syncClk;
                    Ecc_Ded(c) <= '0';
                end if;
            end loop;

            for c in 0 to 17 loop
                wr(RegEccSelect_c, std_logic_vector(to_unsigned(c, 32)));
                D_v := std_logic_vector(to_unsigned(c mod 2, 16)) & std_logic_vector(to_unsigned(c mod 3 + 1, 16));
                chk(RegEccCount_c, D_v, "ECC_COUNT of channel " & to_string(c));
            end loop;

            chk(RegEccStatus_c, "00000000000000" & "101010101010101010", "ECC_STATUS");
            regRead(AXILITE_VVCT, Axi_c, RegEvents_c, D_v);
            check_value(D_v(EventsEccSec_c), '1', ERROR, "ECC_SEC event");
            check_value(D_v(EventsEccDed_c), '1', ERROR, "ECC_DED event");
            wr(RegEccSelect_c, x"00000004");
            wr(RegEccCount_c, x"00000000");
            chk(RegEccCount_c, x"00000000", "ECC_COUNT of channel 4 cleared");
            wr(RegEccSelect_c, x"00000005");
            chk(RegEccCount_c, x"00010003", "ECC_COUNT of channel 5 kept");
            wr(RegEccStatus_c, x"00000000");
            chk(RegEccStatus_c, x"00000000", "ECC_STATUS cleared");
            chk(RegEccCount_c, x"00000000", "all counters cleared");

        elsif run("test_inject") then
            -- ECC_INJECT: targets 0 to 10 go to the data path, 16 to 19 to the key table
            wr(RegEccInject_c, x"00000107");
            syncClk;
            check_value(GcmInjCnt, 1, ERROR, "injection into the data path");
            check_value(Gcm_ErrInj_Sel, "0111", ERROR, "data path target");
            check_value(ErrInj_BitFlip, "01", ERROR, "single error pattern");
            wr(RegEccInject_c, x"00000212");
            syncClk;
            check_value(KtInjCnt, 1, ERROR, "injection into the key table");
            check_value(Kt_ErrInj_Sel, "10", ERROR, "key table target");
            check_value(ErrInj_BitFlip, "11", ERROR, "double error pattern");
            wr(RegEccInject_c, x"00000003");
            syncClk;
            check_value(GcmInjCnt, 1, ERROR, "no injection without SINGLE or DOUBLE");
            check_value(KtInjCnt, 1, ERROR, "no injection without SINGLE or DOUBLE");
        end if;

        ocrTestEnd(runner);
        wait;
    end process;

    i_th : entity work.ocr_mib_th
        generic map (
            KeyBits_g => KeyBits_c,
            NumKeys_g => NumKeys_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            Irq               => Irq,
            M_Load_Valid      => M_Load_Valid,
            M_Load_Ready      => M_Load_Ready,
            M_Load_Slot       => M_Load_Slot,
            M_Load_Key        => M_Load_Key,
            M_Load_IvGen      => M_Load_IvGen,
            M_Load_Fixed      => M_Load_Fixed,
            M_Load_Counter    => M_Load_Counter,
            Zeroize           => Zeroize,
            Kt_Busy           => Kt_Busy,
            M_Query_Valid     => M_Query_Valid,
            M_Query_Ready     => M_Query_Ready,
            M_Query_Slot      => M_Query_Slot,
            S_Query_Valid     => S_Query_Valid,
            S_Query_KeyValid  => S_Query_KeyValid,
            S_Query_IvGen     => S_Query_IvGen,
            S_Query_Exhausted => S_Query_Exhausted,
            S_Query_Fixed     => S_Query_Fixed,
            S_Query_Counter   => S_Query_Counter,
            S_Query_Ded       => S_Query_Ded,
            Evt_Valid         => Evt_Valid,
            Evt_Code          => Evt_Code,
            Evt_Decrypt       => Evt_Decrypt,
            Ecc_Sec           => Ecc_Sec,
            Ecc_Ded           => Ecc_Ded,
            Gcm_ErrInj_Sel    => Gcm_ErrInj_Sel,
            Kt_ErrInj_Sel     => Kt_ErrInj_Sel,
            ErrInj_BitFlip    => ErrInj_BitFlip,
            Gcm_ErrInj_Valid  => Gcm_ErrInj_Valid,
            Kt_ErrInj_Valid   => Kt_ErrInj_Valid
        );

end architecture;
