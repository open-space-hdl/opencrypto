---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Status sink model: compares the status of every message with the expected status of the messages
-- of its vector set (code, direction, key slot, IV, AAD and DATA bytes). Random cycles without ready.
--
-- Byte counts saturate at 2^LenBits_g - 1. What this model does NOT check or reproduce: the byte counts
-- of a message with a format error (the core counts the bytes up to the error).
--
-- Documentation: docs/conventions.md (section Verification)

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
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_tb_sts_sink is
    generic (
        Set_g      : natural  := 0;
        Channel_g  : natural  := ChSts_c;
        SlotBits_g : positive := 2;
        LenBits_g  : positive := 32;
        Seed_g     : positive := 4;
        -- Second core of two cores in series: OK decryptions of the encryptions of the set
        Decrypt_g  : boolean  := false
    );
    port (
        Clk          : in    std_logic;
        In_Valid     : in    std_logic;
        In_Ready     : out   std_logic;
        In_Code      : in    std_logic_vector(3 downto 0);
        In_Decrypt   : in    std_logic;
        In_Slot      : in    std_logic_vector(SlotBits_g - 1 downto 0);
        In_Iv        : in    std_logic_vector(95 downto 0);
        In_AadBytes  : in    std_logic_vector(LenBits_g - 1 downto 0);
        In_DataBytes : in    std_logic_vector(LenBits_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_tb_sts_sink is

begin

    p_sink : process is
        -- Expected status code; the decryption of an encryption of the set is OK
        impure function stsExp (m : natural) return natural is
        begin
            if Decrypt_g then
                return 0;
            end if;
            return OcrVec_v.stsCode(Set_g, m);
        end function;

        variable Seed1_v : positive := 37 + Seed_g;
        variable Seed2_v : positive := 3001 + 11 * Seed_g;
        variable Rand_v  : real;
        variable M_v     : natural;
        variable Dec_v   : std_logic;
        variable Max_v   : natural;
    begin
        if LenBits_g >= 31 then
            Max_v := natural'high;
        else
            Max_v := 2 ** LenBits_g - 1;
        end if;
        In_Ready <= '0';
        wait until rising_edge(Clk);

        loop
            M_v := OcrVec_v.cursor(Set_g, Channel_g);
            uniform(Seed1_v, Seed2_v, Rand_v);
            if Rand_v >= OcrVec_v.stall(Set_g, Channel_g) then
                In_Ready <= '1';
            else
                In_Ready <= '0';
            end if;
            wait until rising_edge(Clk);
            if In_Valid = '1' and In_Ready = '1' then
                if M_v >= OcrVec_v.limit(Set_g, Channel_g) then
                    alert(ERROR, "unexpected status after message " & to_string(M_v), "ocr_tb_sts_sink");
                else
                    if OcrVec_v.msgDec(Set_g, M_v) or Decrypt_g then
                        Dec_v := '1';
                    else
                        Dec_v := '0';
                    end if;
                    check_value(to_integer(unsigned(In_Code)), stsExp(M_v), ERROR,
                                "status code of message " & to_string(M_v), "ocr_tb_sts_sink");
                    check_value(In_Decrypt, Dec_v, ERROR, "direction of message " & to_string(M_v), "ocr_tb_sts_sink");
                    check_value(to_integer(unsigned(In_Slot)), OcrVec_v.msgSlot(Set_g, M_v), ERROR,
                                "key slot of message " & to_string(M_v), "ocr_tb_sts_sink");
                    check_value(In_Iv, OcrVec_v.stsIv(Set_g, M_v), ERROR, "IV of message " & to_string(M_v),
                                "ocr_tb_sts_sink");
                    if stsExp(M_v) /= 2 then
                        check_value(to_integer(unsigned(In_AadBytes)), minimum(OcrVec_v.stsAad(Set_g, M_v), Max_v),
                                    ERROR, "AAD bytes of message " & to_string(M_v), "ocr_tb_sts_sink");
                        check_value(to_integer(unsigned(In_DataBytes)), minimum(OcrVec_v.stsData(Set_g, M_v), Max_v),
                                    ERROR, "DATA bytes of message " & to_string(M_v), "ocr_tb_sts_sink");
                    end if;
                    OcrVec_v.advance(Set_g, Channel_g);
                end if;
            end if;
        end loop;

    end process;

end architecture;
