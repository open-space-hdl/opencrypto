---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Context source model: sends one context per message of its vector set (direction, key slot, IV
-- source and IV) with random cycles without valid and Pause cycles without valid after every context.
-- Counts the cycles in which the receiver does not accept a context (gaps); an abort (reset tests)
-- drops the context in transfer.
--
-- What this model does NOT check or reproduce: it does not check the handshake of the receiver beyond
-- waiting for ready.
--
-- Documentation: docs/conventions.md (section Verification)

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

library work;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_tb_ctx_source is
    generic (
        Set_g      : natural  := 0;
        Channel_g  : natural  := ChCtx_c;
        SlotBits_g : positive := 2;
        Seed_g     : positive := 3;
        -- Decryption contexts for the encryptions of the set (second core of two cores in series)
        Decrypt_g  : boolean  := false
    );
    port (
        Clk         : in    std_logic;
        -- Cycles without valid after every context
        Pause       : in    natural := 0;
        Ctx_Valid   : out   std_logic;
        Ctx_Ready   : in    std_logic;
        Ctx_Decrypt : out   std_logic;
        Ctx_Slot    : out   std_logic_vector(SlotBits_g - 1 downto 0);
        Ctx_IvGen   : out   std_logic;
        Ctx_Iv      : out   std_logic_vector(95 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_tb_ctx_source is

begin

    p_source : process is
        variable Seed1_v : positive := 31 + Seed_g;
        variable Seed2_v : positive := 2003 + 5 * Seed_g;
        variable Rand_v  : real;
        variable M_v     : natural;
    begin
        Ctx_Valid   <= '0';
        Ctx_Decrypt <= '0';
        Ctx_Slot    <= (others => '0');
        Ctx_IvGen   <= '0';
        Ctx_Iv      <= (others => '0');
        wait until rising_edge(Clk);

        loop
            M_v := OcrVec_v.cursor(Set_g, Channel_g);
            if M_v >= OcrVec_v.limit(Set_g, Channel_g) then
                Ctx_Valid <= '0';
                wait until rising_edge(Clk);
            else

                loop
                    uniform(Seed1_v, Seed2_v, Rand_v);
                    exit when Rand_v >= OcrVec_v.stall(Set_g, Channel_g);
                    Ctx_Valid <= '0';
                    wait until rising_edge(Clk);
                end loop;

                if OcrVec_v.msgDec(Set_g, M_v) or Decrypt_g then
                    Ctx_Decrypt <= '1';
                else
                    Ctx_Decrypt <= '0';
                end if;
                Ctx_Slot <= std_logic_vector(to_unsigned(OcrVec_v.msgSlot(Set_g, M_v), SlotBits_g));
                if OcrVec_v.msgIvGen(Set_g, M_v) then
                    Ctx_IvGen <= '1';
                else
                    Ctx_IvGen <= '0';
                end if;
                Ctx_Iv <= OcrVec_v.msgIv(Set_g, M_v);
                if Decrypt_g then
                    Ctx_IvGen <= '0';
                    Ctx_Iv    <= OcrVec_v.stsIv(Set_g, M_v);
                end if;
                Ctx_Valid <= '1';

                loop
                    wait until rising_edge(Clk);
                    exit when Ctx_Ready = '1' or OcrVec_v.getAbort(Set_g, Channel_g);
                    OcrVec_v.addGap(Set_g, Channel_g);
                end loop;

                OcrVec_v.clearAbort(Set_g, Channel_g);
                OcrVec_v.addBeat(Set_g, Channel_g, now);
                Ctx_Valid <= '0';
                OcrVec_v.advance(Set_g, Channel_g);

                for i in 1 to Pause loop
                    wait until rising_edge(Clk);
                end loop;

            end if;
        end loop;

    end process;

end architecture;
