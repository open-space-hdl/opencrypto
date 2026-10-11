---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Keystream of the GCM data path (IN-2, AE-1): the AES engine with the requests of the input parser
-- (keystream blocks and J0) and of the key table (hash subkeys), which have priority. The engine has a
-- fixed latency and no back-pressure, so every destination has credits: a request is accepted only
-- when its FT FIFO (keystream, J0) or its result register (hash subkey) has room for the result.
--
-- Documentation: hdl/ocr_gcm/docs/architecture.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_ft_pkg_ecc.all;

library work;
    use work.ocr_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_gcm_keystream is
    generic (
        KeyBits_g : positive := 256;
        Units_g   : positive := 14;
        KsDepth_g : positive := 32;
        J0Depth_g : positive := 32
    );
    port (
        -- Control
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        -- Requests of the input parser; Dest '0' keystream block, '1' J0
        S_Req_Valid       : in    std_logic;
        S_Req_Ready       : out   std_logic;
        S_Req_Key         : in    std_logic_vector(KeyBits_g - 1 downto 0);
        S_Req_Block       : in    Block_t;
        S_Req_Dest        : in    std_logic;
        -- Hash subkey requests of the key table: CIPH_K(0^128)
        S_Aux_Valid       : in    std_logic;
        S_Aux_Ready       : out   std_logic;
        S_Aux_Key         : in    std_logic_vector(KeyBits_g - 1 downto 0);
        M_Aux_Valid       : out   std_logic;
        M_Aux_Ready       : in    std_logic;
        M_Aux_Block       : out   Block_t;
        -- Keystream blocks and J0 results, in the order of the requests
        M_Ks_Valid        : out   std_logic;
        M_Ks_Ready        : in    std_logic;
        M_Ks_Block        : out   Block_t;
        M_Ks_EccSec       : out   std_logic;
        M_Ks_EccDed       : out   std_logic;
        M_J0_Valid        : out   std_logic;
        M_J0_Ready        : in    std_logic;
        M_J0_Block        : out   Block_t;
        M_J0_EccSec       : out   std_logic;
        M_J0_EccDed       : out   std_logic;
        -- Error injection into the keystream and J0 FIFOs
        Ks_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(128) - 1 downto 0) := (others => '0');
        Ks_ErrInj_Valid   : in    std_logic                                            := '0';
        J0_ErrInj_BitFlip : in    std_logic_vector(eccCodewordWidth(128) - 1 downto 0) := (others => '0');
        J0_ErrInj_Valid   : in    std_logic                                            := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_gcm_keystream is

    constant TagKs_c  : std_logic_vector(1 downto 0) := "00";
    constant TagJ0_c  : std_logic_vector(1 downto 0) := "01";
    constant TagAux_c : std_logic_vector(1 downto 0) := "10";

    type TwoProcess_r is record
        KsCredit : unsigned(log2ceil(KsDepth_g + 1) - 1 downto 0);
        J0Credit : unsigned(log2ceil(J0Depth_g + 1) - 1 downto 0);
        AuxValid : std_logic;  -- hash subkey result waits in the result register
        AuxBusy  : std_logic;  -- hash subkey request in the engine or its result in the register
        AuxBlock : Block_t;
    end record;

    signal r, r_next : TwoProcess_r;

    signal Eng_InValid  : std_logic;
    signal Eng_InReady  : std_logic;
    signal Eng_InKey    : std_logic_vector(KeyBits_g - 1 downto 0);
    signal Eng_InBlock  : Block_t;
    signal Eng_InTag    : std_logic_vector(1 downto 0);
    signal Eng_OutValid : std_logic;
    signal Eng_OutBlock : Block_t;
    signal Eng_OutTag   : std_logic_vector(1 downto 0);
    signal KsF_InValid  : std_logic;
    signal J0F_InValid  : std_logic;
    signal KsF_OutValid : std_logic;
    signal J0F_OutValid : std_logic;

