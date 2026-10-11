---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Test harness of ocr_aes_engine: clock, the engine, a request source that sends the ECB vectors of
-- vector set 0 (random cycles without valid, the vector index as tag) and a result checker that
-- compares every result, its tag and its latency (Nr + 1 cycles) with the vectors.
--
-- What the models do NOT check or reproduce: the request source never changes a request while it waits
-- for ready; results of requests sent before a reset are not expected (the checker restarts with the
-- cursor that the test sets).
--
-- Documentation: hdl/ocr_aes/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library work;
    use work.ocr_pkg.all;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_aes_engine_th is
    generic (
        KeyBits_g : positive := 256;
        Units_g   : positive := 14
    );
    port (
        Clk : out   std_logic;
        Rst : in    std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_aes_engine_th is

    constant ClkPeriod_c : time     := 10 ns;
    constant Nr_c        : positive := aesNr(KeyBits_g);
    constant TagWidth_c  : positive := 12;

    type TimeArr_t is array (0 to 4095) of time;

    signal Clk_i     : std_logic                                 := '0';
    signal In_Valid  : std_logic                                 := '0';
    signal In_Ready  : std_logic;
    signal In_Key    : std_logic_vector(KeyBits_g - 1 downto 0)  := (others => '0');
    signal In_Block  : Block_t                                   := (others => '0');
    signal In_Tag    : std_logic_vector(TagWidth_c - 1 downto 0) := (others => '0');
    signal Out_Valid : std_logic;
    signal Out_Block : Block_t;
    signal Out_Tag   : std_logic_vector(TagWidth_c - 1 downto 0);
    signal AccTime   : TimeArr_t                                 := (others => 0 ns);

begin

    Clk_i <= not Clk_i after ClkPeriod_c / 2;
    Clk   <= Clk_i;

    i_dut : entity work.ocr_aes_engine
        generic map (
            KeyBits_g  => KeyBits_g,
            Units_g    => Units_g,
            TagWidth_g => TagWidth_c
        )
        port map (
            Clk       => Clk_i,
            Rst       => Rst,
            In_Valid  => In_Valid,
            In_Ready  => In_Ready,
            In_Key    => In_Key,
            In_Block  => In_Block,
            In_Tag    => In_Tag,
            Out_Valid => Out_Valid,
            Out_Block => Out_Block,
            Out_Tag   => Out_Tag
        );

    -- Requests: the ECB vectors of set 0 in order
    p_req : process is
        variable Seed1_v : positive := 5;
        variable Seed2_v : positive := 77;
        variable Rand_v  : real;
        variable E_v     : natural;
        variable K_v     : std_logic_vector(255 downto 0);
    begin
        wait until rising_edge(Clk_i);

        loop
            E_v := OcrVec_v.cursor(0, ChSource_c);
            if E_v >= OcrVec_v.limit(0, ChSource_c) or Rst = '1' then
                In_Valid <= '0';
                wait until rising_edge(Clk_i);
            else

                loop
                    uniform(Seed1_v, Seed2_v, Rand_v);
                    exit when Rand_v >= OcrVec_v.stall(0, ChSource_c);
                    In_Valid <= '0';
                    wait until rising_edge(Clk_i);
                end loop;

                K_v      := OcrVec_v.ecbKey(0, E_v);
                In_Key   <= K_v(255 downto 256 - KeyBits_g);
                In_Block <= OcrVec_v.ecbIn(0, E_v);
                In_Tag   <= std_logic_vector(to_unsigned(E_v mod 2 ** TagWidth_c, TagWidth_c));
                In_Valid <= '1';

                loop
                    wait until rising_edge(Clk_i);
                    exit when In_Ready = '1';
                    OcrVec_v.addGap(0, ChSource_c);
                end loop;

                AccTime(E_v mod 4096) <= now;
                OcrVec_v.addBeat(0, ChSource_c, now);
                In_Valid              <= '0';
                OcrVec_v.advance(0, ChSource_c);
            end if;
        end loop;

    end process;

    -- Results: block, tag and latency of every result
    p_chk : process is
        variable E_v : natural;
    begin
        wait until rising_edge(Clk_i);
        if Out_Valid = '1' and Rst = '0' then
            E_v := OcrVec_v.cursor(0, ChSink_c);
            if E_v >= OcrVec_v.limit(0, ChSink_c) then
                alert(ERROR, "unexpected result", "ocr_aes_engine_th");
            else
                check_value(Out_Block, OcrVec_v.ecbOut(0, E_v), ERROR, "result of vector " & to_string(E_v),
                            "ocr_aes_engine_th");
                check_value(to_integer(unsigned(Out_Tag)), E_v mod 2 ** TagWidth_c, ERROR,
                            "tag of vector " & to_string(E_v), "ocr_aes_engine_th");
                check_value(now - AccTime(E_v mod 4096), (Nr_c + 1) * ClkPeriod_c, ERROR,
                            "latency of vector " & to_string(E_v), "ocr_aes_engine_th");
                OcrVec_v.addBeat(0, ChSink_c, now);
                OcrVec_v.advance(0, ChSink_c);
            end if;
        end if;
    end process;

end architecture;
