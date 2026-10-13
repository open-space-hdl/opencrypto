---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Message source model: sends the input sections of the messages of its vector set as an
-- AXI4-Stream with the section code in TUser (IV "11", AAD "01", DATA "00", TAG "10"), every section
-- starting with a new beat, only the last beat of a section partial and TLast on the last beat of the
-- message. Random cycles without valid; lanes without byte enable carry random data. Counts the
-- cycles in which it presents a beat that the receiver does not accept (gaps). A section code in lower
-- case sends the section with byte enables that are not contiguous from lane 0 in its last beat
-- (format error tests). Out_Err is '1' on the last beat of a message whose expected status is not OK
-- (output packer bench). With Plain_g the source sends packets for the framer: the bytes of the
-- messages without section code, TLast only on the last beat of a message with the flag FlagImgEnd_c,
-- so that the messages of one packet (its chunks) form one stream packet.
--
-- What this model does NOT check or reproduce: it does not check the handshake of the receiver beyond
-- waiting for ready; it sends the sections of the vector file as they are, so malformed messages come
-- only from the vector file.
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
entity ocr_tb_msg_source is
    generic (
        Set_g       : natural  := 0;
        Channel_g   : natural  := ChSource_c;
        DataWidth_g : positive := 32;
        Seed_g      : positive := 1;
        Plain_g     : boolean  := false
    );
    port (
        Clk       : in    std_logic;
        Out_Valid : out   std_logic;
        Out_Ready : in    std_logic;
        Out_Data  : out   std_logic_vector(DataWidth_g - 1 downto 0);
        Out_Keep  : out   std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        Out_Last  : out   std_logic;
        Out_User  : out   std_logic_vector(1 downto 0);
        Out_Err   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_tb_msg_source is

    constant Bytes_c : positive := DataWidth_g / 8;

    function secCode (c : character) return std_logic_vector is
    begin

        case c is
            when 'I' | 'i' => return "11";
            when 'A' | 'a' => return "01";
            when 'T' | 't' => return "10";
            when others => return "00";
        end case;

    end function;

begin

    p_source : process is
        variable Seed1_v : positive := 17 + Seed_g;
        variable Seed2_v : positive := 4711 + 3 * Seed_g;
        variable Rand_v  : real;
        variable M_v     : natural;
        variable Len_v   : natural;
        variable Beats_v : natural;
        variable Idx_v   : natural;
        variable NSec_v  : natural;
        variable Abort_v : boolean;
    begin
        Out_Valid <= '0';
        Out_Last  <= '0';
        Out_Data  <= (others => '0');
        Out_Keep  <= (others => '0');
        Out_User  <= (others => '0');
        Out_Err   <= '0';
        wait until rising_edge(Clk);

        loop
            M_v := OcrVec_v.cursor(Set_g, Channel_g);
            if M_v >= OcrVec_v.limit(Set_g, Channel_g) then
                Out_Valid <= '0';
                wait until rising_edge(Clk);
            else
                NSec_v  := OcrVec_v.inCount(Set_g, M_v);
                Abort_v := false;

                l_sections : for s in 0 to NSec_v - 1 loop
                    Len_v   := OcrVec_v.inLen(Set_g, M_v, s);
                    Beats_v := tbBeats(Len_v, Bytes_c);

                    for b in 0 to Beats_v - 1 loop

                        -- Random cycles without valid
                        loop
                            uniform(Seed1_v, Seed2_v, Rand_v);
                            exit when Rand_v >= OcrVec_v.stall(Set_g, Channel_g);
                            Out_Valid <= '0';
                            wait until rising_edge(Clk);
                        end loop;

                        for i in 0 to Bytes_c - 1 loop
                            Idx_v := b * Bytes_c + i;
                            if Idx_v < Len_v then
                                Out_Data(8 * i + 7 downto 8 * i) <= OcrVec_v.inByte(Set_g, M_v, s, Idx_v);
                                Out_Keep(i)                      <= '1';
                            else
                                uniform(Seed1_v, Seed2_v, Rand_v);
                                Out_Data(8 * i + 7 downto 8 * i) <= std_logic_vector(to_unsigned(integer(Rand_v * 255.0), 8));
                                Out_Keep(i)                      <= '0';
                            end if;
                        end loop;

                        -- Lower case section: byte enables of the last beat shifted by one lane
                        if b = Beats_v - 1 and OcrVec_v.inCode(Set_g, M_v, s) >= 'a' then

                            for i in Bytes_c - 1 downto 1 loop
                                if b * Bytes_c + i - 1 < Len_v then
                                    Out_Keep(i) <= '1';
                                else
                                    Out_Keep(i) <= '0';
                                end if;
                            end loop;

                            Out_Keep(0) <= '0';
                        end if;
                        Out_Err <= '0';
                        if s = NSec_v - 1 and b = Beats_v - 1 then
                            if not Plain_g or tbFlag(OcrVec_v.msgFlags(Set_g, M_v), FlagImgEnd_c) then
                                Out_Last <= '1';
                            else
                                Out_Last <= '0';
                            end if;
                            if OcrVec_v.stsCode(Set_g, M_v) /= 0 then
                                Out_Err <= '1';
                            end if;
                        else
                            Out_Last <= '0';
                        end if;
                        if Plain_g then
                            Out_User <= "00";
                        else
                            Out_User <= secCode(OcrVec_v.inCode(Set_g, M_v, s));
                        end if;
                        Out_Valid <= '1';

                        loop
                            wait until rising_edge(Clk);
                            exit when Out_Ready = '1' or OcrVec_v.getAbort(Set_g, Channel_g);
                            OcrVec_v.addGap(Set_g, Channel_g);
                        end loop;

                        OcrVec_v.addBeat(Set_g, Channel_g, now);

                        -- Reset tests: the rest of the message is dropped
                        if OcrVec_v.getAbort(Set_g, Channel_g) then
                            OcrVec_v.clearAbort(Set_g, Channel_g);
                            Out_Valid <= '0';
                            Abort_v   := true;
                            exit l_sections;
                        end if;

                    end loop;

                end loop;

                Out_Valid <= '0';
                OcrVec_v.advance(Set_g, Channel_g);
            end if;
        end loop;

    end process;

end architecture;
