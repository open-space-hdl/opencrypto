---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Common definitions of OpenCrypto: AES transformations and key expansion (FIPS 197), arithmetic in
-- GF(2^128) (NIST SP 800-38D), byte order of blocks and beats, section and status codes, defaults of
-- the generics.
--
-- Documentation: hdl/ocr_pkg/docs/architecture.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

---------------------------------------------------------------------------------------------------
-- Package Header
---------------------------------------------------------------------------------------------------
package ocr_pkg is

    subtype Byte_t is std_logic_vector(7 downto 0);
    subtype Word_t is std_logic_vector(31 downto 0);
    -- A block holds its first byte (the leftmost byte of the string of the standards) in bits 127:120
    subtype Block_t is std_logic_vector(127 downto 0);

    -- Sections of a message (TUser(1:0) of the message streams)
    subtype Section_t is std_logic_vector(1 downto 0);
    constant SecData_c : Section_t := "00";
    constant SecAad_c  : Section_t := "01";
    constant SecTag_c  : Section_t := "10";
    constant SecIv_c   : Section_t := "11";

    -- Status codes of a message
    subtype Status_t is std_logic_vector(3 downto 0);
    constant StsOk_c          : Status_t := x"0";
    constant StsAuth_c        : Status_t := x"1";
    constant StsFormat_c      : Status_t := x"2";
    constant StsKey_c         : Status_t := x"3";
    constant StsIvMode_c      : Status_t := x"4";
    constant StsIvExhausted_c : Status_t := x"5";
    constant StsLength_c      : Status_t := x"6";
    constant StsEcc_c         : Status_t := x"7";
    constant StsOverflow_c    : Status_t := x"8";

    -- Precedence of a status code (higher wins) and the code of higher precedence of two codes
    function stsPrio (s : Status_t) return natural;
    function stsMerge (
        a : Status_t;
        b : Status_t) return Status_t;

    -- AES parameters (AES 5, Figure 4): words of the key and number of rounds
    function aesNk (keyBits : positive) return positive;
    function aesNr (keyBits : positive) return positive;

    -- Defaults and minima of the generics (docs/architecture.md, D4 and D5)
    function aesDefaultUnits (
        keyBits   : positive;
        dataWidth : positive) return positive;
    function aesMinUnits (
        keyBits   : positive;
        dataWidth : positive) return positive;
    function ghashDefaultDigit (dataWidth : positive) return positive;
    -- Bits of a key slot number (at least one)
    function slotBits (numKeys : positive) return positive;

    -- AES transformations
    function aesSbox (b : Byte_t) return Byte_t;
    function aesSubBytes (s : Block_t) return Block_t;
    function aesShiftRows (s : Block_t) return Block_t;
    function aesXtime (b : Byte_t) return Byte_t;
    function aesMixColumns (s : Block_t) return Block_t;
    -- One round of the cipher (AES 5.1): MixColumns is left out when last = '1'
    function aesRound (
        s    : Block_t;
        rk   : Block_t;
        last : std_logic) return Block_t;
    function aesSubWord (w : Word_t) return Word_t;
    function aesRotWord (w : Word_t) return Word_t;
    function aesRcon (i : positive) return Byte_t;

    -- Key expansion on the fly (AES 5.2). A window holds the last Nk words w[g - Nk] to w[g - 1] that the
    -- expansion has produced, the oldest word in the leftmost bits; the round key of the next round is the
    -- last four words of the window. A step produces the four words w[g] to w[g + 3]. Within four words at
    -- most one word needs SubWord, so a step has one SubWord at position SubPos when SubEn = '1'.
    type AesKeyCtl_t is record
        SubEn  : std_logic;
        SubPos : natural range 0 to 3;
        Rot    : std_logic;
        Rcon   : Byte_t;
    end record;

    type AesKeyCtlArr_t is array (natural range <>) of AesKeyCtl_t;

    -- Control of the step that produces w[g] to w[g + 3]
    function aesKeyCtl (
        nk : positive;
        g  : natural) return AesKeyCtl_t;
    -- Control of the steps of the rounds: entry r (1 to Nr - 1) produces the round key of round r + 1
    function aesKeyCtlTable (keyBits : positive) return AesKeyCtlArr_t;
    -- Next window (Nk words in, Nk words out)
    function aesKeyStep (
        win : std_logic_vector;
        ctl : AesKeyCtl_t) return std_logic_vector;
    -- Window after the first round key: its last four words are the round key of round 1
    function aesKeyFirst (key : std_logic_vector) return std_logic_vector;

    -- Multiplication in GF(2^128) of GCM 6.3: bit 127 of a block is the coefficient of u^0. aesGfDigit returns
    -- z * u^D + d * h mod P for a digit d of D bits whose leftmost bit is the coefficient of u^0.
    function gfMulDigit (
        z : Block_t;
        d : std_logic_vector;
        h : Block_t) return Block_t;
    function gfMul (
        x : Block_t;
        y : Block_t) return Block_t;

    -- Byte i of a block (0: leftmost byte)
    function blockByte (
        b : Block_t;
        i : natural) return Byte_t;
    -- Beat k of a block on a stream of bytes bytes per beat: byte lane j holds byte k * bytes + j of the block
    function blockToBeat (
        b     : Block_t;
        k     : natural;
        bytes : positive) return std_logic_vector;
    -- Block with the beat k of a stream written to its bytes k * bytes to k * bytes + bytes - 1
    function beatToBlock (
        b     : Block_t;
        beat  : std_logic_vector;
        k     : natural;
        bytes : positive) return Block_t;
    -- Byte enables of the first n lanes of a beat
    function keepOf (
        n     : natural;
        bytes : positive) return std_logic_vector;

