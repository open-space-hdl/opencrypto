---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Test harness of ocr_key_table: clock, the key table, a context source and a job checker for the
-- messages of vector set 0, and a model of the AES engine for the hash subkey requests. The key load,
-- zeroize, query and error injection ports are ports of the harness for the test sequencer.
--
-- What the models do NOT check or reproduce: the AES model answers a hash subkey request with the
-- hash subkey of the KEY record of vector set 0 or 1 that has the same key (pycryptodome), after a fixed
-- latency; a key that is not in the vector set is an error. The job checker expects the key and the
-- hash subkey of the KEY record of the slot of a message.
--
-- Documentation: hdl/ocr_key_table/docs/verification_plan.md

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
entity ocr_key_table_th is
    generic (
        KeyBits_g : positive := 256;
        NumKeys_g : positive := 4
    );
    port (
        Clk               : out   std_logic;
        Rst               : in    std_logic;
        Load_Valid        : in    std_logic;
        Load_Ready        : out   std_logic;
        Load_Slot         : in    std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        Load_Key          : in    std_logic_vector(KeyBits_g - 1 downto 0);
        Load_IvGen        : in    std_logic;
        Load_Fixed        : in    std_logic_vector(31 downto 0);
        Load_Counter      : in    std_logic_vector(63 downto 0);
        Zeroize           : in    std_logic;
        Busy              : out   std_logic;
        Query_Valid       : in    std_logic;
        Query_Ready       : out   std_logic;
        Query_Slot        : in    std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        Query_OutValid    : out   std_logic;
        Query_KeyValid    : out   std_logic;
        Query_IvGen       : out   std_logic;
        Query_Exhausted   : out   std_logic;
        Query_Fixed       : out   std_logic_vector(31 downto 0);
        Query_Counter     : out   std_logic_vector(63 downto 0);
        Query_Ded         : out   std_logic;
        Ecc_Sec           : out   std_logic_vector(6 downto 0);
        Ecc_Ded           : out   std_logic_vector(6 downto 0);
        ErrInj_Sel        : in    std_logic_vector(1 downto 0);
        ErrInj_BitFlip    : in    std_logic_vector(1 downto 0);
        ErrInj_Valid      : in    std_logic;
        AuxRequests       : out   natural;
        JobReadyStall     : in    real
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_key_table_th is

    constant ClkPeriod_c : time     := 10 ns;
    constant SlotBits_c  : positive := slotBits(NumKeys_g);

    signal Clk_i       : std_logic := '0';
    signal Ctx_Valid   : std_logic;
    signal Ctx_Ready   : std_logic;
    signal Ctx_Decrypt : std_logic;
    signal Ctx_Slot    : std_logic_vector(SlotBits_c - 1 downto 0);
    signal Ctx_IvGen   : std_logic;
    signal Ctx_Iv      : std_logic_vector(95 downto 0);
    signal Job_Valid   : std_logic;
    signal Job_Ready   : std_logic := '0';
    signal Job_Decrypt : std_logic;
    signal Job_Key     : std_logic_vector(KeyBits_g - 1 downto 0);
    signal Job_H       : Block_t;
    signal Job_Iv      : std_logic_vector(95 downto 0);
    signal Job_IvOut   : std_logic;
    signal Job_Err     : Status_t;
    signal Job_Slot    : std_logic_vector(SlotBits_c - 1 downto 0);
    signal Aux_Valid   : std_logic;
    signal Aux_Ready   : std_logic := '0';
    signal Aux_Key     : std_logic_vector(KeyBits_g - 1 downto 0);
    signal AuxR_Valid  : std_logic := '0';
    signal AuxR_Ready  : std_logic;
    signal AuxR_Block  : Block_t   := (others => '0');
    signal AuxCnt      : natural   := 0;

begin

    Clk_i <= not Clk_i after ClkPeriod_c / 2;
    Clk   <= Clk_i;

    i_dut : entity work.ocr_key_table
        generic map (
            KeyBits_g => KeyBits_g,
            NumKeys_g => NumKeys_g
        )
        port map (
            Clk               => Clk_i,
            Rst               => Rst,
            S_Ctx_Valid       => Ctx_Valid,
            S_Ctx_Ready       => Ctx_Ready,
            S_Ctx_Decrypt     => Ctx_Decrypt,
            S_Ctx_Slot        => Ctx_Slot,
            S_Ctx_IvGen       => Ctx_IvGen,
            S_Ctx_Iv          => Ctx_Iv,
            M_Job_Valid       => Job_Valid,
            M_Job_Ready       => Job_Ready,
            M_Job_Decrypt     => Job_Decrypt,
            M_Job_Key         => Job_Key,
            M_Job_H           => Job_H,
            M_Job_Iv          => Job_Iv,
            M_Job_IvOut       => Job_IvOut,
            M_Job_Err         => Job_Err,
            M_Job_Slot        => Job_Slot,
            S_Load_Valid      => Load_Valid,
            S_Load_Ready      => Load_Ready,
            S_Load_Slot       => Load_Slot,
            S_Load_Key        => Load_Key,
            S_Load_IvGen      => Load_IvGen,
            S_Load_Fixed      => Load_Fixed,
            S_Load_Counter    => Load_Counter,
            Zeroize           => Zeroize,
            Busy              => Busy,
            S_Query_Valid     => Query_Valid,
            S_Query_Ready     => Query_Ready,
            S_Query_Slot      => Query_Slot,
            M_Query_Valid     => Query_OutValid,
            M_Query_KeyValid  => Query_KeyValid,
            M_Query_IvGen     => Query_IvGen,
            M_Query_Exhausted => Query_Exhausted,
            M_Query_Fixed     => Query_Fixed,
            M_Query_Counter   => Query_Counter,
            M_Query_Ded       => Query_Ded,
            M_Aux_Valid       => Aux_Valid,
            M_Aux_Ready       => Aux_Ready,
            M_Aux_Key         => Aux_Key,
            S_Aux_Valid       => AuxR_Valid,
            S_Aux_Ready       => AuxR_Ready,
            S_Aux_Block       => AuxR_Block,
            Ecc_Sec           => Ecc_Sec,
            Ecc_Ded           => Ecc_Ded,
            ErrInj_Sel        => ErrInj_Sel,
            ErrInj_BitFlip    => ErrInj_BitFlip,
            ErrInj_Valid      => ErrInj_Valid
        );

    i_ctx : entity work.ocr_tb_ctx_source
        generic map (
            SlotBits_g => SlotBits_c
        )
        port map (
            Clk         => Clk_i,
            Ctx_Valid   => Ctx_Valid,
            Ctx_Ready   => Ctx_Ready,
            Ctx_Decrypt => Ctx_Decrypt,
            Ctx_Slot    => Ctx_Slot,
            Ctx_IvGen   => Ctx_IvGen,
            Ctx_Iv      => Ctx_Iv
        );

    -- Model of the AES engine for hash subkeys: the H of the KEY record with the requested key
    p_aes : process is
        variable Key_v   : std_logic_vector(255 downto 0);
        variable Found_v : boolean;
    begin
        Aux_Ready <= '1';

        loop
            wait until rising_edge(Clk_i);
            if Aux_Valid = '1' and Aux_Ready = '1' and Rst = '0' then
                AuxCnt    <= AuxCnt + 1;
                Aux_Ready <= '0';
                Found_v   := false;

                for s in 0 to 1 loop

                    for k in 0 to OcrVec_v.keyCount(s) - 1 loop
                        Key_v := OcrVec_v.keyValue(s, k);
                        if Key_v(255 downto 256 - KeyBits_g) = Aux_Key and not Found_v then
                            AuxR_Block <= OcrVec_v.keyHash(s, k);
                            Found_v    := true;
                        end if;
                    end loop;

                end loop;

                if not Found_v then
                    alert(ERROR, "hash subkey request with a key that is not in the vector set", "ocr_key_table_th");
                end if;

                for i in 1 to 15 loop
                    wait until rising_edge(Clk_i);
                end loop;

                AuxR_Valid <= '1';

                loop
                    wait until rising_edge(Clk_i);
                    exit when AuxR_Ready = '1';
                end loop;

                AuxR_Valid <= '0';
                Aux_Ready  <= '1';
            end if;
        end loop;

    end process;

    AuxRequests <= AuxCnt;

    -- Job checker: every job against the expected status, key, hash subkey and IV of its message
    p_job : process is
        variable Seed1_v : positive := 3;
        variable Seed2_v : positive := 7;
        variable Rand_v  : real;
        variable M_v     : natural;
        variable K_v     : natural;
        variable Key_v   : std_logic_vector(255 downto 0);
        variable Code_v  : natural;
        variable Gen_v   : std_logic;
        variable Dec_v   : std_logic;
    begin
        wait until rising_edge(Clk_i);

        loop
            uniform(Seed1_v, Seed2_v, Rand_v);
            if Rand_v >= JobReadyStall then
                Job_Ready <= '1';
            else
                Job_Ready <= '0';
            end if;
            wait until rising_edge(Clk_i);
            if Job_Valid = '1' and Job_Ready = '1' and Rst = '0' then
                M_v := OcrVec_v.cursor(0, ChSink_c);
                if M_v >= OcrVec_v.limit(0, ChSink_c) then
                    alert(ERROR, "unexpected job", "ocr_key_table_th");
                else
                    Code_v := OcrVec_v.stsCode(0, M_v);
                    Dec_v  := tbSl(OcrVec_v.msgDec(0, M_v));
                    Gen_v  := tbSl(OcrVec_v.msgIvGen(0, M_v));
                    check_value(to_integer(unsigned(Job_Err)), Code_v, ERROR, "error of job " & to_string(M_v),
                                "ocr_key_table_th");
                    check_value(Job_Decrypt, Dec_v, ERROR, "direction of job " & to_string(M_v), "ocr_key_table_th");
                    check_value(to_integer(unsigned(Job_Slot)), OcrVec_v.msgSlot(0, M_v), ERROR,
                                "slot of job " & to_string(M_v), "ocr_key_table_th");
                    if Code_v = 0 then
                        K_v   := OcrVec_v.keyOfSlot(0, OcrVec_v.msgSlot(0, M_v));
                        Key_v := OcrVec_v.keyValue(0, K_v);
                        check_value(Job_Key, Key_v(255 downto 256 - KeyBits_g), ERROR, "key of job " & to_string(M_v),
                                    "ocr_key_table_th");
                        check_value(Job_H, OcrVec_v.keyHash(0, K_v), ERROR, "hash subkey of job " & to_string(M_v),
                                    "ocr_key_table_th");
                        check_value(Job_Iv, OcrVec_v.stsIv(0, M_v), ERROR, "IV of job " & to_string(M_v),
                                    "ocr_key_table_th");
                        check_value(Job_IvOut, Gen_v, ERROR, "IV section flag of job " & to_string(M_v),
                                    "ocr_key_table_th");
                    else
                        -- A rejected job carries no key material
                        check_value(Job_Key = (Job_Key'range => '0'), ERROR, "no key in rejected job " & to_string(M_v),
                                    "ocr_key_table_th");
                        check_value(Job_H = (Job_H'range => '0'), ERROR, "no H in rejected job " & to_string(M_v),
                                    "ocr_key_table_th");
                        check_value(Job_IvOut, '0', ERROR, "IV section flag of job " & to_string(M_v), "ocr_key_table_th");
                        check_value(Job_Iv, OcrVec_v.stsIv(0, M_v), ERROR, "IV of job " & to_string(M_v),
                                    "ocr_key_table_th");
                    end if;
                    OcrVec_v.addBeat(0, ChSink_c, now);
                    OcrVec_v.advance(0, ChSink_c);
                end if;
            end if;
        end loop;

    end process;

end architecture;
