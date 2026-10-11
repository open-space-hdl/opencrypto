---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocr_ghash: S of the GCM test cases and of random messages of pycryptodome (empty and
-- partial sections, both directions), random stalls on both sides, the throughput bound of
-- max(beats + 1, steps * (blocks + 1)) cycles per message, the length error and the reset.
--
-- Documentation: hdl/ocr_ghash/docs/verification_plan.md

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
entity ocr_ghash_tb is
    generic (
        runner_cfg  : string;
        DataWidth_g : positive := 32;
        Digit_g     : positive := 64;
        LenBits_g   : positive := 32;
        VecSpec_g   : string;
        VecRand_g   : string
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_ghash_tb is

    constant ClkPeriod_c : time     := 10 ns;
    constant Bytes_c     : positive := DataWidth_g / 8;
    constant Steps_c     : positive := 128 / Digit_g;
    -- Source, H source and checker
    constant All_c       : std_logic_vector(TbChannels_c - 1 downto 0) := x"07";

    signal Clk : std_logic;
    signal Rst : std_logic := '1';

    -- Cycles that the GHASH needs for a message at most (D5): one per beat plus the length block, or the
    -- steps of the multiplier for every block and the length block
    impure function budget (m : natural) return natural is
        variable A_v      : natural;
        variable C_v      : natural;
        variable HasA_v   : boolean := false;
        variable HasD_v   : boolean := false;
        variable Beats_v  : natural;
        variable Blocks_v : natural;
    begin
        A_v := OcrVec_v.stsAad(0, m);
        C_v := OcrVec_v.stsData(0, m);

        for s in 0 to OcrVec_v.inCount(0, m) - 1 loop
            if OcrVec_v.inCode(0, m, s) = 'A' then
                HasA_v := true;
            elsif OcrVec_v.inCode(0, m, s) = 'D' then
                HasD_v := true;
            end if;
        end loop;

        Beats_v := 0;
        if HasA_v then
            Beats_v := tbBeats(A_v, Bytes_c);
        end if;
        if HasD_v or not HasA_v then
            Beats_v := Beats_v + tbBeats(C_v, Bytes_c);
        end if;
        Blocks_v := (A_v + 15) / 16 + (C_v + 15) / 16;
        return maximum(Beats_v + 1, Steps_c * (Blocks_v + 1));
    end function;

begin

    test_runner_watchdog(runner, 50 ms);

    p_main : process is
        variable N_v      : natural;
        variable Budget_v : natural;
        variable Span_v   : natural;
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);
        wait for 5 * ClkPeriod_c;
        wait until rising_edge(Clk);
        Rst <= '0';
        wait until rising_edge(Clk);

        while test_suite loop

            if run("test_gcm_spec") then
                -- Test cases of the GCM specification, encryption and decryption
                tbLoad(0, VecSpec_g);
                tbStart(0, All_c);
                tbWaitDone(0, ChSink_c, 1 ms, "GCM test cases");
                check_value(OcrVec_v.cursor(0, ChSink_c), OcrVec_v.msgCount(0), ERROR, "results");

            elsif run("test_random") then
                -- Random messages with random stalls of the source and of the receiver of S
                tbLoad(0, VecRand_g);
                tbSetStall(0, ChSource_c, 0.3);
                tbSetStall(0, ChSink_c, 0.5);
                tbStart(0, All_c);
                tbWaitDone(0, ChSink_c, 20 ms, "random messages");
                check_value(OcrVec_v.cursor(0, ChSink_c), OcrVec_v.msgCount(0), ERROR, "results");

            elsif run("test_throughput") then
                -- Back-to-back messages: the GHASH needs at most the budget of every message
                tbLoad(0, VecRand_g);
                N_v      := OcrVec_v.msgCount(0);
                Budget_v := 0;

                for m in 0 to N_v - 1 loop
                    Budget_v := Budget_v + budget(m);
                end loop;

                OcrVec_v.clearStats(0, ChSource_c);
                tbStart(0, All_c);
                tbWaitDone(0, ChSink_c, 20 ms, "random messages");
                check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "results");
                Span_v := (OcrVec_v.lastTime(0,
                                             ChSource_c) - OcrVec_v.firstTime(0,
                                                                                 ChSource_c)) / ClkPeriod_c + 1;
                log(ID_SEQUENCER, "beats " & to_string(OcrVec_v.beats(0, ChSource_c)) & ", cycles " &
                    to_string(Span_v) & ", budget " & to_string(Budget_v));
                check_value(Span_v <= Budget_v, ERROR, "cycles of the input within the budget");

            elsif run("test_length_error") then
                -- Sections longer than 2^LenBits_g - 1 bytes: length error, saturated byte counts
                tbLoad(0, VecRand_g);
                tbStart(0, All_c);
                tbWaitDone(0, ChSink_c, 20 ms, "random messages");
                check_value(OcrVec_v.cursor(0, ChSink_c), OcrVec_v.msgCount(0), ERROR, "results");

            elsif run("test_reset") then
                -- A reset in the middle of the messages; afterwards the messages from the next one on are correct
                tbLoad(0, VecRand_g);
                N_v := OcrVec_v.msgCount(0);
                tbStart(0, All_c);
                wait for 200 * ClkPeriod_c;
                wait until rising_edge(Clk);
                wait for 1 ns;
                -- Abort the sources, ignore the results of the current messages and reset
                OcrVec_v.setLimit(0, ChSink_c, OcrVec_v.cursor(0, ChSink_c));
                OcrVec_v.setLimit(0, ChSource_c, OcrVec_v.cursor(0, ChSource_c) + 1);
                OcrVec_v.setLimit(0, ChCtx_c, OcrVec_v.cursor(0, ChCtx_c) + 1);
                OcrVec_v.setAbort(0, ChSource_c);
                OcrVec_v.setAbort(0, ChCtx_c);
                Rst <= '1';
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);
                wait for 1 ns;
                Rst <= '0';
                wait for 100 * ClkPeriod_c;
                -- All models continue with the message after the aborted one
                OcrVec_v.clearAbort(0, ChSource_c);
                OcrVec_v.clearAbort(0, ChCtx_c);
                OcrVec_v.setCursor(0, ChCtx_c, OcrVec_v.cursor(0, ChSource_c));
                OcrVec_v.setCursor(0, ChSink_c, OcrVec_v.cursor(0, ChSource_c));
                tbStart(0, All_c);
                tbWaitDone(0, ChSink_c, 20 ms, "messages after the reset");
                check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "results");
            end if;

        end loop;

        ocrTestEnd(runner);
        wait;
    end process;

    i_th : entity work.ocr_ghash_th
        generic map (
            DataWidth_g => DataWidth_g,
            Digit_g     => Digit_g,
            LenBits_g   => LenBits_g
        )
        port map (
            Clk => Clk,
            Rst => Rst
        );

end architecture;
