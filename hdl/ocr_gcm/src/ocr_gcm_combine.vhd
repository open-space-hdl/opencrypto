---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- GCTR combiner of the GCM data path (CT-1): XORs every DATA beat with its part of the keystream
-- block (a partial last block uses its leftmost bytes), passes the AAD, sends the body beats to the
-- output assembly and the AAD and ciphertext beats to GHASH, collects the received tag of a decryption
-- and reports a summary of every message to the tag stage. One entry per clock cycle.
--
-- Documentation: hdl/ocr_gcm/docs/architecture.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.ocr_pkg.all;
    use work.ocr_gcm_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_gcm_combine is
    generic (
        DataWidth_g : positive := 32
    );
    port (
        -- Control
        Clk          : in    std_logic;
        Rst          : in    std_logic;
        -- Data FIFO
        S_Dat_Valid  : in    std_logic;
        S_Dat_Ready  : out   std_logic;
        S_Dat_Data   : in    std_logic_vector(datWidth(DataWidth_g) - 1 downto 0);
        S_Dat_EccDed : in    std_logic;
        -- Keystream FIFO
        S_Ks_Valid   : in    std_logic;
        S_Ks_Ready   : out   std_logic;
        S_Ks_Block   : in    Block_t;
        S_Ks_EccDed  : in    std_logic;
        -- Body beats to the output assembly
        M_Out_Valid  : out   std_logic;
        M_Out_Ready  : in    std_logic;
        M_Out_Data   : out   std_logic_vector(beatWidth(DataWidth_g) - 1 downto 0);
        -- AAD and ciphertext beats to GHASH
        M_Hash_Valid : out   std_logic;
        M_Hash_Ready : in    std_logic;
        M_Hash_Data  : out   std_logic_vector(beatWidth(DataWidth_g) - 1 downto 0);
        -- Summary of every message to the tag stage
        M_Sum_Valid  : out   std_logic;
        M_Sum_Ready  : in    std_logic;
        M_Sum_Data   : out   std_logic_vector(SummaryWidth_c - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_gcm_combine is

    constant Bytes_c : positive := DataWidth_g / 8;
    constant Beats_c : positive := 128 / DataWidth_g;

    type TwoProcess_r is record
        TagIdx : unsigned(4 downto 0);
        RxTag  : Block_t;
        EccErr : std_logic;
    end record;

    signal r, r_next : TwoProcess_r;

begin

    p_comb : process (all) is
        variable v       : TwoProcess_r;
        variable E_v     : DatEntry_t;
        variable Mask_v  : std_logic_vector(DataWidth_g - 1 downto 0);
        variable In_v    : std_logic_vector(DataWidth_g - 1 downto 0);
        variable Ks_v    : std_logic_vector(DataWidth_g - 1 downto 0);
        variable Res_v   : std_logic_vector(DataWidth_g - 1 downto 0);
        variable Body_v  : boolean;
        variable Empty_v : boolean;
        variable UseKs_v : boolean;
        variable Ok_v    : boolean;
        variable O_v     : BeatEntry_t;
        variable H_v     : BeatEntry_t;
        variable S_v     : Summary_t;
    begin
        -- hold variables stable
        v := r;

        E_v := datUnpack(S_Dat_Data, DataWidth_g);

        -- Lanes without byte enable are zero
        for i in 0 to Bytes_c - 1 loop
            Mask_v(8 * i + 7 downto 8 * i) := (others => E_v.Keep(i));
        end loop;

        In_v := E_v.Data(DataWidth_g - 1 downto 0) and Mask_v;

        -- GCM 6.5 steps 6 and 7: the beat K of the block uses bytes K * Bytes_c to K * Bytes_c + Bytes_c - 1 of
        -- its keystream block; a partial last block uses the leftmost bytes (MSB of the length of the block)
        Ks_v := blockToBeat(S_Ks_Block, to_integer(E_v.K) mod Beats_c, Bytes_c) and Mask_v;

        Empty_v := E_v.Keep(Bytes_c - 1 downto 0) = (Bytes_c - 1 downto 0 => '0');
        UseKs_v := (E_v.Sec = SecData_c and not Empty_v) or E_v.KsPop = '1';
        Body_v  := E_v.Sec = SecAad_c or E_v.Sec = SecData_c;

        if E_v.Sec = SecData_c then
            Res_v := In_v xor Ks_v;
        else
            Res_v := In_v;
        end if;

        -- Output assembly: the body; GHASH: AAD, and the ciphertext (input of a decryption, result of an
        -- encryption). A first TAG beat of a message without body adds an empty body beat.
        O_v.Data                           := (others => '0');
        O_v.Keep                           := (others => '0');
        O_v.Data(DataWidth_g - 1 downto 0) := Res_v;
        O_v.Keep                           := E_v.Keep;
        O_v.Sec                            := E_v.Sec;
        O_v.SecL                           := E_v.SecLast;
        O_v.Last                           := E_v.BodyLast;
        H_v                                := O_v;
        if E_v.Sec = SecAad_c or E_v.Dec = '1' then
            H_v.Data(DataWidth_g - 1 downto 0) := In_v;
        end if;
        if E_v.NoBody = '1' then
            O_v.Data := (others => '0');
            O_v.Keep := (others => '0');
            O_v.Sec  := SecData_c;
            O_v.SecL := '1';
            O_v.Last := '1';
            H_v      := O_v;
        end if;
        M_Out_Data  <= beatPack(O_v, DataWidth_g);
        M_Hash_Data <= beatPack(H_v, DataWidth_g);

        S_v.Dec := E_v.Dec;
        S_v.Rej := E_v.Rej;
        -- A format error is marked on the last entry of its message
        S_v.FmtErr := E_v.FmtErr;
        S_v.EccErr := r.EccErr or S_Dat_EccDed;
        if UseKs_v then
            S_v.EccErr := S_v.EccErr or S_Ks_EccDed;
        end if;
        S_v.RxTag := r.RxTag;
        if E_v.Sec = SecTag_c then
            -- The received tag, its first byte in lane 0 of the first TAG beat
            S_v.RxTag := beatToBlock(r.RxTag, E_v.Data(DataWidth_g - 1 downto 0), to_integer(r.TagIdx) mod Beats_c,
                                     Bytes_c);
        end if;
        M_Sum_Data <= sumPack(S_v);

        -- One entry per cycle when everything it needs is available
        Ok_v := S_Dat_Valid = '1';
        if UseKs_v and S_Ks_Valid = '0' then
            Ok_v := false;
        end if;
        if (Body_v or E_v.NoBody = '1') and (M_Out_Ready = '0' or M_Hash_Ready = '0') then
            Ok_v := false;
        end if;
        if E_v.MsgLast = '1' and M_Sum_Ready = '0' then
            Ok_v := false;
        end if;

        S_Dat_Ready  <= '0';
        S_Ks_Ready   <= '0';
        M_Out_Valid  <= '0';
        M_Hash_Valid <= '0';
        M_Sum_Valid  <= '0';
        if Ok_v then
            S_Dat_Ready <= '1';
            if E_v.KsPop = '1' then
                S_Ks_Ready <= '1';
            end if;
            if Body_v or E_v.NoBody = '1' then
                M_Out_Valid  <= '1';
                M_Hash_Valid <= '1';
            end if;
            v.EccErr := S_v.EccErr;
            v.RxTag  := S_v.RxTag;
            if E_v.Sec = SecTag_c then
                v.TagIdx := r.TagIdx + 1;
            end if;
            if E_v.MsgLast = '1' then
                M_Sum_Valid <= '1';
                v.TagIdx    := (others => '0');
                v.RxTag     := (others => '0');
                v.EccErr    := '0';
            end if;
        end if;

        -- assign signal
        r_next <= v;
    end process;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.TagIdx <= (others => '0');
                r.RxTag  <= (others => '0');
                r.EccErr <= '0';
            end if;
        end if;
    end process;

end architecture;
