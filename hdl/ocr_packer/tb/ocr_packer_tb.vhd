---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocr_packer: sectioned messages of every section layout against the expected gapless
-- byte stream, with stall cycles on both sides, throughput and reset.
--
-- Documentation: hdl/ocr_packer/docs/verification_plan.md

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
    use work.ocr_tb_pkg.all;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_packer_tb is
    generic (
        runner_cfg  : string;
        DataWidth_g : positive := 32;
        VecDir_g    : string
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_packer_tb is

    constant ClkPeriod_c : time     := 10 ns;
    constant Bytes_c     : positive := DataWidth_g / 8;
    -- Message source and message sink
    constant Models_c    : std_logic_vector(TbChannels_c - 1 downto 0) := x"05";

    signal Clk : std_logic;
    signal Rst : std_logic := '1';

begin

    test_runner_watchdog(runner, 20 ms);

    p_main : process is
        variable N_v : natural;
        variable M_v : natural;

        -- The sequencer acts 1 ns after the clock edge, after the models
        procedure syncClk is
        begin
            wait until rising_edge(Clk);
            wait for 1 ns;
        end procedure;

        -- All messages of a vector file with stall probabilities at the input and at the output
        procedure runSet (
            name     : string;
            stallIn  : real;
            stallOut : real) is
        begin
            tbLoad(0, VecDir_g & "/" & name);
            tbSetStall(0, ChSource_c, stallIn);
            tbSetStall(0, ChSink_c, stallOut);
            OcrVec_v.clearStats(0, ChSource_c);
            OcrVec_v.clearStats(0, ChSink_c);
            tbStart(0, Models_c);
            tbWaitDone(0, ChSink_c, 10 ms, name);
            N_v := OcrVec_v.msgCount(0);
            check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "messages checked at the output of " & name);
        end procedure;

        -- Messages before the last one whose last input beat does not fit into the output beat with the bytes
        -- before it: the packer needs one more output beat for the rest and stalls its input for one cycle. Computed
        -- from the input sections: every section starts with a new beat.
        impure function flushCount return natural is
            variable R_v   : natural := 0;
            variable Res_v : natural;
            variable Tot_v : natural;
            variable Len_v : natural;
            variable K_v   : natural;
        begin

            for m in 0 to OcrVec_v.msgCount(0) - 2 loop
                Res_v := 0;
                Tot_v := 0;

                for s in 0 to OcrVec_v.inCount(0, m) - 1 loop
                    Len_v := OcrVec_v.inLen(0, m, s);

                    for b in 0 to tbBeats(Len_v, Bytes_c) - 1 loop
                        K_v   := minimum(Bytes_c, Len_v - b * Bytes_c);
                        Tot_v := Res_v + K_v;
                        Res_v := Tot_v mod Bytes_c;
                    end loop;

                end loop;

                -- The last beat: residual bytes left after a full beat
                if Tot_v > Bytes_c then
                    R_v := R_v + 1;
                end if;
            end loop;

            return R_v;
        end function;

    -- Test sequence
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);
        wait for 5 * ClkPeriod_c;
        syncClk;
        Rst <= '0';
        syncClk;

        while test_suite loop

            if run("test_pack") then
                -- Every section layout of an output message, gapless at the output, with stall cycles on both sides
                runSet("pack.txt", 0.3, 0.3);
                runSet("pack_long.txt", 0.0, 0.5);

            elsif run("test_backpressure") then
                -- A slow and a fast sink, a slow source
                runSet("pack.txt", 0.0, 0.9);
                runSet("pack.txt", 0.8, 0.0);
                runSet("pack_long.txt", 0.5, 0.5);

            elsif run("test_throughput") then
                -- Without stall cycles the input accepts a beat in every cycle, except one cycle per message that needs
                -- an extra output beat for its last bytes
                runSet("pack_long.txt", 0.0, 0.0);
                log(ID_SEQUENCER, "input beats " & to_string(OcrVec_v.beats(0, ChSource_c)) & ", gaps " &
                    to_string(OcrVec_v.gaps(0, ChSource_c)) & ", messages with an extra beat " &
                    to_string(flushCount));
                check_value(OcrVec_v.gaps(0, ChSource_c) <= flushCount, ERROR, "cycles without input beat");

            elsif run("test_reset") then
                -- A reset in the middle of the messages; afterwards all messages from the next one on are correct
                tbLoad(0, VecDir_g & "/pack_long.txt");
                N_v := OcrVec_v.msgCount(0);
                tbSetStall(0, ChSource_c, 0.1);
                tbSetStall(0, ChSink_c, 0.3);
                tbStart(0, Models_c);

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

                for i in 0 to 20 loop
                    syncClk;
                end loop;

                M_v := OcrVec_v.cursor(0, ChSource_c);

                for ch in 0 to 3 loop
                    OcrVec_v.setCursor(0, ch, M_v);
                    OcrVec_v.clearAbort(0, ch);
                end loop;

                tbStart(0, Models_c);
                tbWaitDone(0, ChSink_c, 10 ms, "messages after the reset");
                check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "messages after the reset");
            end if;

        end loop;

        ocrTestEnd(runner);
        wait;
    end process;

    i_th : entity work.ocr_packer_th
        generic map (
            DataWidth_g => DataWidth_g
        )
        port map (
            Clk => Clk,
            Rst => Rst
        );

end architecture;
