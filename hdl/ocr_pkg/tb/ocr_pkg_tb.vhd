---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocr_pkg: AES transformations, key expansion and cipher against the examples of
-- FIPS 197 and pycryptodome, GF(2^128) multiplication and GHASH against the GCM specification and
-- pycryptodome, byte order, status precedence and the defaults of the generics.
--
-- Documentation: hdl/ocr_pkg/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library vunit_lib;
    context vunit_lib.vunit_context;

library work;
    use work.ocr_pkg.all;
    use work.ocr_tb_pkg.all;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_pkg_tb is
    generic (
        runner_cfg : string;
        VecEcb_g   : string;  -- ECB vectors of all key lengths
        VecGcm_g   : string   -- GCM test cases with GHASH results
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_pkg_tb is

    type WordRef_t is record
        Idx  : natural;
        Word : Word_t;
    end record;

    type WordRefArr_t is array (natural range <>) of WordRef_t;

    -- AES Appendix A: words of the key expansion examples
    constant Exp128_c : WordRefArr_t := (
        (4, x"A0FAFE17"), (5, x"88542CB1"), (6, x"23A33939"), (7, x"2A6C7605"), (8, x"F2C295F2"), (9, x"7A96B943"),
        (10, x"5935807A"), (11, x"7359F67F"), (12, x"3D80477D"), (13, x"4716FE3E"), (14, x"1E237E44"),
        (15, x"6D7A883B"), (16, x"EF44A541"), (17, x"A8525B7F"), (18, x"B671253B"), (19, x"DB0BAD00"),
        (20, x"D4D1C6F8"), (21, x"7C839D87"), (22, x"CAF2B8BC"), (23, x"11F915BC"), (25, x"110B3EFD"),
        (26, x"DBF98641"), (27, x"CA0093FD"), (28, x"4E54F70E"), (29, x"5F5FC9F3"), (30, x"84A64FB2"),
        (31, x"4EA6DC4F"), (32, x"EAD27321"), (33, x"B58DBAD2"), (34, x"312BF560"), (35, x"7F8D292F"),
        (36, x"AC7766F3"), (37, x"19FADC21"), (38, x"28D12941"), (39, x"575C006E"), (40, x"D014F9A8"),
        (41, x"C9EE2589"), (42, x"E13F0CC8"), (43, x"B6630CA6"));
    constant Exp192_c : WordRefArr_t := (
        (6, x"FE0C91F7"), (7, x"2402F5A5"), (8, x"EC12068E"), (10, x"0E7A95B9"), (11, x"5C56FEC2"),
        (12, x"4DB7B4BD"), (13, x"69B54118"), (14, x"85A74796"), (15, x"E92538FD"), (16, x"E75FAD44"),
        (17, x"BB095386"), (18, x"485AF057"), (19, x"21EFB14F"), (20, x"A448F6D9"), (21, x"4D6DCE24"),
        (22, x"AA326360"), (23, x"113B30E6"), (24, x"A25E7ED5"), (25, x"83B1CF9A"), (26, x"27F93943"),
        (27, x"6A94F767"), (28, x"C0A69407"), (29, x"D19DA4E1"), (30, x"EC1786EB"), (31, x"6FA64971"),
        (32, x"485F7032"), (33, x"22CB8755"), (34, x"E26D1352"), (35, x"33F0B7B3"), (36, x"40BEEB28"),
        (37, x"2F18A259"), (38, x"6747D26B"), (39, x"458C553E"), (40, x"A7E1466C"), (41, x"9411F1DF"),
        (42, x"821F750A"), (43, x"AD07D753"), (45, x"8FCC5006"), (46, x"282D166A"), (47, x"BC3CE7B5"),
        (48, x"E98BA06F"), (49, x"448C773C"), (50, x"8ECC7204"), (51, x"01002202"));
    constant Exp256_c : WordRefArr_t := (
        (8, x"9BA35411"), (9, x"8E6925AF"), (10, x"A51A8B5F"), (11, x"2067FCDE"), (12, x"A8B09C1A"),
        (13, x"93D194CD"), (14, x"BE49846E"), (15, x"B75D5B9A"), (16, x"D59AECB8"), (17, x"5BF3C917"),
        (18, x"FEE94248"), (19, x"DE8EBE96"), (20, x"B5A9328A"), (21, x"2678A647"), (22, x"98312229"),
        (24, x"812C81AD"), (25, x"DADF48BA"), (26, x"24360AF2"), (27, x"FAB8B464"), (28, x"98C5BFC9"),
        (29, x"BEBD198E"), (30, x"268C3BA7"), (31, x"09E04214"), (32, x"68007BAC"), (33, x"B2DF3316"),
        (34, x"96E939E4"), (35, x"6C518D80"), (36, x"C814E204"), (37, x"76A9FB8A"), (38, x"5025C02D"),
        (39, x"59C58239"), (40, x"DE136967"), (41, x"6CCC5A71"), (42, x"FA256395"), (43, x"9674EE15"),
        (44, x"5886CA5D"), (45, x"2E2F31D7"), (46, x"7E0AF1FA"), (47, x"27CF73C3"), (48, x"749C47AB"),
        (49, x"18501DDA"), (50, x"E2757E4F"), (51, x"7401905A"), (52, x"CAFAAAE3"), (53, x"E4D59B34"),
        (54, x"9ADF6ACE"), (55, x"BD10190D"), (56, x"FE4890D1"), (57, x"E6188D0B"), (59, x"706C631E"));

    type WordArr_t is array (0 to 59) of Word_t;

    -- All words of the key expansion, produced with the steps of ocr_pkg as the round units use them
    function expand (key : std_logic_vector) return WordArr_t is
        constant KeyBits_c : positive                                 := key'length;
        constant Nk_c      : positive                                 := KeyBits_c / 32;
        constant Nr_c      : positive                                 := aesNr(KeyBits_c);
        constant Ctl_c     : AesKeyCtlArr_t                           := aesKeyCtlTable(KeyBits_c);
        variable K_v       : std_logic_vector(KeyBits_c - 1 downto 0) := key;
        variable Win_v     : std_logic_vector(KeyBits_c - 1 downto 0);
        variable W_v       : WordArr_t                                := (others => (others => '0'));
    begin

        for i in 0 to Nk_c - 1 loop
            W_v(i) := K_v(KeyBits_c - 1 - 32 * i downto KeyBits_c - 32 - 32 * i);
        end loop;

        Win_v := aesKeyFirst(K_v);

        for j in 0 to 3 loop
            W_v(4 + j) := Win_v(127 - 32 * j downto 96 - 32 * j);
        end loop;

        for r in 1 to Nr_c - 1 loop
            Win_v := aesKeyStep(Win_v, Ctl_c(r));

            for j in 0 to 3 loop
                W_v(4 * r + 4 + j) := Win_v(127 - 32 * j downto 96 - 32 * j);
            end loop;

        end loop;

        return W_v;
    end function;

    -- Cipher composed of the functions of ocr_pkg in the order of the round units
    function cipher (
        key : std_logic_vector;
        din : Block_t) return Block_t is
        constant KeyBits_c : positive                                 := key'length;
        constant Nr_c      : positive                                 := aesNr(KeyBits_c);
        constant Ctl_c     : AesKeyCtlArr_t                           := aesKeyCtlTable(KeyBits_c);
        variable K_v       : std_logic_vector(KeyBits_c - 1 downto 0) := key;
        variable Win_v     : std_logic_vector(KeyBits_c - 1 downto 0);
        variable S_v       : Block_t;
        variable Last_v    : std_logic;
    begin
        S_v   := din xor K_v(KeyBits_c - 1 downto KeyBits_c - 128);
        Win_v := aesKeyFirst(K_v);

        for r in 1 to Nr_c loop
            if r = Nr_c then
                Last_v := '1';
            else
                Last_v := '0';
            end if;
            S_v := aesRound(S_v, Win_v(127 downto 0), Last_v);
            if r < Nr_c then
                Win_v := aesKeyStep(Win_v, Ctl_c(r));
            end if;
        end loop;

        return S_v;
    end function;

    -- Reference multiplication of GCM 6.3, Algorithm 1 (bit-serial, written independently of gfMulDigit)
    function gfMulRef (
        x : Block_t;
        y : Block_t) return Block_t is
        constant R_c : Block_t := x"E1000000000000000000000000000000";
        variable Z_v : Block_t := (others => '0');
        variable V_v : Block_t := y;
    begin

        for i in 0 to 127 loop
            if x(127 - i) = '1' then
                Z_v := Z_v xor V_v;
            end if;
            if V_v(0) = '0' then
                V_v := '0' & V_v(127 downto 1);
            else
                V_v := ('0' & V_v(127 downto 1)) xor R_c;
            end if;
        end loop;

        return Z_v;
    end function;

begin

    test_runner_watchdog(runner, 10 ms);

    p_main : process is
        variable K_v    : std_logic_vector(255 downto 0);
        variable Bits_v : natural;
        variable W_v    : WordArr_t;
        variable B_v    : Block_t;
        variable H_v    : Block_t;
        variable X_v    : Block_t;
        variable Y_v    : Block_t;
        variable Z_v    : Block_t;
        variable N_v    : natural;
        variable Pos_v  : natural;
        variable Sts_v  : Status_t;
        variable Len_v  : natural;
        variable LenA_v : natural;
        variable LenC_v : natural;
        variable Seen_v : std_logic_vector(0 to 255);
        variable D_v    : natural;
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);

        while test_suite loop

            if run("test_sbox") then
                -- AES 5.1.1: example S({53}) = {ed}, Figure 7 corners; the S-box is a permutation
                check_value(aesSbox(x"53"), x"ED", ERROR, "S-box {53}");
                check_value(aesSbox(x"00"), x"63", ERROR, "S-box {00}");
                check_value(aesSbox(x"FF"), x"16", ERROR, "S-box {ff}");
                Seen_v := (others => '0');

                for i in 0 to 255 loop
                    Seen_v(to_integer(unsigned(aesSbox(std_logic_vector(to_unsigned(i, 8)))))) := '1';
                end loop;

                check_value(Seen_v = (Seen_v'range => '1'), ERROR, "S-box is a permutation");

            elsif run("test_gf8") then
                -- AES 4.2: {57} * {13} = {fe} via xtime, AES 4.2.1
                check_value(aesXtime(x"57"), x"AE", ERROR, "{57} * {02}");
                check_value(aesXtime(aesXtime(x"57")), x"47", ERROR, "{57} * {04}");
                check_value(aesXtime(aesXtime(aesXtime(x"57"))), x"8E", ERROR, "{57} * {08}");
                check_value(aesXtime(aesXtime(aesXtime(aesXtime(x"57")))), x"07", ERROR, "{57} * {10}");
                check_value(x"57" xor aesXtime(x"57") xor aesXtime(aesXtime(aesXtime(aesXtime(x"57")))), x"FE",
                            ERROR, "{57} * {13}");
                -- AES 5.2: Rcon
                check_value(aesRcon(1), x"01", ERROR, "Rcon[1]");
                check_value(aesRcon(8), x"80", ERROR, "Rcon[8]");
                check_value(aesRcon(9), x"1B", ERROR, "Rcon[9]");
                check_value(aesRcon(10), x"36", ERROR, "Rcon[10]");

            elsif run("test_round") then
                -- AES Appendix B, round 1: SubBytes, ShiftRows, MixColumns, AddRoundKey
                B_v := x"193DE3BEA0F4E22B9AC68D2AE9F84808";
                check_value(aesSubBytes(B_v), x"D42711AEE0BF98F1B8B45DE51E415230", ERROR, "SubBytes");
                check_value(aesShiftRows(aesSubBytes(B_v)), x"D4BF5D30E0B452AEB84111F11E2798E5", ERROR, "ShiftRows");
                check_value(aesMixColumns(x"D4BF5D30E0B452AEB84111F11E2798E5"), x"046681E5E0CB199A48F8D37A2806264C",
                            ERROR, "MixColumns");
                check_value(aesRound(B_v, x"A0FAFE1788542CB123A339392A6C7605", '0'),
                            x"A49C7FF2689F352B6B5BEA43026A5049", ERROR, "round 1");
                check_value(aesRound(B_v, x"00000000000000000000000000000000", '1'),
                            x"D4BF5D30E0B452AEB84111F11E2798E5", ERROR, "last round without MixColumns");

            elsif run("test_key_expansion") then
                -- AES Appendix A.1 to A.3
                W_v := expand(x"2B7E151628AED2A6ABF7158809CF4F3C");

                for i in Exp128_c'range loop
                    check_value(W_v(Exp128_c(i).Idx), Exp128_c(i).Word, ERROR, "AES-128 w" & to_string(Exp128_c(i).Idx));
                end loop;

                W_v := expand(x"8E73B0F7DA0E6452C810F32B809079E562F8EAD2522C6B7B");

                for i in Exp192_c'range loop
                    check_value(W_v(Exp192_c(i).Idx), Exp192_c(i).Word, ERROR, "AES-192 w" & to_string(Exp192_c(i).Idx));
                end loop;

                W_v := expand(x"603DEB1015CA71BE2B73AEF0857D77811F352C073B6108D72D9810A30914DFF4");

                for i in Exp256_c'range loop
                    check_value(W_v(Exp256_c(i).Idx), Exp256_c(i).Word, ERROR, "AES-256 w" & to_string(Exp256_c(i).Idx));
                end loop;

            elsif run("test_cipher") then
                -- AES Appendix B and C, random blocks of pycryptodome
                tbLoad(0, VecEcb_g);
                N_v := OcrVec_v.ecbCount(0);
                check_value(N_v > 100, ERROR, "number of ECB vectors");

                for e in 0 to N_v - 1 loop
                    K_v    := OcrVec_v.ecbKey(0, e);
                    Bits_v := OcrVec_v.ecbKeyBits(0, e);

                    case Bits_v is
                        when 128 => B_v := cipher(K_v(255 downto 128), OcrVec_v.ecbIn(0, e));
                        when 192 => B_v := cipher(K_v(255 downto 64), OcrVec_v.ecbIn(0, e));
                        when others => B_v := cipher(K_v, OcrVec_v.ecbIn(0, e));
                    end case;

                    check_value(B_v, OcrVec_v.ecbOut(0, e), ERROR, "cipher, vector " & to_string(e) & " (" &
                                to_string(Bits_v) & " bits)");
                end loop;

            elsif run("test_gf_mul") then
                -- gfMul and every digit size against the bit-serial Algorithm 1 of GCM 6.3
                X_v := x"66E94BD4EF8A2C3B884CFA59CA342B2E";
                Y_v := x"0388DACE60B6A392F328C2B971B2FE78";

                for t in 0 to 31 loop
                    Z_v := gfMul(X_v, Y_v);
                    check_value(Z_v, gfMulRef(X_v, Y_v), ERROR, "gfMul, case " & to_string(t));

                    for k in 0 to 2 loop
                        D_v := 32 * (2 ** k);
                        -- Horner over the digits, highest-degree digit (rightmost bits) first
                        B_v := (others => '0');

                        for j in 128 / D_v - 1 downto 0 loop
                            B_v := gfMulDigit(B_v, X_v(127 - D_v * j downto 128 - D_v * (j + 1)), Y_v);
                        end loop;

                        check_value(B_v, Z_v, ERROR, "gfMulDigit " & to_string(D_v) & ", case " & to_string(t));
                    end loop;

                    -- Unit element: the block with the coefficient of u^0 (bit 127)
                    check_value(gfMul(X_v, x"80000000000000000000000000000000"), X_v, ERROR, "x * 1");
                    -- Next case: products of the previous values
                    X_v := Z_v xor Y_v;
                    Y_v := gfMulRef(Y_v, Y_v) xor x"0123456789ABCDEF0011223344556677";
                end loop;

            elsif run("test_ghash") then
                -- GHASH of A || 0 || C || 0 || len(A) || len(C) with gfMul (GCM 6.4, 7.1 step 5) against S of
                -- the GCM test cases (pycryptodome)
                tbLoad(0, VecGcm_g);

                for m in 0 to OcrVec_v.msgCount(0) - 1 loop
                    H_v    := OcrVec_v.keyHash(0, OcrVec_v.keyOfSlot(0, OcrVec_v.msgSlot(0, m)));
                    Y_v    := (others => '0');
                    LenA_v := 0;
                    LenC_v := 0;

                    for s in 0 to OcrVec_v.inCount(0, m) - 1 loop
                        if OcrVec_v.inCode(0, m, s) = 'A' or OcrVec_v.inCode(0, m, s) = 'D' then
                            Len_v := OcrVec_v.inLen(0, m, s);
                            -- Encryption: GHASH runs over the ciphertext (expected output section D)
                            Pos_v := 0;

                            while Pos_v < Len_v loop
                                X_v := (others => '0');

                                for i in 0 to 15 loop
                                    if Pos_v + i < Len_v then
                                        if OcrVec_v.inCode(0, m, s) = 'A' then
                                            X_v(127 - 8 * i downto 120 - 8 * i) := OcrVec_v.inByte(0, m, s, Pos_v + i);
                                        else
                                            X_v(127 - 8 * i downto 120 - 8 * i) := OcrVec_v.outByte(0, m, OcrVec_v.outCount(0, m) - 2, Pos_v + i);
                                        end if;
                                    end if;
                                end loop;

                                Y_v   := gfMul(Y_v xor X_v, H_v);
                                Pos_v := Pos_v + 16;
                            end loop;

                            if OcrVec_v.inCode(0, m, s) = 'A' then
                                LenA_v := Len_v;
                            else
                                LenC_v := Len_v;
                            end if;
                        end if;
                    end loop;

                    X_v := std_logic_vector(to_unsigned(8 * LenA_v, 64)) & std_logic_vector(to_unsigned(8 * LenC_v, 64));
                    Y_v := gfMul(Y_v xor X_v, H_v);
                    check_value(OcrVec_v.ghValid(0, m), ERROR, "GHASH result in the vectors");
                    check_value(Y_v, OcrVec_v.ghashValue(0, m), ERROR, "GHASH of message " & to_string(m));
                end loop;

            elsif run("test_byte_order") then
                B_v := x"000102030405060708090A0B0C0D0E0F";
                check_value(blockByte(B_v, 0), x"00", ERROR, "first byte of a block");
                check_value(blockByte(B_v, 15), x"0F", ERROR, "last byte of a block");
                check_value(blockToBeat(B_v, 0, 2), x"0100", ERROR, "16-bit beat 0");
                check_value(blockToBeat(B_v, 7, 2), x"0F0E", ERROR, "16-bit beat 7");
                check_value(blockToBeat(B_v, 1, 4), x"07060504", ERROR, "32-bit beat 1");
                check_value(blockToBeat(B_v, 1, 8), x"0F0E0D0C0B0A0908", ERROR, "64-bit beat 1");
                check_value(blockToBeat(B_v, 0, 16), x"0F0E0D0C0B0A09080706050403020100", ERROR, "128-bit beat");
                X_v := (others => '0');

                for k in 0 to 3 loop
                    X_v := beatToBlock(X_v, blockToBeat(B_v, k, 4), k, 4);
                end loop;

                check_value(X_v, B_v, ERROR, "beats back to the block");
                check_value(keepOf(0, 4), "0000", ERROR, "keep of 0 bytes");
                check_value(keepOf(3, 4), "0111", ERROR, "keep of 3 bytes");
                check_value(keepOf(4, 4), "1111", ERROR, "keep of 4 bytes");

            elsif run("test_status") then
                -- Precedence: ECC, KEY, IV_MODE, IV_EXHAUSTED, FORMAT, LENGTH, AUTH, OVERFLOW, OK
                check_value(stsMerge(StsOk_c, StsAuth_c), StsAuth_c, ERROR, "OK and AUTH");
                check_value(stsMerge(StsAuth_c, StsFormat_c), StsFormat_c, ERROR, "AUTH and FORMAT");
                check_value(stsMerge(StsEcc_c, StsKey_c), StsEcc_c, ERROR, "ECC and KEY");
                check_value(stsMerge(StsKey_c, StsIvMode_c), StsKey_c, ERROR, "KEY and IV_MODE");
                check_value(stsMerge(StsIvExhausted_c, StsIvMode_c), StsIvMode_c, ERROR, "IV_EXHAUSTED and IV_MODE");
                check_value(stsMerge(StsLength_c, StsFormat_c), StsFormat_c, ERROR, "LENGTH and FORMAT");
                check_value(stsMerge(StsLength_c, StsAuth_c), StsLength_c, ERROR, "LENGTH and AUTH");
                check_value(stsMerge(StsOverflow_c, StsAuth_c), StsAuth_c, ERROR, "OVERFLOW and AUTH");
                check_value(stsMerge(StsOverflow_c, StsOk_c), StsOverflow_c, ERROR, "OVERFLOW and OK");

                -- Every pair of codes at run time (not folded by the compiler): the higher precedence wins
                for a in 0 to 8 loop

                    for b in 0 to 8 loop
                        Sts_v := std_logic_vector(to_unsigned(a, 4));
                        check_value(stsMerge(Sts_v, std_logic_vector(to_unsigned(b, 4))),
                                    stsMerge(std_logic_vector(to_unsigned(b, 4)), Sts_v), ERROR,
                                    "precedence is symmetric for " & to_string(a) & " and " & to_string(b));
                        check_value(stsPrio(stsMerge(Sts_v, std_logic_vector(to_unsigned(b, 4)))) >= stsPrio(Sts_v),
                                    ERROR, "merge keeps the higher precedence");
                    end loop;

                end loop;

            elsif run("test_defaults") then
                -- docs/architecture.md D4 and D5
                check_value(aesNr(128), 10, ERROR, "Nr of AES-128");
                check_value(aesNr(192), 12, ERROR, "Nr of AES-192");
                check_value(aesNr(256), 14, ERROR, "Nr of AES-256");
                check_value(aesDefaultUnits(256, 128), 14, ERROR, "units AES-256, 128 bits");
                check_value(aesDefaultUnits(256, 64), 10, ERROR, "units AES-256, 64 bits");
                check_value(aesDefaultUnits(256, 32), 6, ERROR, "units AES-256, 32 bits");
                check_value(aesDefaultUnits(256, 16), 4, ERROR, "units AES-256, 16 bits");
                check_value(aesDefaultUnits(192, 64), 8, ERROR, "units AES-192, 64 bits");
                check_value(aesDefaultUnits(192, 32), 5, ERROR, "units AES-192, 32 bits");
                check_value(aesDefaultUnits(128, 64), 7, ERROR, "units AES-128, 64 bits");
                check_value(aesDefaultUnits(128, 16), 3, ERROR, "units AES-128, 16 bits");
                check_value(aesMinUnits(256, 16), 2, ERROR, "minimum units AES-256, 16 bits");
                check_value(aesMinUnits(256, 32), 4, ERROR, "minimum units AES-256, 32 bits");
                check_value(aesMinUnits(256, 64), 7, ERROR, "minimum units AES-256, 64 bits");
                check_value(aesMinUnits(128, 128), 10, ERROR, "minimum units AES-128, 128 bits");
                check_value(ghashDefaultDigit(16), 64, ERROR, "GHASH digit, 16 bits");
                check_value(ghashDefaultDigit(32), 64, ERROR, "GHASH digit, 32 bits");
                check_value(ghashDefaultDigit(64), 128, ERROR, "GHASH digit, 64 bits");
                check_value(ghashDefaultDigit(128), 128, ERROR, "GHASH digit, 128 bits");
            end if;

        end loop;

        ocrTestEnd(runner);
        wait;
    end process;

end architecture;
