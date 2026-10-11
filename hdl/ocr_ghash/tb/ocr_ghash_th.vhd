---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Test harness of ocr_ghash: clock, the GHASH, a beat source that sends the AAD and the ciphertext
-- of the messages of vector set 0 (the ciphertext of an encryption is its expected output), an H
-- source with the hash subkey of the key slot of every message, and a result checker that compares S,
-- the byte counts and the length error with the vectors.
--
-- What the models do NOT check or reproduce: the beat source sends an empty ciphertext section only
-- when a message has no AAD or its input has a DATA section. On an abort (reset tests) the sources drop
-- the current message or hash subkey and continue with the next one.
--
-- Documentation: hdl/ocr_ghash/docs/verification_plan.md

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
    use work.ocr_pkg.all;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_ghash_th is
    generic (
        DataWidth_g : positive := 32;
        Digit_g     : positive := 64;
        LenBits_g   : positive := 32
    );
    port (
        Clk : out   std_logic;
        Rst : in    std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_ghash_th is

    constant ClkPeriod_c : time     := 10 ns;
    constant Bytes_c     : positive := DataWidth_g / 8;
    constant ChH_c       : natural  := ChCtx_c;

    signal Clk_i         : std_logic                                  := '0';
    signal In_Valid      : std_logic                                  := '0';
    signal In_Ready      : std_logic;
    signal In_Data       : std_logic_vector(DataWidth_g - 1 downto 0) := (others => '0');
    signal In_Keep       : std_logic_vector(Bytes_c - 1 downto 0)     := (others => '0');
    signal In_Aad        : std_logic                                  := '0';
    signal In_SecLast    : std_logic                                  := '0';
    signal In_MsgLast    : std_logic                                  := '0';
    signal H_Valid       : std_logic                                  := '0';
    signal H_Ready       : std_logic;
    signal H_Data        : Block_t                                    := (others => '0');
    signal Out_Valid     : std_logic;
    signal Out_Ready     : std_logic                                  := '0';
    signal Out_S         : Block_t;
    signal Out_AadBytes  : std_logic_vector(LenBits_g - 1 downto 0);
    signal Out_DataBytes : std_logic_vector(LenBits_g - 1 downto 0);
    signal Out_LenErr    : std_logic;

begin

    Clk_i <= not Clk_i after ClkPeriod_c / 2;
    Clk   <= Clk_i;

    i_dut : entity work.ocr_ghash
        generic map (
            DataWidth_g => DataWidth_g,
            Digit_g     => Digit_g,
            LenBits_g   => LenBits_g
        )
        port map (
            Clk           => Clk_i,
            Rst           => Rst,
            In_Valid      => In_Valid,
            In_Ready      => In_Ready,
            In_Data       => In_Data,
            In_Keep       => In_Keep,
            In_Aad        => In_Aad,
            In_SecLast    => In_SecLast,
            In_MsgLast    => In_MsgLast,
            H_Valid       => H_Valid,
            H_Ready       => H_Ready,
            H_Data        => H_Data,
            Out_Valid     => Out_Valid,
            Out_Ready     => Out_Ready,
            Out_S         => Out_S,
            Out_AadBytes  => Out_AadBytes,
            Out_DataBytes => Out_DataBytes,
            Out_LenErr    => Out_LenErr
        );

    -- AAD and ciphertext beats of the messages of set 0
    p_src : process is
        variable Seed1_v : positive := 11;
        variable Seed2_v : positive := 97;
        variable Rand_v  : real;
        variable M_v     : natural;
        variable SecA_v  : integer;
        variable SecC_v  : integer;
        variable COut_v  : boolean;
        variable Len_v   : natural;
        variable Beats_v : natural;
        variable Idx_v   : natural;
        variable Sec_v   : integer;
        variable HasD_v  : boolean;

        -- Byte i of the ciphertext section
        impure function cByte (i : natural) return std_logic_vector is
        begin
            if COut_v then
                return OcrVec_v.outByte(0, M_v, SecC_v, i);
            end if;
            return OcrVec_v.inByte(0, M_v, SecC_v, i);
        end function;

    -- Beat source
    begin
        wait until rising_edge(Clk_i);

        loop
            M_v := OcrVec_v.cursor(0, ChSource_c);
            if M_v >= OcrVec_v.limit(0, ChSource_c) then
                In_Valid <= '0';
                wait until rising_edge(Clk_i);
            else
                -- Sections: AAD from the input, ciphertext from the input (decryption) or the output (encryption)
                SecA_v := -1;
                SecC_v := -1;
                HasD_v := false;
                COut_v := false;

                for s in 0 to OcrVec_v.inCount(0, M_v) - 1 loop
                    if OcrVec_v.inCode(0, M_v, s) = 'A' then
                        SecA_v := s;
                    elsif OcrVec_v.inCode(0, M_v, s) = 'D' then
                        HasD_v := true;
                        if OcrVec_v.msgDec(0, M_v) then
                            SecC_v := s;
                        end if;
                    end if;
                end loop;

                if not OcrVec_v.msgDec(0, M_v) then

                    for s in 0 to OcrVec_v.outCount(0, M_v) - 1 loop
                        if OcrVec_v.outCode(0, M_v, s) = 'D' then
                            SecC_v := s;
                            COut_v := true;
                        end if;
                    end loop;

                end if;

                l_msg : for p in 0 to 1 loop
                    if p = 0 then
                        Sec_v := SecA_v;
                    else
                        Sec_v := SecC_v;
                    end if;
                    -- An empty ciphertext section when the input has a DATA section or the message has no AAD
                    if Sec_v >= 0 or (p = 1 and (HasD_v or SecA_v < 0)) then
                        if Sec_v < 0 then
                            Len_v := 0;
                        elsif p = 0 then
                            Len_v := OcrVec_v.inLen(0, M_v, Sec_v);
                        elsif COut_v then
                            Len_v := OcrVec_v.outLen(0, M_v, Sec_v);
                        else
                            Len_v := OcrVec_v.inLen(0, M_v, Sec_v);
                        end if;
                        Beats_v := tbBeats(Len_v, Bytes_c);

                        for b in 0 to Beats_v - 1 loop

                            loop
                                uniform(Seed1_v, Seed2_v, Rand_v);
                                exit when Rand_v >= OcrVec_v.stall(0, ChSource_c);
                                In_Valid <= '0';
                                wait until rising_edge(Clk_i);
                            end loop;

                            for i in 0 to Bytes_c - 1 loop
                                Idx_v := b * Bytes_c + i;
                                if Idx_v < Len_v then
                                    if p = 0 then
                                        In_Data(8 * i + 7 downto 8 * i) <= OcrVec_v.inByte(0, M_v, Sec_v, Idx_v);
                                    else
                                        In_Data(8 * i + 7 downto 8 * i) <= cByte(Idx_v);
                                    end if;
                                    In_Keep(i) <= '1';
                                else
                                    -- Lanes without byte enable carry garbage
                                    In_Data(8 * i + 7 downto 8 * i) <= x"A5";
                                    In_Keep(i)                      <= '0';
                                end if;
                            end loop;

                            if p = 0 then
                                In_Aad <= '1';
                            else
                                In_Aad <= '0';
                            end if;
                            if b = Beats_v - 1 then
                                In_SecLast <= '1';
                            else
                                In_SecLast <= '0';
                            end if;
                            if b = Beats_v - 1 and (p = 1 or not (HasD_v or SecA_v < 0)) then
                                In_MsgLast <= '1';
                            else
                                In_MsgLast <= '0';
                            end if;
                            In_Valid <= '1';

                            loop
                                wait until rising_edge(Clk_i);
                                exit when In_Ready = '1' or OcrVec_v.getAbort(0, ChSource_c);
                                OcrVec_v.addGap(0, ChSource_c);
                            end loop;

                            exit l_msg when OcrVec_v.getAbort(0, ChSource_c);
                            OcrVec_v.addBeat(0, ChSource_c, now);
                        end loop;

                    end if;
                end loop;

                OcrVec_v.clearAbort(0, ChSource_c);
                In_Valid <= '0';
                OcrVec_v.advance(0, ChSource_c);
            end if;
        end loop;

    end process;

    -- Hash subkey of the key slot of every message
    p_h : process is
        variable M_v : natural;
    begin
        wait until rising_edge(Clk_i);

        loop
            M_v := OcrVec_v.cursor(0, ChH_c);
            if M_v >= OcrVec_v.limit(0, ChH_c) then
                H_Valid <= '0';
                wait until rising_edge(Clk_i);
            else
                H_Data  <= OcrVec_v.keyHash(0, OcrVec_v.keyOfSlot(0, OcrVec_v.msgSlot(0, M_v)));
                H_Valid <= '1';

                loop
                    wait until rising_edge(Clk_i);
                    exit when H_Ready = '1' or OcrVec_v.getAbort(0, ChH_c);
                end loop;

                OcrVec_v.clearAbort(0, ChH_c);
                H_Valid <= '0';
                OcrVec_v.advance(0, ChH_c);
            end if;
        end loop;

    end process;

    -- S, byte counts and length error of every message
    p_chk : process is
        variable Seed1_v : positive := 13;
        variable Seed2_v : positive := 101;
        variable Rand_v  : real;
        variable M_v     : natural;
        variable Max_v   : natural;
        variable A_v     : natural;
        variable C_v     : natural;
        variable Err_v   : std_logic;
    begin
        if LenBits_g >= 31 then
            Max_v := natural'high;
        else
            Max_v := 2 ** LenBits_g - 1;
        end if;
        wait until rising_edge(Clk_i);

        loop
            uniform(Seed1_v, Seed2_v, Rand_v);
            if Rand_v >= OcrVec_v.stall(0, ChSink_c) then
                Out_Ready <= '1';
            else
                Out_Ready <= '0';
            end if;
            wait until rising_edge(Clk_i);
            if Out_Valid = '1' and Out_Ready = '1' and Rst = '0' then
                M_v := OcrVec_v.cursor(0, ChSink_c);
                if M_v >= OcrVec_v.limit(0, ChSink_c) then
                    alert(ERROR, "unexpected result", "ocr_ghash_th");
                else
                    A_v   := OcrVec_v.stsAad(0, M_v);
                    C_v   := OcrVec_v.stsData(0, M_v);
                    Err_v := '0';
                    if A_v > Max_v or C_v > Max_v then
                        Err_v := '1';
                    end if;
                    check_value(Out_LenErr, Err_v, ERROR, "length error of message " & to_string(M_v), "ocr_ghash_th");
                    check_value(to_integer(unsigned(Out_AadBytes)), minimum(A_v, Max_v), ERROR,
                                "AAD bytes of message " & to_string(M_v), "ocr_ghash_th");
                    check_value(to_integer(unsigned(Out_DataBytes)), minimum(C_v, Max_v), ERROR,
                                "ciphertext bytes of message " & to_string(M_v), "ocr_ghash_th");
                    if Err_v = '0' then
                        check_value(Out_S, OcrVec_v.ghashValue(0, M_v), ERROR, "S of message " & to_string(M_v),
                                    "ocr_ghash_th");
                    end if;
                    OcrVec_v.addBeat(0, ChSink_c, now);
                    OcrVec_v.advance(0, ChSink_c);
                end if;
            end if;
        end loop;

    end process;

end architecture;
