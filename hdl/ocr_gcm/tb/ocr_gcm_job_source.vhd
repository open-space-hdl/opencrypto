---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Job source model of the GCM data path: sends one job per message of its vector set with the key
-- and the hash subkey of the key slot of the message (KEY records), the IV (for a generated IV the IV
-- that the vector file expects), the IV section flag, and the context error when the message has the
-- job error flag (the expected status code). Random cycles without valid.
--
-- What this model does NOT check or reproduce: it does not resolve key slots like the key table (slot
-- validity, IV construction, IV generation); these come from the vector file.
--
-- Documentation: hdl/ocr_gcm/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

library work;
    use work.ocr_pkg.all;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_gcm_job_source is
    generic (
        Set_g      : natural  := 0;
        Channel_g  : natural  := ChCtx_c;
        KeyBits_g  : positive := 256;
        SlotBits_g : positive := 2;
        Seed_g     : positive := 5
    );
    port (
        Clk         : in    std_logic;
        Job_Valid   : out   std_logic;
        Job_Ready   : in    std_logic;
        Job_Decrypt : out   std_logic;
        Job_Key     : out   std_logic_vector(KeyBits_g - 1 downto 0);
        Job_H       : out   Block_t;
        Job_Iv      : out   std_logic_vector(95 downto 0);
        Job_IvOut   : out   std_logic;
        Job_Err     : out   Status_t;
        Job_Slot    : out   std_logic_vector(SlotBits_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_gcm_job_source is

begin

    p_source : process is
        variable Seed1_v : positive := 41 + Seed_g;
        variable Seed2_v : positive := 5003 + 13 * Seed_g;
        variable Rand_v  : real;
        variable M_v     : natural;
        variable K_v     : natural;
        variable Key_v   : std_logic_vector(255 downto 0);
    begin
        Job_Valid   <= '0';
        Job_Decrypt <= '0';
        Job_Key     <= (others => '0');
        Job_H       <= (others => '0');
        Job_Iv      <= (others => '0');
        Job_IvOut   <= '0';
        Job_Err     <= StsOk_c;
        Job_Slot    <= (others => '0');
        wait until rising_edge(Clk);

        loop
            M_v := OcrVec_v.cursor(Set_g, Channel_g);
            if M_v >= OcrVec_v.limit(Set_g, Channel_g) then
                Job_Valid <= '0';
                wait until rising_edge(Clk);
            else

                loop
                    uniform(Seed1_v, Seed2_v, Rand_v);
                    exit when Rand_v >= OcrVec_v.stall(Set_g, Channel_g);
                    Job_Valid <= '0';
                    wait until rising_edge(Clk);
                end loop;

                K_v   := OcrVec_v.keyOfSlot(Set_g, OcrVec_v.msgSlot(Set_g, M_v));
                Key_v := OcrVec_v.keyValue(Set_g, K_v);
                if OcrVec_v.msgDec(Set_g, M_v) then
                    Job_Decrypt <= '1';
                else
                    Job_Decrypt <= '0';
                end if;
                Job_Key <= Key_v(255 downto 256 - KeyBits_g);
                Job_H   <= OcrVec_v.keyHash(Set_g, K_v);
                -- The IV of the status is the IV used, also for a generated IV
                Job_Iv <= OcrVec_v.stsIv(Set_g, M_v);
                if OcrVec_v.msgIvGen(Set_g, M_v) then
                    Job_IvOut <= '1';
                else
                    Job_IvOut <= '0';
                end if;
                if tbFlag(OcrVec_v.msgFlags(Set_g, M_v), FlagJobErr_c) then
                    Job_Err <= std_logic_vector(to_unsigned(OcrVec_v.stsCode(Set_g, M_v), 4));
                else
                    Job_Err <= StsOk_c;
                end if;
                Job_Slot  <= std_logic_vector(to_unsigned(OcrVec_v.msgSlot(Set_g, M_v), SlotBits_g));
                Job_Valid <= '1';

                loop
                    wait until rising_edge(Clk);
                    exit when Job_Ready = '1' or OcrVec_v.getAbort(Set_g, Channel_g);
                end loop;

                OcrVec_v.clearAbort(Set_g, Channel_g);
                Job_Valid <= '0';
                OcrVec_v.advance(Set_g, Channel_g);
            end if;
        end loop;

    end process;

end architecture;
