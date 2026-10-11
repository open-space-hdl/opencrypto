---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocr_aes_engine: examples of FIPS 197 and blocks of pycryptodome with single and
-- back-to-back requests, latency, order, throughput of Units_g / Nr blocks per cycle and reset.
--
-- Documentation: hdl/ocr_aes/docs/verification_plan.md

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
entity ocr_aes_engine_tb is
    generic (
        runner_cfg : string;
        KeyBits_g  : positive := 256;
        Units_g    : positive := 14;
        VecEcb_g   : string
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_aes_engine_tb is

    constant ClkPeriod_c : time                                        := 10 ns;
    constant Nr_c        : positive                                    := aesNr(KeyBits_g);
    constant Both_c      : std_logic_vector(TbChannels_c - 1 downto 0) := x"05";  -- source and sink

    signal Clk : std_logic;
    signal Rst : std_logic := '1';

begin

    test_runner_watchdog(runner, 10 ms);

    p_main : process is
        variable N_v    : natural;
        variable Span_v : natural;
        variable Pos_v  : natural;
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);
        tbLoad(0, VecEcb_g);
        N_v := OcrVec_v.ecbCount(0);
        wait for 5 * ClkPeriod_c;
        wait until rising_edge(Clk);
        Rst <= '0';
        wait until rising_edge(Clk);

        while test_suite loop

            if run("test_fips197") then
                -- The examples of FIPS 197 and the blocks of all zeros and all ones, one request at a time
                tbSetStall(0, ChSource_c, 0.95);
                tbStart(0, Both_c, 6);
                tbWaitDone(0, ChSink_c, 1 ms, "FIPS 197 examples");

            elsif run("test_vectors") then
                -- All blocks with random cycles without valid; every request with a new key
                tbSetStall(0, ChSource_c, 0.3);
                tbStart(0, Both_c);
                tbWaitDone(0, ChSink_c, 5 ms, "all vectors");
                check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "results");

            elsif run("test_throughput") then
                -- Requests in every cycle: Units_g requests per Nr cycles
                tbSetStall(0, ChSource_c, 0.0);
                OcrVec_v.clearStats(0, ChSource_c);
                tbStart(0, Both_c);
                tbWaitDone(0, ChSink_c, 5 ms, "all vectors");
                Span_v := ((N_v - 1) / Units_g) * Nr_c + (N_v - 1) mod Units_g;
                check_value(OcrVec_v.beats(0, ChSource_c), N_v, ERROR, "accepted requests");
                check_value((OcrVec_v.lastTime(0, ChSource_c) - OcrVec_v.firstTime(0, ChSource_c)) / ClkPeriod_c,
                            Span_v, ERROR, "cycles from the first to the last request");

            elsif run("test_reset") then
                -- A reset while blocks are in the units: no result of these blocks, normal operation afterwards
                tbSetStall(0, ChSource_c, 0.0);
                tbStart(0, Both_c);
                wait for 3 * Nr_c * ClkPeriod_c;
                -- The models act on the clock edge; the sequencer acts 1 ns later
                wait until rising_edge(Clk);
                wait for 1 ns;
                -- Stop the source after its current request and expect no further result
                OcrVec_v.setLimit(0, ChSource_c, OcrVec_v.cursor(0, ChSource_c) + 1);
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);
                wait for 1 ns;
                OcrVec_v.setLimit(0, ChSink_c, OcrVec_v.cursor(0, ChSink_c));
                Rst <= '1';
                wait until rising_edge(Clk);
                wait until rising_edge(Clk);
                wait for 1 ns;
                Rst <= '0';
                -- No result of the blocks of the reset
                wait for 2 * Nr_c * ClkPeriod_c;
                Pos_v := OcrVec_v.cursor(0, ChSource_c);
                check_value(Pos_v < N_v, ERROR, "vectors left after the reset");
                -- Continue with the next vector
                OcrVec_v.setCursor(0, ChSink_c, Pos_v);
                tbStart(0, Both_c);
                tbWaitDone(0, ChSink_c, 5 ms, "vectors after the reset");
                check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "results after the reset");
            end if;

        end loop;

        ocrTestEnd(runner);
        wait;
    end process;

    i_th : entity work.ocr_aes_engine_th
        generic map (
            KeyBits_g => KeyBits_g,
            Units_g   => Units_g
        )
        port map (
            Clk => Clk,
            Rst => Rst
        );

end architecture;
