---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- AES engine (forward cipher, FIPS 197): Units_g iterative round units dispatched in round robin.
-- Every request carries its key, the units expand the round keys on the fly. The latency is Nr + 1
-- clock cycles; results leave in the order of the requests, one per cycle at most, without
-- back-pressure. Throughput: Units_g / Nr blocks per clock cycle.
--
-- Documentation: hdl/ocr_aes/docs/architecture.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library olo;
    use olo.olo_base_pkg_math.all;

library work;
    use work.ocr_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_aes_engine is
    generic (
        KeyBits_g  : positive range 128 to 256 := 256;
        Units_g    : positive range 1 to 14    := 14;
        TagWidth_g : positive                  := 2
    );
    port (
        -- Control
        Clk       : in    std_logic;
        Rst       : in    std_logic;
        -- Requests
        In_Valid  : in    std_logic;
        In_Ready  : out   std_logic;
        In_Key    : in    std_logic_vector(KeyBits_g - 1 downto 0);
        In_Block  : in    Block_t;
        In_Tag    : in    std_logic_vector(TagWidth_g - 1 downto 0);
        -- Results (Nr + 1 cycles after the request, no back-pressure)
        Out_Valid : out   std_logic;
        Out_Block : out   Block_t;
        Out_Tag   : out   std_logic_vector(TagWidth_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_aes_engine is

    constant Nr_c      : positive := aesNr(KeyBits_g);
    constant PtrBits_c : positive := log2ceil(Units_g + 1);

    type BlockArr_t is array (0 to Units_g - 1) of Block_t;

    type TagArr_t is array (0 to Units_g - 1) of std_logic_vector(TagWidth_g - 1 downto 0);

    type TwoProcess_r is record
        Ptr      : unsigned(PtrBits_c - 1 downto 0);
        OutValid : std_logic;
        OutBlock : Block_t;
        OutTag   : std_logic_vector(TagWidth_g - 1 downto 0);
    end record;

    signal r, r_next : TwoProcess_r;

    signal Start    : std_logic_vector(Units_g - 1 downto 0);
    signal Busy     : std_logic_vector(Units_g - 1 downto 0);
    signal Done     : std_logic_vector(Units_g - 1 downto 0);
    signal Result   : BlockArr_t;
    signal ResTag   : TagArr_t;
    signal StartSt  : Block_t;
    signal StartWin : std_logic_vector(KeyBits_g - 1 downto 0);

begin

    assert KeyBits_g = 128 or KeyBits_g = 192 or KeyBits_g = 256
        report "ocr_aes_engine: KeyBits_g must be 128, 192 or 256"
        severity failure;
    assert Units_g <= Nr_c
        report "ocr_aes_engine: Units_g must not exceed the number of rounds"
        severity failure;

    -- AES 5.1: AddRoundKey of round 0 (round key w[0] to w[3]); AES 5.2: window of round 1
    StartSt  <= In_Block xor In_Key(KeyBits_g - 1 downto KeyBits_g - 128);
    StartWin <= aesKeyFirst(In_Key);

    p_comb : process (all) is
        variable v      : TwoProcess_r;
        variable Free_v : std_logic;
        variable Blk_v  : Block_t;
        variable Tag_v  : std_logic_vector(TagWidth_g - 1 downto 0);
    begin
        -- hold variables stable
        v := r;

        -- The unit of the round-robin pointer is free when it is idle or runs its last round
        Free_v := '0';
        Start  <= (others => '0');

        for u in 0 to Units_g - 1 loop
            if r.Ptr = u then
                Free_v := not Busy(u) or Done(u);
                if In_Valid = '1' and Free_v = '1' then
                    Start(u) <= '1';
                end if;
            end if;
        end loop;

        In_Ready <= Free_v;

        if In_Valid = '1' and Free_v = '1' then
            if r.Ptr >= Units_g - 1 then
                v.Ptr := (others => '0');
            else
                v.Ptr := r.Ptr + 1;
            end if;
        end if;

        -- At most one unit finishes per cycle (one start per cycle, Nr cycles per block)
        Blk_v := (others => '0');
        Tag_v := (others => '0');

        for u in 0 to Units_g - 1 loop
            if Done(u) = '1' then
                Blk_v := Blk_v or Result(u);
                Tag_v := Tag_v or ResTag(u);
            end if;
        end loop;

        v.OutValid := or Done;
        v.OutBlock := Blk_v;
        v.OutTag   := Tag_v;

        Out_Valid <= r.OutValid;
        Out_Block <= r.OutBlock;
        Out_Tag   <= r.OutTag;

        -- assign signal
        r_next <= v;
    end process;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Ptr      <= (others => '0');
                r.OutValid <= '0';
            end if;
        end if;
    end process;

    g_unit : for u in 0 to Units_g - 1 generate

        i_unit : entity work.ocr_aes_unit
            generic map (
                KeyBits_g  => KeyBits_g,
                TagWidth_g => TagWidth_g
            )
            port map (
                Clk      => Clk,
                Rst      => Rst,
                Start    => Start(u),
                StartSt  => StartSt,
                StartWin => StartWin,
                StartTag => In_Tag,
                Busy     => Busy(u),
                Done     => Done(u),
                Result   => Result(u),
                ResTag   => ResTag(u)
            );

    end generate;

end architecture;
