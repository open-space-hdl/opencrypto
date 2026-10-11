---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Iterative AES round unit: one round of the cipher per clock cycle on one block, with the key
-- expansion on the fly (the window of the last Nk words of the expansion travels with the block).
-- A unit is busy for Nr cycles per block and can start the next block in the cycle of its last round.
--
-- Documentation: hdl/ocr_aes/docs/architecture.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.ocr_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_aes_unit is
    generic (
        KeyBits_g  : positive := 256;
        TagWidth_g : positive := 2
    );
    port (
        -- Control
        Clk      : in    std_logic;
        Rst      : in    std_logic;
        -- Start of a block: state after the AddRoundKey of round 0 and window of round 1
        Start    : in    std_logic;
        StartSt  : in    Block_t;
        StartWin : in    std_logic_vector(KeyBits_g - 1 downto 0);
        StartTag : in    std_logic_vector(TagWidth_g - 1 downto 0);
        -- Busy: a block is in the unit; Done: the last round runs in this cycle (Result is valid)
        Busy     : out   std_logic;
        Done     : out   std_logic;
        Result   : out   Block_t;
        ResTag   : out   std_logic_vector(TagWidth_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_aes_unit is

    constant Nr_c     : positive       := aesNr(KeyBits_g);
    constant KeyCtl_c : AesKeyCtlArr_t := aesKeyCtlTable(KeyBits_g);

    type TwoProcess_r is record
        Busy  : std_logic;
        Round : unsigned(3 downto 0);
        State : Block_t;
        Win   : std_logic_vector(KeyBits_g - 1 downto 0);
        Tag   : std_logic_vector(TagWidth_g - 1 downto 0);
    end record;

    signal r, r_next : TwoProcess_r;

begin

    p_comb : process (all) is
        variable v       : TwoProcess_r;
        variable Last_v  : std_logic;
        variable Ctl_v   : AesKeyCtl_t;
        variable Round_v : Block_t;
    begin
        -- hold variables stable
        v := r;

        -- Last round: Nr; an illegal count above Nr also ends the block (recovery)
        if r.Round >= Nr_c then
            Last_v := '1';
        else
            Last_v := '0';
        end if;

        -- AES 5.1: one round with the round key in the last four words of the window
        Round_v := aesRound(r.State, r.Win(127 downto 0), Last_v);

        -- AES 5.2: the next four words of the expansion for the round key of the next round
        Ctl_v := KeyCtl_c(to_integer(r.Round));

        if Start = '1' then
            v.Busy  := '1';
            v.Round := to_unsigned(1, 4);
            v.State := StartSt;
            v.Win   := StartWin;
            v.Tag   := StartTag;
        elsif r.Busy = '1' then
            if Last_v = '1' then
                v.Busy := '0';
            else
                v.State := Round_v;
                v.Win   := aesKeyStep(r.Win, Ctl_v);
                v.Round := r.Round + 1;
            end if;
        end if;

        Busy   <= r.Busy;
        Done   <= r.Busy and Last_v;
        Result <= Round_v;
        ResTag <= r.Tag;

        -- assign signal
        r_next <= v;
    end process;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Busy  <= '0';
                r.Round <= (others => '0');
            end if;
        end if;
    end process;

end architecture;