end package;

---------------------------------------------------------------------------------------------------
-- Package Body
---------------------------------------------------------------------------------------------------
package body ocr_pkg is

    type ByteArr_t is array (0 to 255) of Byte_t;

    -- AES 5.1.1, Figure 7: S-box
    constant Sbox_c : ByteArr_t := (
        x"63", x"7C", x"77", x"7B", x"F2", x"6B", x"6F", x"C5", x"30", x"01", x"67", x"2B", x"FE", x"D7", x"AB", x"76",
        x"CA", x"82", x"C9", x"7D", x"FA", x"59", x"47", x"F0", x"AD", x"D4", x"A2", x"AF", x"9C", x"A4", x"72", x"C0",
        x"B7", x"FD", x"93", x"26", x"36", x"3F", x"F7", x"CC", x"34", x"A5", x"E5", x"F1", x"71", x"D8", x"31", x"15",
        x"04", x"C7", x"23", x"C3", x"18", x"96", x"05", x"9A", x"07", x"12", x"80", x"E2", x"EB", x"27", x"B2", x"75",
        x"09", x"83", x"2C", x"1A", x"1B", x"6E", x"5A", x"A0", x"52", x"3B", x"D6", x"B3", x"29", x"E3", x"2F", x"84",
        x"53", x"D1", x"00", x"ED", x"20", x"FC", x"B1", x"5B", x"6A", x"CB", x"BE", x"39", x"4A", x"4C", x"58", x"CF",
        x"D0", x"EF", x"AA", x"FB", x"43", x"4D", x"33", x"85", x"45", x"F9", x"02", x"7F", x"50", x"3C", x"9F", x"A8",
        x"51", x"A3", x"40", x"8F", x"92", x"9D", x"38", x"F5", x"BC", x"B6", x"DA", x"21", x"10", x"FF", x"F3", x"D2",
        x"CD", x"0C", x"13", x"EC", x"5F", x"97", x"44", x"17", x"C4", x"A7", x"7E", x"3D", x"64", x"5D", x"19", x"73",
        x"60", x"81", x"4F", x"DC", x"22", x"2A", x"90", x"88", x"46", x"EE", x"B8", x"14", x"DE", x"5E", x"0B", x"DB",
        x"E0", x"32", x"3A", x"0A", x"49", x"06", x"24", x"5C", x"C2", x"D3", x"AC", x"62", x"91", x"95", x"E4", x"79",
        x"E7", x"C8", x"37", x"6D", x"8D", x"D5", x"4E", x"A9", x"6C", x"56", x"F4", x"EA", x"65", x"7A", x"AE", x"08",
        x"BA", x"78", x"25", x"2E", x"1C", x"A6", x"B4", x"C6", x"E8", x"DD", x"74", x"1F", x"4B", x"BD", x"8B", x"8A",
        x"70", x"3E", x"B5", x"66", x"48", x"03", x"F6", x"0E", x"61", x"35", x"57", x"B9", x"86", x"C1", x"1D", x"9E",
        x"E1", x"F8", x"98", x"11", x"69", x"D9", x"8E", x"94", x"9B", x"1E", x"87", x"E9", x"CE", x"55", x"28", x"DF",
        x"8C", x"A1", x"89", x"0D", x"BF", x"E6", x"42", x"68", x"41", x"99", x"2D", x"0F", x"B0", x"54", x"BB", x"16"
    );

    function stsPrio (s : Status_t) return natural is
    begin

        case s is
            when StsEcc_c => return 8;
            when StsKey_c => return 7;
            when StsIvMode_c => return 6;
            when StsIvExhausted_c => return 5;
            when StsFormat_c => return 4;
            when StsLength_c => return 3;
            when StsAuth_c => return 2;
            when StsOverflow_c => return 1;
            when others => return 0;
        end case;

    end function;

    function stsMerge (
        a : Status_t;
        b : Status_t) return Status_t is
    begin
        if stsPrio(b) > stsPrio(a) then
            return b;
        end if;
        return a;
    end function;

    function aesNk (keyBits : positive) return positive is
    begin
        return keyBits / 32;
    end function;

    function aesNr (keyBits : positive) return positive is
    begin
        return keyBits / 32 + 6;
    end function;

    function aesDefaultUnits (
        keyBits   : positive;
        dataWidth : positive) return positive is
        constant R_c  : positive := 128 / dataWidth;
        constant Nr_c : positive := aesNr(keyBits);
    begin
        -- ceil(2 Nr / (R + 1)): one counter block and J0 per message of the shortest length (D4)
        return (2 * Nr_c + R_c) / (R_c + 1);
    end function;

    function aesMinUnits (
        keyBits   : positive;
        dataWidth : positive) return positive is
        constant R_c  : positive := 128 / dataWidth;
        constant Nr_c : positive := aesNr(keyBits);
    begin
        return (Nr_c + R_c - 1) / R_c;
    end function;

    function ghashDefaultDigit (dataWidth : positive) return positive is
    begin
        if dataWidth >= 64 then
            return 128;
        end if;
        return 64;
    end function;

    function slotBits (numKeys : positive) return positive is
        variable R_v : positive := 1;
    begin

        while 2 ** R_v < numKeys loop
            R_v := R_v + 1;
        end loop;

        return R_v;
    end function;

    -- AES 5.1.1
    function aesSbox (b : Byte_t) return Byte_t is
    begin
        return Sbox_c(to_integer(unsigned(b)));
    end function;

    function aesSubBytes (s : Block_t) return Block_t is
        variable R_v : Block_t;
    begin

        for i in 0 to 15 loop
            R_v(127 - 8 * i downto 120 - 8 * i) := aesSbox(s(127 - 8 * i downto 120 - 8 * i));
        end loop;

        return R_v;
    end function;

    -- AES 5.1.2: s'(r, c) = s(r, (c + r) mod 4); byte r + 4c of the block is s(r, c) (AES 3.4)
    function aesShiftRows (s : Block_t) return Block_t is
        variable R_v : Block_t;
    begin

        for c in 0 to 3 loop

            for r in 0 to 3 loop
                R_v(127 - 8 * (r + 4 * c) downto 120 - 8 * (r + 4 * c)) := blockByte(s, r + 4 * ((c + r) mod 4));
            end loop;

        end loop;

        return R_v;
    end function;

    -- AES 4.2.1: multiplication by x modulo m(x) = x^8 + x^4 + x^3 + x + 1
    function aesXtime (b : Byte_t) return Byte_t is
        variable R_v : Byte_t;
    begin
        R_v := b(6 downto 0) & '0';
        if b(7) = '1' then
            R_v := R_v xor x"1B";
        end if;
        return R_v;
    end function;

    -- AES 5.1.3: every column multiplied by a(x) = {03}x^3 + {01}x^2 + {01}x + {02}
    function aesMixColumns (s : Block_t) return Block_t is
        variable R_v                    : Block_t;
        variable A_v                    : ByteArr_t;
        variable S0_v, S1_v, S2_v, S3_v : Byte_t;
    begin

        for c in 0 to 3 loop
            S0_v                                  := blockByte(s, 4 * c);
            S1_v                                  := blockByte(s, 4 * c + 1);
            S2_v                                  := blockByte(s, 4 * c + 2);
            S3_v                                  := blockByte(s, 4 * c + 3);
            R_v(127 - 32 * c downto 120 - 32 * c) := aesXtime(S0_v) xor aesXtime(S1_v) xor S1_v xor S2_v xor S3_v;
            R_v(119 - 32 * c downto 112 - 32 * c) := S0_v xor aesXtime(S1_v) xor aesXtime(S2_v) xor S2_v xor S3_v;
            R_v(111 - 32 * c downto 104 - 32 * c) := S0_v xor S1_v xor aesXtime(S2_v) xor aesXtime(S3_v) xor S3_v;
            R_v(103 - 32 * c downto 96 - 32 * c)  := aesXtime(S0_v) xor S0_v xor S1_v xor S2_v xor aesXtime(S3_v);
        end loop;

        return R_v;
    end function;

    -- AES 5.1, Figure 5: SubBytes, ShiftRows, MixColumns (not in the last round), AddRoundKey (AES 5.1.4)
    function aesRound (
        s    : Block_t;
        rk   : Block_t;
        last : std_logic) return Block_t is
        variable R_v : Block_t;
    begin
        R_v := aesShiftRows(aesSubBytes(s));
        if last = '0' then
            R_v := aesMixColumns(R_v);
        end if;
        return R_v xor rk;
    end function;

    -- AES 5.2: SubWord and RotWord
    function aesSubWord (w : Word_t) return Word_t is
    begin
        return aesSbox(w(31 downto 24)) & aesSbox(w(23 downto 16)) & aesSbox(w(15 downto 8)) & aesSbox(w(7 downto 0));
    end function;

    function aesRotWord (w : Word_t) return Word_t is
    begin
        return w(23 downto 0) & w(31 downto 24);
    end function;

    -- AES 5.2: Rcon[i] = [x^(i-1), {00}, {00}, {00}]; returns the first byte
    function aesRcon (i : positive) return Byte_t is
        variable R_v : Byte_t := x"01";
    begin

        for j in 2 to i loop
            R_v := aesXtime(R_v);
        end loop;

        return R_v;
    end function;

    -- AES 5.2, Figure 11: word i needs SubWord(RotWord()) and Rcon when i mod Nk = 0, SubWord when Nk > 6 and
    -- i mod Nk = 4
    function aesKeyCtl (
        nk : positive;
        g  : natural) return AesKeyCtl_t is
        variable R_v : AesKeyCtl_t := (SubEn => '0', SubPos => 0, Rot => '0', Rcon => x"00");
    begin

        for j in 0 to 3 loop
            if (g + j) mod nk = 0 then
                R_v.SubEn  := '1';
                R_v.SubPos := j;
                R_v.Rot    := '1';
                R_v.Rcon   := aesRcon((g + j) / nk);
            elsif nk > 6 and (g + j) mod nk = 4 then
                R_v.SubEn  := '1';
                R_v.SubPos := j;
                R_v.Rot    := '0';
                R_v.Rcon   := x"00";
            end if;
        end loop;

        return R_v;
    end function;

    function aesKeyCtlTable (keyBits : positive) return AesKeyCtlArr_t is
        constant Nr_c : positive                := aesNr(keyBits);
        variable R_v  : AesKeyCtlArr_t(0 to 15) := (others => (SubEn => '0', SubPos => 0, Rot => '0', Rcon => x"00"));
    begin

        for r in 1 to Nr_c - 1 loop
            R_v(r) := aesKeyCtl(aesNk(keyBits), 4 * r + 4);
        end loop;

        return R_v;
    end function;

    -- Four words w[g] to w[g + 3]: w[i] = w[i - Nk] xor temp, temp = w[i - 1] or its SubWord form. The words are
    -- first chained without SubWord; the difference that the one SubWord makes at SubPos propagates to all later
    -- words of the step, because each word XORs the previous one.
    function aesKeyStep (
        win : std_logic_vector;
        ctl : AesKeyCtl_t) return std_logic_vector is
        constant Nk_c    : positive                                  := win'length / 32;
        variable W_v     : std_logic_vector(win'length - 1 downto 0) := win;
        variable Chain_v : std_logic_vector(127 downto 0);
        variable Prev_v  : Word_t;
        variable SubIn_v : Word_t;
        variable Delta_v : Word_t;
        variable R_v     : std_logic_vector(win'length - 1 downto 0);
    begin
        -- Chain without SubWord: c[k] = w[g + k - Nk] xor c[k - 1], c[-1] = w[g - 1]
        Prev_v := W_v(31 downto 0);

        for k in 0 to 3 loop
            Prev_v                                   := W_v(win'length - 1 - 32 * k downto win'length - 32 - 32 * k) xor Prev_v;
            Chain_v(127 - 32 * k downto 96 - 32 * k) := Prev_v;
        end loop;

        -- The input of SubWord is w[g + SubPos - 1]
        if ctl.SubPos = 0 then
            SubIn_v := W_v(31 downto 0);
        else
            SubIn_v := Chain_v(127 - 32 * (ctl.SubPos - 1) downto 96 - 32 * (ctl.SubPos - 1));
        end if;
        if ctl.Rot = '1' then
            Delta_v := aesSubWord(aesRotWord(SubIn_v)) xor (ctl.Rcon & x"000000");
        else
            Delta_v := aesSubWord(SubIn_v);
        end if;
        Delta_v := Delta_v xor SubIn_v;

        for k in 0 to 3 loop
            if ctl.SubEn = '1' and k >= ctl.SubPos then
                Chain_v(127 - 32 * k downto 96 - 32 * k) := Chain_v(127 - 32 * k downto 96 - 32 * k) xor Delta_v;
            end if;
        end loop;

        -- New window: the last Nk - 4 words of the old window followed by the four new words
        if Nk_c > 4 then
            R_v(win'length - 1 downto 128) := W_v(win'length - 129 downto 0);
        end if;
        R_v(127 downto 0) := Chain_v;
        return R_v;
    end function;

    function aesKeyFirst (key : std_logic_vector) return std_logic_vector is
        constant Nk_c : positive                                  := key'length / 32;
        variable K_v  : std_logic_vector(key'length - 1 downto 0) := key;
        variable R_v  : std_logic_vector(key'length - 1 downto 0);
        variable W6_v : Word_t;
        variable W7_v : Word_t;
    begin
        if Nk_c = 4 then
            -- w[4] to w[7]
            R_v := aesKeyStep(K_v, aesKeyCtl(4, 4));
        elsif Nk_c = 6 then
            -- w[6] = w[0] xor SubWord(RotWord(w[5])) xor Rcon[1], w[7] = w[1] xor w[6]; window w[2] to w[7]
            W6_v := K_v(191 downto 160) xor aesSubWord(aesRotWord(K_v(31 downto 0))) xor (aesRcon(1) & x"000000");
            W7_v := K_v(159 downto 128) xor W6_v;
            R_v  := K_v(127 downto 0) & W6_v & W7_v;
        else
            -- Round key 1 is w[4] to w[7] of the key
            R_v := K_v;
        end if;
        return R_v;
    end function;

    -- GCM 6.3: polynomial product modulo P(u) = u^128 + u^7 + u^2 + u + 1 (R = 11100001 || 0^120)
    function gfMulDigit (
        z : Block_t;
        d : std_logic_vector;
        h : Block_t) return Block_t is
        constant D_c : positive                         := d'length;
        variable D_v : std_logic_vector(0 to D_c - 1)   := d;
        variable Z_v : std_logic_vector(0 to 127)       := z;
        variable H_v : std_logic_vector(0 to 127)       := h;
        variable T_v : std_logic_vector(0 to 127 + D_c) := (others => '0');
        variable R_v : std_logic_vector(0 to 127);
    begin

        -- z * u^D
        for i in 0 to 127 loop
            T_v(i + D_c) := Z_v(i);
        end loop;

        -- + d * h
        for j in 0 to D_c - 1 loop

            for i in 0 to 127 loop
                T_v(i + j) := T_v(i + j) xor (D_v(j) and H_v(i));
            end loop;

        end loop;

        -- Reduction from the highest degree: u^n = u^(n - 128) * (u^7 + u^2 + u + 1)
        for n in 127 + D_c downto 128 loop
            T_v(n - 128) := T_v(n - 128) xor T_v(n);
            T_v(n - 127) := T_v(n - 127) xor T_v(n);
            T_v(n - 126) := T_v(n - 126) xor T_v(n);
            T_v(n - 121) := T_v(n - 121) xor T_v(n);
        end loop;

        R_v := T_v(0 to 127);
        return R_v;
    end function;

    function gfMul (
        x : Block_t;
        y : Block_t) return Block_t is
    begin
        return gfMulDigit((others => '0'), x, y);
    end function;

    function blockByte (
        b : Block_t;
        i : natural) return Byte_t is
    begin
        return b(127 - 8 * i downto 120 - 8 * i);
    end function;

    function blockToBeat (
        b     : Block_t;
        k     : natural;
        bytes : positive) return std_logic_vector is
        variable R_v : std_logic_vector(8 * bytes - 1 downto 0) := (others => '0');
    begin

        -- Multiplexer over the beats of a block: static slices only
        for kk in 0 to 16 / bytes - 1 loop
            if kk = k then

                for j in 0 to bytes - 1 loop
                    R_v(8 * j + 7 downto 8 * j) := blockByte(b, kk * bytes + j);
                end loop;

            end if;
        end loop;

        return R_v;
    end function;

    function beatToBlock (
        b     : Block_t;
        beat  : std_logic_vector;
        k     : natural;
        bytes : positive) return Block_t is
        variable B_v : std_logic_vector(8 * bytes - 1 downto 0) := beat;
        variable R_v : Block_t                                  := b;
    begin

        -- Multiplexer over the beats of a block: static slices only
        for kk in 0 to 16 / bytes - 1 loop
            if kk = k then

                for j in 0 to bytes - 1 loop
                    R_v(127 - 8 * (kk * bytes + j) downto 120 - 8 * (kk * bytes + j)) := B_v(8 * j + 7 downto 8 * j);
                end loop;

            end if;
        end loop;

        return R_v;
    end function;

    function keepOf (
        n     : natural;
        bytes : positive) return std_logic_vector is
        variable R_v : std_logic_vector(bytes - 1 downto 0) := (others => '0');
    begin

        for i in 0 to bytes - 1 loop
            if i < n then
                R_v(i) := '1';
            end if;
        end loop;

        return R_v;
    end function;

end package body;