begin

    p_comb : process (all) is
        variable v      : TwoProcess_r;
        variable Aux_v  : boolean;
        variable Req_v  : boolean;
        variable Cred_v : boolean;
    begin
        -- hold variables stable
        v := r;

        -- Hash subkey requests first: they are rare and must not starve behind a continuous data stream
        Aux_v := S_Aux_Valid = '1' and r.AuxBusy = '0';
        if S_Req_Dest = '1' then
            Cred_v := r.J0Credit /= 0;
        else
            Cred_v := r.KsCredit /= 0;
        end if;
        Req_v := not Aux_v and S_Req_Valid = '1' and Cred_v;

        Eng_InValid <= '0';
        Eng_InKey   <= S_Req_Key;
        Eng_InBlock <= S_Req_Block;
        Eng_InTag   <= TagKs_c;
        S_Aux_Ready <= '0';
        S_Req_Ready <= '0';
        if Aux_v then
            -- GCM 7.1 step 1: H = CIPH_K(0^128)
            Eng_InValid <= '1';
            Eng_InKey   <= S_Aux_Key;
            Eng_InBlock <= (others => '0');
            Eng_InTag   <= TagAux_c;
            S_Aux_Ready <= Eng_InReady;
            if Eng_InReady = '1' then
                v.AuxBusy := '1';
            end if;
        else
            if S_Req_Dest = '1' then
                Eng_InTag <= TagJ0_c;
            end if;
            if Cred_v then
                Eng_InValid <= S_Req_Valid;
                S_Req_Ready <= Eng_InReady;
            end if;
        end if;

        -- Credits: taken by an accepted request, returned when its result leaves the FIFO
        if Req_v and Eng_InReady = '1' then
            if S_Req_Dest = '1' then
                v.J0Credit := v.J0Credit - 1;
            else
                v.KsCredit := v.KsCredit - 1;
            end if;
        end if;
        if KsF_OutValid = '1' and M_Ks_Ready = '1' then
            v.KsCredit := v.KsCredit + 1;
        end if;
        if J0F_OutValid = '1' and M_J0_Ready = '1' then
            v.J0Credit := v.J0Credit + 1;
        end if;

        -- Results to their destination
        KsF_InValid <= '0';
        J0F_InValid <= '0';
        if Eng_OutValid = '1' then

            case Eng_OutTag is
                when TagKs_c => KsF_InValid <= '1';
                when TagJ0_c => J0F_InValid <= '1';
                when others =>
                    v.AuxValid := '1';
                    v.AuxBlock := Eng_OutBlock;
            end case;

        end if;
        if r.AuxValid = '1' and M_Aux_Ready = '1' then
            v.AuxValid := '0';
            v.AuxBusy  := '0';
        end if;
        M_Aux_Valid <= r.AuxValid;
        M_Aux_Block <= r.AuxBlock;

        -- assign signal
        r_next <= v;
    end process;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.KsCredit <= to_unsigned(KsDepth_g, r.KsCredit'length);
                r.J0Credit <= to_unsigned(J0Depth_g, r.J0Credit'length);
                r.AuxValid <= '0';
                r.AuxBusy  <= '0';
            end if;
        end if;
    end process;

    i_aes : entity work.ocr_aes_engine
        generic map (
            KeyBits_g  => KeyBits_g,
            Units_g    => Units_g,
            TagWidth_g => 2
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Valid  => Eng_InValid,
            In_Ready  => Eng_InReady,
            In_Key    => Eng_InKey,
            In_Block  => Eng_InBlock,
            In_Tag    => Eng_InTag,
            Out_Valid => Eng_OutValid,
            Out_Block => Eng_OutBlock,
            Out_Tag   => Eng_OutTag
        );

    -- The credits guarantee room for every result: the FIFOs never refuse a write
    i_ks_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => 128,
            Depth_g => KsDepth_g
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => Eng_OutBlock,
            In_Valid          => KsF_InValid,
            In_Ready          => open,
            Out_Data          => M_Ks_Block,
            Out_Valid         => KsF_OutValid,
            Out_Ready         => M_Ks_Ready,
            Out_EccSec        => M_Ks_EccSec,
            Out_EccDed        => M_Ks_EccDed,
            In_ErrInj_BitFlip => Ks_ErrInj_BitFlip,
            In_ErrInj_Valid   => Ks_ErrInj_Valid
        );

    i_j0_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => 128,
            Depth_g => J0Depth_g
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => Eng_OutBlock,
            In_Valid          => J0F_InValid,
            In_Ready          => open,
            Out_Data          => M_J0_Block,
            Out_Valid         => J0F_OutValid,
            Out_Ready         => M_J0_Ready,
            Out_EccSec        => M_J0_EccSec,
            Out_EccDed        => M_J0_EccDed,
            In_ErrInj_BitFlip => J0_ErrInj_BitFlip,
            In_ErrInj_Valid   => J0_ErrInj_Valid
        );

    M_Ks_Valid <= KsF_OutValid;
    M_J0_Valid <= J0F_OutValid;

end architecture;
