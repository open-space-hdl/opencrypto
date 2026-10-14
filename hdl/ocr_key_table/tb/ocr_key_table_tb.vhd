---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocr_key_table: erasure after the reset, key load with hash subkey, slot query,
-- context resolution with all checks, IV generation and exhaustion, zeroize, loads during traffic,
-- error injection, scrubbing, throughput and reset.
--
-- Documentation: hdl/ocr_key_table/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library vunit_lib;
    context vunit_lib.vunit_context;

library work;
    use work.ocr_pkg.all;
    use work.ocr_tb_pkg.all;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_key_table_tb is
    generic (
        runner_cfg    : string;
        KeyBits_g     : positive := 256;
        NumKeys_g     : positive := 4;
        ClkFreqHz_g   : real     := 100.0e6;
        ScrubPeriod_g : real     := 0.0;
        VecDir_g      : string
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_key_table_tb is

    constant ClkPeriod_c   : time := 1 sec / ClkFreqHz_g;
    -- Clock cycles between two scrub passes (0: free-running scrubbers); every wait for a scrubber adds them
    constant ScrubCycles_c : natural  := integer(ScrubPeriod_g * ClkFreqHz_g);
    constant SlotBits_c    : positive := slotBits(NumKeys_g);
    -- Context source and job checker
    constant Both_c        : std_logic_vector(TbChannels_c - 1 downto 0) := x"06";

    signal Clk             : std_logic;
    signal Rst             : std_logic                                 := '1';
    signal Load_Valid      : std_logic                                 := '0';
    signal Load_Ready      : std_logic;
    signal Load_Slot       : std_logic_vector(SlotBits_c - 1 downto 0) := (others => '0');
    signal Load_Key        : std_logic_vector(KeyBits_g - 1 downto 0)  := (others => '0');
    signal Load_IvGen      : std_logic                                 := '0';
    signal Load_Fixed      : std_logic_vector(31 downto 0)             := (others => '0');
    signal Load_Counter    : std_logic_vector(63 downto 0)             := (others => '0');
    signal Zeroize         : std_logic                                 := '0';
    signal Busy            : std_logic;
    signal Query_Valid     : std_logic                                 := '0';
    signal Query_Ready     : std_logic;
    signal Query_Slot      : std_logic_vector(SlotBits_c - 1 downto 0) := (others => '0');
    signal Query_OutValid  : std_logic;
    signal Query_KeyValid  : std_logic;
    signal Query_IvGen     : std_logic;
    signal Query_Exhausted : std_logic;
    signal Query_Fixed     : std_logic_vector(31 downto 0);
    signal Query_Counter   : std_logic_vector(63 downto 0);
    signal Query_Ded       : std_logic;
    signal Ecc_Sec         : std_logic_vector(6 downto 0);
    signal Ecc_Ded         : std_logic_vector(6 downto 0);
    signal ErrInj_Sel      : std_logic_vector(1 downto 0)              := (others => '0');
    signal ErrInj_BitFlip  : std_logic_vector(1 downto 0)              := (others => '0');
    signal ErrInj_Valid    : std_logic                                 := '0';
    signal AuxRequests     : natural;
    signal JobReadyStall   : real                                      := 0.0;

    type CntArr_t is array (0 to 6) of natural;

    signal SecCnt : CntArr_t := (others => 0);
    signal DedCnt : CntArr_t := (others => 0);

begin

    test_runner_watchdog(runner, 2_000_000 * ClkPeriod_c);

    p_ecc : process (Clk) is
    begin
        if rising_edge(Clk) then

            for i in 0 to 6 loop
                if Ecc_Sec(i) = '1' then
                    SecCnt(i) <= SecCnt(i) + 1;
                end if;
                if Ecc_Ded(i) = '1' then
                    DedCnt(i) <= DedCnt(i) + 1;
                end if;
            end loop;

        end if;
    end process;

    p_main : process is
        variable N_v    : natural;
        variable K_v    : std_logic_vector(255 downto 0);
        variable Cnt_v  : unsigned(63 downto 0);
        variable Gen_v  : natural;
        variable T0_v   : time;
        variable Sec0_v : natural;
        variable Ded0_v : natural;
        variable Span_v : natural;
        variable Pat_v  : std_logic_vector(1 downto 0);

        procedure syncClk is
        begin
            wait until rising_edge(Clk);
            wait for 1 ns;
        end procedure;

        procedure waitIdle is
        begin
            syncClk;

            while Busy = '1' loop
                syncClk;
            end loop;

        end procedure;

        -- Loads the key slot of KEY record k of a set
        procedure loadKey (
            set : natural;
            k   : natural) is
        begin
            K_v          := OcrVec_v.keyValue(set, k);
            Load_Slot    <= std_logic_vector(to_unsigned(OcrVec_v.keySlot(set, k), SlotBits_c));
            Load_Key     <= K_v(255 downto 256 - KeyBits_g);
            Load_IvGen   <= tbSl(OcrVec_v.keyIvGen(set, k));
            Load_Fixed   <= OcrVec_v.keyFixed(set, k);
            Load_Counter <= OcrVec_v.keyCounter(set, k);
            Load_Valid   <= '1';

            loop
                wait until rising_edge(Clk);
                exit when Load_Ready = '1';
            end loop;

            wait for 1 ns;
            Load_Valid <= '0';
        end procedure;

        procedure loadAll (set : natural) is
        begin

            for k in 0 to OcrVec_v.keyCount(set) - 1 loop
                loadKey(set, k);
                waitIdle;
            end loop;

        end procedure;

        -- Queries a slot; the response is in the Query_* signals afterwards
        procedure query (slot : natural) is
        begin
            Query_Slot  <= std_logic_vector(to_unsigned(slot, SlotBits_c));
            Query_Valid <= '1';

            loop
                wait until rising_edge(Clk);
                exit when Query_Ready = '1';
            end loop;

            wait for 1 ns;
            Query_Valid <= '0';

            loop
                wait until rising_edge(Clk);
                exit when Query_OutValid = '1';
            end loop;

        end procedure;

        procedure doZeroize is
        begin
            Zeroize <= '1';
            syncClk;
            Zeroize <= '0';
            waitIdle;
        end procedure;

        procedure inject (
            sel : natural;
            pat : std_logic_vector(1 downto 0)) is
        begin
            ErrInj_Sel     <= std_logic_vector(to_unsigned(sel, 2));
            ErrInj_BitFlip <= pat;
            ErrInj_Valid   <= '1';
            syncClk;
            ErrInj_Valid   <= '0';
        end procedure;

        -- All contexts of set 0 with the given stall probability of contexts and jobs
        procedure runContexts (stall : real) is
        begin
            tbSetStall(0, ChCtx_c, stall);
            JobReadyStall <= stall;
            OcrVec_v.clearStats(0, ChCtx_c);
            tbStart(0, Both_c);
            tbWaitDone(0, ChSink_c, 500_000 * ClkPeriod_c, "contexts");
            check_value(OcrVec_v.cursor(0, ChSink_c), OcrVec_v.msgCount(0), ERROR, "jobs checked");
        end procedure;

        -- Every loaded generator slot: the counter of its KEY record plus its generated IVs
        procedure checkCounters is
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

                    query(OcrVec_v.keySlot(0, k));
                    Cnt_v := unsigned(OcrVec_v.keyCounter(0, k)) + Gen_v;
                    check_value(Query_Counter, std_logic_vector(Cnt_v), ERROR,
                                "invocation counter of slot " & to_string(OcrVec_v.keySlot(0, k)));
                end if;
            end loop;

        end procedure;

    -- Test sequence
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);
        wait for 5 * ClkPeriod_c;
        syncClk;
        Rst <= '0';

        while test_suite loop

            if run("test_erase_after_reset") then
                -- KT-1: after the reset the table erases all slots; every slot is invalid, contexts fail with KEY
                T0_v := now;
                waitIdle;
                check_value((now - T0_v) / ClkPeriod_c <= maximum(2, NumKeys_g) + 3, ERROR, "duration of the erasure");

                for s in 0 to 2 ** SlotBits_c - 1 loop
                    query(s);
                    check_value(Query_KeyValid, '0', ERROR, "slot " & to_string(s) & " invalid");
                    check_value(Query_Counter, (63 downto 0 => '0'), ERROR, "counter of slot " & to_string(s));
                    check_value(Query_Fixed, (31 downto 0 => '0'), ERROR, "fixed field of slot " & to_string(s));
                end loop;

                tbLoad(0, VecDir_g & "/unloaded.txt");
                runContexts(0.0);

            elsif run("test_load_query") then
                -- KT-2: every load computes H with one request; the query reports the slot, never the key
                waitIdle;
                tbLoad(0, VecDir_g & "/kt.txt");
                loadAll(0);
                check_value(AuxRequests, OcrVec_v.keyCount(0), ERROR, "hash subkey requests");
                -- A load of a slot out of range is accepted and ignored
                if NumKeys_g < 2 ** SlotBits_c then
                    Load_Slot  <= std_logic_vector(to_unsigned(NumKeys_g, SlotBits_c));
                    Load_Key   <= (others => '1');
                    Load_Valid <= '1';

                    loop
                        wait until rising_edge(Clk);
                        exit when Load_Ready = '1';
                    end loop;

                    wait for 1 ns;
                    Load_Valid <= '0';
                    waitIdle;
                    check_value(AuxRequests, OcrVec_v.keyCount(0), ERROR, "no hash subkey request out of range");
                    query(NumKeys_g);
                    check_value(Query_KeyValid, '0', ERROR, "slot out of range invalid");
                end if;

                for k in 0 to OcrVec_v.keyCount(0) - 1 loop
                    query(OcrVec_v.keySlot(0, k));
                    check_value(Query_KeyValid, '1', ERROR, "slot valid");
                    check_value(Query_IvGen, tbSl(OcrVec_v.keyIvGen(0, k)), ERROR, "IV construction");
                    check_value(Query_Fixed, OcrVec_v.keyFixed(0, k), ERROR, "fixed field");
                    check_value(Query_Counter, OcrVec_v.keyCounter(0, k), ERROR, "invocation counter");
                    check_value(Query_Exhausted, '0', ERROR, "not exhausted");
                end loop;

                -- Queries in consecutive cycles: every accepted query is answered
                Query_Slot  <= std_logic_vector(to_unsigned(OcrVec_v.keySlot(0, 0), SlotBits_c));
                Query_Valid <= '1';
                N_v         := 0;
                Gen_v       := 0;

                for i in 0 to 19 loop
                    wait until rising_edge(Clk);
                    if Query_Ready = '1' then
                        N_v := N_v + 1;
                    end if;
                    if Query_OutValid = '1' then
                        Gen_v := Gen_v + 1;
                        check_value(Query_Counter, OcrVec_v.keyCounter(0, 0), ERROR, "counter of a back-to-back query");
                    end if;
                    if i = 15 then
                        Query_Valid <= '0' after 1 ns;
                    end if;
                end loop;

                check_value(N_v >= 5, ERROR, "back-to-back queries accepted");
                check_value(Gen_v, N_v, ERROR, "answers of back-to-back queries");

            elsif run("test_resolve") then
                -- KT-3, KT-4: contexts of loaded, unloaded and out-of-range slots, both directions, both IV sources
                waitIdle;
                tbLoad(0, VecDir_g & "/kt.txt");
                loadAll(0);
                runContexts(0.3);
                checkCounters;

            elsif run("test_exhaustion") then
                -- GCM 8.3: the last value of the invocation counter is never used
                waitIdle;
                tbLoad(0, VecDir_g & "/exhaust.txt");
                loadAll(0);
                runContexts(0.2);
                query(0);
                check_value(Query_Exhausted, '1', ERROR, "slot 0 exhausted");
                check_value(Query_Counter, (63 downto 0 => '1'), ERROR, "counter of slot 0");

            elsif run("test_zeroize") then
                -- KT-1: zeroize erases every slot; the slots can be loaded again
                waitIdle;
                tbLoad(0, VecDir_g & "/kt.txt");
                loadAll(0);
                doZeroize;

                for s in 0 to 2 ** SlotBits_c - 1 loop
                    query(s);
                    check_value(Query_KeyValid, '0', ERROR, "slot " & to_string(s) & " erased");
                end loop;

                tbLoad(0, VecDir_g & "/unloaded.txt");
                runContexts(0.0);
                tbLoad(0, VecDir_g & "/kt.txt");
                loadAll(0);
                runContexts(0.1);
                -- A load requested right after a zeroize waits for the erasure
                Zeroize <= '1';
                syncClk;
                Zeroize <= '0';
                loadKey(0, 0);
                waitIdle;
                query(OcrVec_v.keySlot(0, 0));
                check_value(Query_KeyValid, '1', ERROR, "slot loaded after the erasure");
                -- A zeroize during a load erases the slot after the load
                loadKey(0, 0);
                Zeroize <= '1';
                syncClk;
                Zeroize <= '0';
                waitIdle;
                query(OcrVec_v.keySlot(0, 0));
                check_value(Query_KeyValid, '0', ERROR, "slot erased by a zeroize during its load");
                -- A zeroize while contexts are resolved starts after the read in flight
                tbLoad(0, VecDir_g & "/unloaded.txt");
                tbSetStall(0, ChCtx_c, 0.0);
                JobReadyStall <= 0.0;
                tbStart(0, Both_c);

                for i in 0 to 9 loop
                    syncClk;
                end loop;

                Zeroize <= '1';
                syncClk;
                Zeroize <= '0';
                tbWaitDone(0, ChSink_c, 500_000 * ClkPeriod_c, "contexts around a zeroize");
                check_value(OcrVec_v.cursor(0, ChSink_c), OcrVec_v.msgCount(0), ERROR, "jobs around a zeroize");

            elsif run("test_load_during_traffic") then
                -- Loads of the last slot while the contexts of the other slots are resolved
                waitIdle;
                tbLoad(0, VecDir_g & "/traffic.txt");
                tbLoad(1, VecDir_g & "/lastslot.txt");
                loadAll(0);
                tbSetStall(0, ChCtx_c, 0.1);
                tbStart(0, Both_c);

                for i in 0 to 19 loop
                    loadKey(1, i mod OcrVec_v.keyCount(1));
                    waitIdle;
                end loop;

                tbWaitDone(0, ChSink_c, 500_000 * ClkPeriod_c, "contexts");
                check_value(OcrVec_v.cursor(0, ChSink_c), OcrVec_v.msgCount(0), ERROR, "jobs checked");
                checkCounters;

            elsif run("test_ecc") then
                -- Single and double errors in the key, H and IV word of the next load and in the next job
                waitIdle;
                tbLoad(0, VecDir_g & "/ecc.txt");

                for m in 0 to 9 loop
                    if m mod 2 = 0 then
                        Pat_v := "01";
                    else
                        Pat_v := "11";
                    end if;
                    Sec0_v := SecCnt(m / 2) + SecCnt(3 + m / 2 mod 3) + SecCnt(6);
                    Ded0_v := DedCnt(m / 2) + DedCnt(3 + m / 2 mod 3) + DedCnt(6);
                    if m / 2 >= 3 then
                        -- Job FIFO: external IV (KEY record 0), then generated IV (KEY record 1)
                        loadKey(0, m / 2 - 3);
                        waitIdle;
                        inject(3, Pat_v);
                    else
                        inject(m / 2, Pat_v);
                        loadKey(0, 0);
                        waitIdle;
                    end if;
                    tbStart(0, Both_c, m + 1);
                    tbWaitDone(0, ChSink_c, 100_000 * ClkPeriod_c, "context " & to_string(m));

                    for i in 0 to 5 loop
                        syncClk;
                    end loop;

                    if m mod 2 = 0 then
                        check_value(SecCnt(m / 2) + SecCnt(3 + m / 2 mod 3) + SecCnt(6) > Sec0_v, ERROR,
                                    "SEC event of memory " & to_string(m / 2));
                    else
                        check_value(DedCnt(m / 2) + DedCnt(3 + m / 2 mod 3) + DedCnt(6) > Ded0_v, ERROR,
                                    "DED event of memory " & to_string(m / 2));
                    end if;
                end loop;

                -- An injection into the key word requested during a load goes into the next load
                loadKey(0, 0);
                inject(0, "01");
                waitIdle;

                for i in 0 to 20 * maximum(2, NumKeys_g) + ScrubCycles_c loop
                    syncClk;
                end loop;

                Sec0_v := SecCnt(0) + SecCnt(3);
                loadKey(0, 0);
                waitIdle;

                for i in 0 to 20 * maximum(2, NumKeys_g) + ScrubCycles_c loop
                    syncClk;
                end loop;

                check_value(SecCnt(0) + SecCnt(3) > Sec0_v, ERROR, "single error in the key word of the next load");

            elsif run("test_scrub") then
                -- The scrubber corrects a single error of a slot that no context reads
                waitIdle;
                tbLoad(0, VecDir_g & "/ecc.txt");
                Sec0_v := SecCnt(3);
                inject(0, "01");
                loadKey(0, 0);
                waitIdle;

                for i in 0 to 20 * maximum(2, NumKeys_g) + ScrubCycles_c loop
                    syncClk;
                end loop;

                check_value(SecCnt(3), Sec0_v + 1, ERROR, "single error found by the scrubber");
                -- The corrected word reads without error
                Sec0_v := SecCnt(0);
                tbStart(0, Both_c, 1);
                tbWaitDone(0, ChSink_c, 100_000 * ClkPeriod_c, "context");
                syncClk;
                syncClk;
                check_value(SecCnt(0), Sec0_v, ERROR, "no error at the read after the scrubber");

            elsif run("test_throughput") then
                -- Contexts in every cycle: one per cycle with external IVs, one per two cycles with generated IVs
                waitIdle;
                tbLoad(0, VecDir_g & "/tp_ext.txt");
                loadAll(0);
                runContexts(0.0);
                N_v    := OcrVec_v.msgCount(0);
                Span_v := (OcrVec_v.lastTime(0,
                                             ChCtx_c) - OcrVec_v.firstTime(0,
                                                                              ChCtx_c)) / ClkPeriod_c;
                check_value(Span_v, N_v - 1, ERROR, "cycles for contexts with external IVs");
                doZeroize;
                tbLoad(0, VecDir_g & "/tp_gen.txt");
                loadAll(0);
                runContexts(0.0);
                N_v    := OcrVec_v.msgCount(0);
                Span_v := (OcrVec_v.lastTime(0,
                                             ChCtx_c) - OcrVec_v.firstTime(0,
                                                                              ChCtx_c)) / ClkPeriod_c;
                check_value(Span_v, 2 * (N_v - 1), ERROR, "cycles for contexts with generated IVs");

            elsif run("test_reset") then
                -- A reset during a load erases all slots: right after the load is accepted (hash subkey request
                -- pending) and one cycle later (waiting for the hash subkey)
                waitIdle;
                tbLoad(0, VecDir_g & "/kt.txt");

                for d in 0 to 1 loop
                    loadAll(0);
                    loadKey(0, 0);
                    if d = 1 then
                        syncClk;
                    end if;
                    Rst <= '1';
                    syncClk;
                    Rst <= '0';
                    waitIdle;

                    for s in 0 to 2 ** SlotBits_c - 1 loop
                        query(s);
                        check_value(Query_KeyValid, '0', ERROR, "slot " & to_string(s) & " erased after the reset");
                    end loop;

                end loop;

            end if;

        end loop;

        ocrTestEnd(runner);
        wait;
    end process;

    i_th : entity work.ocr_key_table_th
        generic map (
            KeyBits_g     => KeyBits_g,
            NumKeys_g     => NumKeys_g,
            ClkFreqHz_g   => ClkFreqHz_g,
            ScrubPeriod_g => ScrubPeriod_g
        )
        port map (
            Clk             => Clk,
            Rst             => Rst,
            Load_Valid      => Load_Valid,
            Load_Ready      => Load_Ready,
            Load_Slot       => Load_Slot,
            Load_Key        => Load_Key,
            Load_IvGen      => Load_IvGen,
            Load_Fixed      => Load_Fixed,
            Load_Counter    => Load_Counter,
            Zeroize         => Zeroize,
            Busy            => Busy,
            Query_Valid     => Query_Valid,
            Query_Ready     => Query_Ready,
            Query_Slot      => Query_Slot,
            Query_OutValid  => Query_OutValid,
            Query_KeyValid  => Query_KeyValid,
            Query_IvGen     => Query_IvGen,
            Query_Exhausted => Query_Exhausted,
            Query_Fixed     => Query_Fixed,
            Query_Counter   => Query_Counter,
            Query_Ded       => Query_Ded,
            Ecc_Sec         => Ecc_Sec,
            Ecc_Ded         => Ecc_Ded,
            ErrInj_Sel      => ErrInj_Sel,
            ErrInj_BitFlip  => ErrInj_BitFlip,
            ErrInj_Valid    => ErrInj_Valid,
            AuxRequests     => AuxRequests,
            JobReadyStall   => JobReadyStall
        );

end architecture;
