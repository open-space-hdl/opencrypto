---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Message sink model: receives the output messages of the core and compares every beat with the
-- expected output sections of the messages of its vector set: section code, byte enables, every
-- valid byte, TLast and the error flag (TUser(2), '1' when the expected status is not OK). A message
-- with the expected section 'X' is checked only for its end and its error flag. Random cycles without
-- ready; counts the cycles with ready but without valid while messages are expected (gaps). With
-- Dense_g the expected sections form one gapless byte stream: all bytes valid except in the last beat,
-- TUser(1:0) the section of the first byte of the beat (of the last section for a message without
-- any byte).
--
-- What this model does NOT check or reproduce: the data of lanes without byte enable; the content of
-- messages with the expected section 'X'. On an abort (reset tests) it drops the message it receives and
-- continues, once the test has cleared the abort, at the cursor that the test has set.
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
entity ocr_tb_msg_sink is
    generic (
        Set_g       : natural  := 0;
        Channel_g   : natural  := ChSink_c;
        DataWidth_g : positive := 32;
        Seed_g      : positive := 2;
        -- Second core of two cores in series: the decryption of an encryption of the set gives back its AAD and
        -- DATA input sections, without error flag
        Decrypt_g   : boolean  := false;
        -- Dense output: the sections without gaps
        Dense_g     : boolean  := false
    );
    port (
        Clk      : in    std_logic;
        In_Valid : in    std_logic;
        In_Ready : out   std_logic;
        In_Data  : in    std_logic_vector(DataWidth_g - 1 downto 0);
        In_Keep  : in    std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        In_Last  : in    std_logic;
        In_User  : in    std_logic_vector(2 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_tb_msg_sink is

    constant Bytes_c : positive := DataWidth_g / 8;

    function secCode (c : character) return std_logic_vector is
    begin

        case c is
            when 'I' => return "11";
            when 'A' => return "01";
            when 'T' => return "10";
            when others => return "00";
        end case;

    end function;

begin

    p_sink : process is
        variable Seed1_v   : positive := 23 + Seed_g;
        variable Seed2_v   : positive := 1913 + 7 * Seed_g;
        variable Rand_v    : real;
        variable M_v       : natural;
        variable Len_v     : natural;
        variable Beats_v   : natural;
        variable Idx_v     : natural;
        variable NSec_v    : natural;
        variable Err_v     : std_logic;
        variable Bad_v     : natural;
        variable First_v   : string(1 to 120);
        variable FirstL_v  : natural;
        variable LastExp_v : std_logic;
        variable Started_v : boolean  := false;
        variable Abort_v   : boolean  := false;
        variable Tot_v     : natural;

        -- Waits for the next accepted beat (random ready); counts the gaps
        procedure getBeat is
        begin

            loop
                uniform(Seed1_v, Seed2_v, Rand_v);
                if Rand_v >= OcrVec_v.stall(Set_g, Channel_g) then
                    In_Ready <= '1';
                else
                    In_Ready <= '0';
                end if;
                wait until rising_edge(Clk);
                exit when In_Valid = '1' and In_Ready = '1';
                if OcrVec_v.getAbort(Set_g, Channel_g) then
                    Abort_v := true;
                    exit;
                end if;
                if In_Ready = '1' and Started_v then
                    OcrVec_v.addGap(Set_g, Channel_g);
                end if;
            end loop;

            OcrVec_v.addBeat(Set_g, Channel_g, now);
            Started_v := true;
        end procedure;

        -- Expected sections: the output sections of the vector file, or with Decrypt_g the input sections with bytes
        -- (an encryption without bytes gives back one empty DATA beat)
        impure function expCount (m : natural) return natural is
            variable N_v : natural := 0;
        begin
            if not Decrypt_g then
                return OcrVec_v.outCount(Set_g, m);
            end if;

            for s in 0 to OcrVec_v.inCount(Set_g, m) - 1 loop
                if OcrVec_v.inLen(Set_g, m, s) > 0 then
                    N_v := N_v + 1;
                end if;
            end loop;

            return maximum(N_v, 1);
        end function;

        -- Index of the input section of expected section s (Decrypt_g), -1 for the empty beat
        impure function inSec (
            m : natural;
            s : natural) return integer is
            variable N_v : natural := 0;
        begin

            for i in 0 to OcrVec_v.inCount(Set_g, m) - 1 loop
                if OcrVec_v.inLen(Set_g, m, i) > 0 then
                    if N_v = s then
                        return i;
                    end if;
                    N_v := N_v + 1;
                end if;
            end loop;

            return -1;
        end function;

        impure function expCode (
            m : natural;
            s : natural) return character is
        begin
            if not Decrypt_g then
                return OcrVec_v.outCode(Set_g, m, s);
            elsif inSec(m, s) < 0 then
                return 'D';
            end if;
            return OcrVec_v.inCode(Set_g, m, inSec(m, s));
        end function;

        impure function expLen (
            m : natural;
            s : natural) return natural is
        begin
            if not Decrypt_g then
                return OcrVec_v.outLen(Set_g, m, s);
            elsif inSec(m, s) < 0 then
                return 0;
            end if;
            return OcrVec_v.inLen(Set_g, m, inSec(m, s));
        end function;

        impure function expByte (
            m : natural;
            s : natural;
            i : natural) return std_logic_vector is
        begin
            if not Decrypt_g then
                return OcrVec_v.outByte(Set_g, m, s, i);
            end if;
            return OcrVec_v.inByte(Set_g, m, inSec(m, s), i);
        end function;

        -- Dense output: number of bytes of all expected sections
        impure function totalLen (m : natural) return natural is
            variable N_v : natural := 0;
        begin

            for s in 0 to expCount(m) - 1 loop
                N_v := N_v + expLen(m, s);
            end loop;

            return N_v;
        end function;

        -- Dense output: section index of byte g of the message (the last section for g beyond the bytes)
        impure function secOf (
            m : natural;
            g : natural) return natural is
            variable N_v : natural := 0;
        begin

            for s in 0 to expCount(m) - 1 loop
                if g < N_v + expLen(m, s) then
                    return s;
                end if;
                N_v := N_v + expLen(m, s);
            end loop;

            return expCount(m) - 1;
        end function;

        -- Dense output: byte g of the message
        impure function denseByte (
            m : natural;
            g : natural) return std_logic_vector is
            variable N_v : natural := 0;
        begin

            for s in 0 to expCount(m) - 1 loop
                if g < N_v + expLen(m, s) then
                    return expByte(m, s, g - N_v);
                end if;
                N_v := N_v + expLen(m, s);
            end loop;

            return x"00";
        end function;

        procedure mismatch (text : string) is
        begin
            if Bad_v = 0 then
                FirstL_v               := minimum(text'length, First_v'length);
                First_v(1 to FirstL_v) := text(text'left to text'left + FirstL_v - 1);
            end if;
            Bad_v := Bad_v + 1;
        end procedure;

    -- Sink
    begin
        In_Ready <= '0';
        wait until rising_edge(Clk);

        loop
            M_v := OcrVec_v.cursor(Set_g, Channel_g);
            if M_v >= OcrVec_v.limit(Set_g, Channel_g) then
                -- No message expected: any beat is an error
                Started_v := false;
                uniform(Seed1_v, Seed2_v, Rand_v);
                if Rand_v >= OcrVec_v.stall(Set_g, Channel_g) then
                    In_Ready <= '1';
                else
                    In_Ready <= '0';
                end if;
                wait until rising_edge(Clk);
                if In_Valid = '1' and In_Ready = '1' then
                    alert(ERROR, "unexpected beat after message " & to_string(M_v), "ocr_tb_msg_sink");
                end if;
            elsif OcrVec_v.skipFailed(Set_g, Channel_g) and OcrVec_v.stsCode(Set_g, M_v) /= 0 and
                  not tbFlag(OcrVec_v.msgFlags(Set_g, M_v), FlagOutOk_c) then
                -- Release buffer: a failed message is not delivered
                OcrVec_v.advance(Set_g, Channel_g);
            else
                Bad_v   := 0;
                Abort_v := false;
                NSec_v  := expCount(M_v);
                if (OcrVec_v.stsCode(Set_g, M_v) /= 0 and not tbFlag(OcrVec_v.msgFlags(Set_g, M_v), FlagOutOk_c)) or
                   tbFlag(OcrVec_v.msgFlags(Set_g, M_v), FlagOutErr_c) then
                    Err_v := '1';
                else
                    Err_v := '0';
                end if;
                if Decrypt_g then
                    Err_v := '0';
                end if;

                if NSec_v = 1 and expCode(M_v, 0) = 'X' then

                    -- Content not checked: beats up to TLast, error flag on the last beat
                    loop
                        getBeat;
                        exit when In_Last = '1' or Abort_v;
                    end loop;

                    if In_User(2) /= Err_v then
                        mismatch("error flag " & to_string(In_User(2)));
                    end if;
                elsif Dense_g then
                    Tot_v   := totalLen(M_v);
                    Beats_v := tbBeats(Tot_v, Bytes_c);

                    for b in 0 to Beats_v - 1 loop
                        getBeat;
                        exit when Abort_v;
                        if In_User(1 downto 0) /= secCode(expCode(M_v, secOf(M_v, b * Bytes_c))) then
                            mismatch("section " & to_string(In_User(1 downto 0)) & " in beat " & to_string(b));
                        end if;

                        for i in 0 to Bytes_c - 1 loop
                            Idx_v := b * Bytes_c + i;
                            if Idx_v < Tot_v then
                                if In_Keep(i) /= '1' then
                                    mismatch("byte enable of byte " & to_string(Idx_v));
                                elsif In_Data(8 * i + 7 downto 8 * i) /= denseByte(M_v, Idx_v) then
                                    mismatch("byte " & to_string(Idx_v) & ": " & to_hstring(In_Data(8 * i + 7 downto 8 * i)) &
                                             " expected " & to_hstring(denseByte(M_v, Idx_v)));
                                end if;
                            elsif In_Keep(i) /= '0' then
                                mismatch("byte enable of lane " & to_string(i) & " beyond the message");
                            end if;
                        end loop;

                        if b = Beats_v - 1 then
                            LastExp_v := '1';
                        else
                            LastExp_v := '0';
                        end if;
                        if In_Last /= LastExp_v then
                            mismatch("TLast " & to_string(In_Last) & " in beat " & to_string(b));
                            if In_Last = '1' then
                                exit;
                            end if;
                        end if;
                        if LastExp_v = '1' and In_User(2) /= Err_v then
                            mismatch("error flag " & to_string(In_User(2)));
                        end if;
                    end loop;

                else

                    l_sections : for s in 0 to NSec_v - 1 loop
                        Len_v   := expLen(M_v, s);
                        Beats_v := tbBeats(Len_v, Bytes_c);

                        for b in 0 to Beats_v - 1 loop
                            getBeat;
                            exit l_sections when Abort_v;
                            if In_User(1 downto 0) /= secCode(expCode(M_v, s)) then
                                mismatch("section " & to_string(In_User(1 downto 0)) & " in section " &
                                         to_string(s) & " beat " & to_string(b));
                            end if;

                            for i in 0 to Bytes_c - 1 loop
                                Idx_v := b * Bytes_c + i;
                                if Idx_v < Len_v then
                                    if In_Keep(i) /= '1' then
                                        mismatch("byte enable of byte " & to_string(Idx_v) & " of section " &
                                                 to_string(s));
                                    elsif In_Data(8 * i + 7 downto 8 * i) /= expByte(M_v, s, Idx_v) then
                                        mismatch("byte " & to_string(Idx_v) & " of section " & to_string(s) &
                                                 ": " & to_hstring(In_Data(8 * i + 7 downto 8 * i)) & " expected " &
                                                 to_hstring(expByte(M_v, s, Idx_v)));
                                    end if;
                                elsif In_Keep(i) /= '0' then
                                    mismatch("byte enable of lane " & to_string(i) & " beyond section " &
                                             to_string(s));
                                end if;
                            end loop;

                            if s = NSec_v - 1 and b = Beats_v - 1 then
                                LastExp_v := '1';
                            else
                                LastExp_v := '0';
                            end if;
                            if In_Last /= LastExp_v then
                                mismatch("TLast " & to_string(In_Last) & " in section " & to_string(s) & " beat " &
                                         to_string(b));
                                if In_Last = '1' then
                                    exit;
                                end if;
                            end if;
                            if LastExp_v = '1' and In_User(2) /= Err_v then
                                mismatch("error flag " & to_string(In_User(2)));
                            end if;
                        end loop;

                    end loop;

                end if;

                if Abort_v then

                    -- The test sets the cursor of the next message and then clears the abort
                    while OcrVec_v.getAbort(Set_g, Channel_g) loop
                        In_Ready <= '0';
                        wait until rising_edge(Clk);
                    end loop;

                else
                    if Bad_v /= 0 then
                        alert(ERROR, "message " & to_string(M_v) & ": " & to_string(Bad_v) & " mismatches, first: " &
                              First_v(1 to FirstL_v), "ocr_tb_msg_sink");
                    end if;
                    OcrVec_v.advance(Set_g, Channel_g);
                end if;
            end if;
        end loop;

    end process;

end architecture;
