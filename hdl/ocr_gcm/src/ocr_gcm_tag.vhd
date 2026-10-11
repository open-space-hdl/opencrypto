---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Tag stage of the GCM data path (TG-1): T = S xor CIPH_K(J0) for every message; the tag of an
-- encryption, the verification of the received tag of a decryption, and the status code of the
-- message from the errors of the data path. One message per clock cycle.
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
entity ocr_gcm_tag is
    generic (
        LenBits_g : positive := 32
    );
    port (
        -- Control
        Clk          : in    std_logic;
        Rst          : in    std_logic;
        -- GHASH result
        S_Gh_Valid   : in    std_logic;
        S_Gh_Ready   : out   std_logic;
        S_Gh_S       : in    Block_t;
        S_Gh_Aad     : in    std_logic_vector(LenBits_g - 1 downto 0);
        S_Gh_Data    : in    std_logic_vector(LenBits_g - 1 downto 0);
        S_Gh_LenErr  : in    std_logic;
        S_Gh_EccErr  : in    std_logic;
        -- Summary of the combiner
        S_Sum_Valid  : in    std_logic;
        S_Sum_Ready  : out   std_logic;
        S_Sum_Data   : in    std_logic_vector(SummaryWidth_c - 1 downto 0);
        S_Sum_EccDed : in    std_logic;
        -- CIPH_K(J0), not for messages that their context rejected
        S_J0_Valid   : in    std_logic;
        S_J0_Ready   : out   std_logic;
        S_J0_Block   : in    Block_t;
        S_J0_EccDed  : in    std_logic;
        -- Result of the message
        M_Res_Valid  : out   std_logic;
        M_Res_Ready  : in    std_logic;
        M_Res_Data   : out   std_logic_vector(ResultWidth_c - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_gcm_tag is

    type TwoProcess_r is record
        Valid : std_logic;
        Res   : std_logic_vector(ResultWidth_c - 1 downto 0);
    end record;

    signal r, r_next : TwoProcess_r;

begin

    p_comb : process (all) is
        variable v     : TwoProcess_r;
        variable Sum_v : Summary_t;
        variable Res_v : Result_t;
        variable T_v   : Block_t;
        variable Go_v  : boolean;
    begin
        -- hold variables stable
        v := r;

        Sum_v := sumUnpack(S_Sum_Data);

        -- GCM 7.1 step 6: T = MSB_128(GCTR_K(J0, S)) = S xor CIPH_K(J0) (CCSDS 3.4.2: t = 128)
        T_v := S_Gh_S xor S_J0_Block;

        Res_v.Code     := StsOk_c;
        Res_v.Tag      := T_v;
        Res_v.AadBytes := resize(unsigned(S_Gh_Aad), 32);
        Res_v.DatBytes := resize(unsigned(S_Gh_Data), 32);
        if Sum_v.Rej = '1' then
            -- The context error of the message is reported by the output assembly
            Res_v.Tag := (others => '0');
        else
            -- GCM 7.2 step 8: FAIL when the computed tag differs from the received one
            if Sum_v.Dec = '1' and T_v /= Sum_v.RxTag then
                Res_v.Code := StsAuth_c;
            end if;
            if S_J0_EccDed = '1' then
                Res_v.Code := stsMerge(Res_v.Code, StsEcc_c);
            end if;
        end if;
        if S_Gh_LenErr = '1' then
            Res_v.Code := stsMerge(Res_v.Code, StsLength_c);
        end if;
        if Sum_v.FmtErr = '1' then
            Res_v.Code := stsMerge(Res_v.Code, StsFormat_c);
        end if;
        -- An uncorrectable error of a buffer that held data of the message
        if Sum_v.EccErr = '1' or S_Sum_EccDed = '1' or S_Gh_EccErr = '1' then
            Res_v.Code := stsMerge(Res_v.Code, StsEcc_c);
        end if;

        -- A message is complete with its GHASH result, its summary and, unless rejected, its J0
        Go_v := S_Gh_Valid = '1' and S_Sum_Valid = '1' and (Sum_v.Rej = '1' or S_J0_Valid = '1') and
                (r.Valid = '0' or M_Res_Ready = '1');

        if r.Valid = '1' and M_Res_Ready = '1' then
            v.Valid := '0';
        end if;
        S_Gh_Ready  <= '0';
        S_Sum_Ready <= '0';
        S_J0_Ready  <= '0';
        if Go_v then
            S_Gh_Ready  <= '1';
            S_Sum_Ready <= '1';
            if Sum_v.Rej = '0' then
                S_J0_Ready <= '1';
            end if;
            v.Valid := '1';
            v.Res   := resPack(Res_v);
        end if;

        M_Res_Valid <= r.Valid;
        M_Res_Data  <= r.Res;

        -- assign signal
        r_next <= v;
    end process;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Valid <= '0';
            end if;
        end if;
    end process;

end architecture;
