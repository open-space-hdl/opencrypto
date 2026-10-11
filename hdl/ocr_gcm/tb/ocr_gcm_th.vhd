---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Test harness of ocr_gcm: clock, the GCM data path and the models of vector set 0: job source,
-- message source, message sink and status sink. The hash subkey port, the error injection and the
-- ECC events are ports of the harness for the test sequencer.
--
-- Documentation: hdl/ocr_gcm/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.ocr_pkg.all;
    use work.ocr_gcm_pkg.all;
    use work.ocr_tb_vec_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_gcm_th is
    generic (
        DataWidth_g     : positive := 32;
        KeyBits_g       : positive := 256;
        AesUnits_g      : natural  := 0;
        GhashDigit_g    : natural  := 0;
        LenBits_g       : positive := 32;
        ReleaseBuffer_g : boolean  := false;
        ReleaseBytes_g  : positive := 4096
    );
    port (
        Clk            : out   std_logic;
        Rst            : in    std_logic;
        -- Hash subkey port
        Aux_InValid    : in    std_logic;
        Aux_InReady    : out   std_logic;
        Aux_InKey      : in    std_logic_vector(KeyBits_g - 1 downto 0);
        Aux_OutValid   : out   std_logic;
        Aux_OutReady   : in    std_logic;
        Aux_OutBlock   : out   Block_t;
        -- Error injection and ECC events
        ErrInj_Sel     : in    std_logic_vector(3 downto 0);
        ErrInj_BitFlip : in    std_logic_vector(1 downto 0);
        ErrInj_Valid   : in    std_logic;
        Ecc_Sec        : out   std_logic_vector(GcmEccBuffers_c - 1 downto 0);
        Ecc_Ded        : out   std_logic_vector(GcmEccBuffers_c - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_gcm_th is

    constant ClkPeriod_c : time     := 10 ns;
    constant SlotBits_c  : positive := 3;
    constant Bytes_c     : positive := DataWidth_g / 8;

    signal Clk_i         : std_logic := '0';
    signal Job_Valid     : std_logic;
    signal Job_Ready     : std_logic;
    signal Job_Decrypt   : std_logic;
    signal Job_Key       : std_logic_vector(KeyBits_g - 1 downto 0);
    signal Job_H         : Block_t;
    signal Job_Iv        : std_logic_vector(95 downto 0);
    signal Job_IvOut     : std_logic;
    signal Job_Err       : Status_t;
    signal Job_Slot      : std_logic_vector(SlotBits_c - 1 downto 0);
    signal In_Valid      : std_logic;
    signal In_Ready      : std_logic;
    signal In_Data       : std_logic_vector(DataWidth_g - 1 downto 0);
    signal In_Keep       : std_logic_vector(Bytes_c - 1 downto 0);
    signal In_Last       : std_logic;
    signal In_User       : std_logic_vector(1 downto 0);
    signal Out_Valid     : std_logic;
    signal Out_Ready     : std_logic;
    signal Out_Data      : std_logic_vector(DataWidth_g - 1 downto 0);
    signal Out_Keep      : std_logic_vector(Bytes_c - 1 downto 0);
    signal Out_Last      : std_logic;
    signal Out_User      : std_logic_vector(2 downto 0);
    signal Sts_Valid     : std_logic;
    signal Sts_Ready     : std_logic;
    signal Sts_Code      : Status_t;
    signal Sts_Decrypt   : std_logic;
    signal Sts_Slot      : std_logic_vector(SlotBits_c - 1 downto 0);
    signal Sts_Iv        : std_logic_vector(95 downto 0);
    signal Sts_AadBytes  : std_logic_vector(LenBits_g - 1 downto 0);
    signal Sts_DataBytes : std_logic_vector(LenBits_g - 1 downto 0);

begin

    Clk_i <= not Clk_i after ClkPeriod_c / 2;
    Clk   <= Clk_i;

    i_dut : entity work.ocr_gcm
        generic map (
            DataWidth_g     => DataWidth_g,
            KeyBits_g       => KeyBits_g,
            AesUnits_g      => AesUnits_g,
            GhashDigit_g    => GhashDigit_g,
            LenBits_g       => LenBits_g,
            SlotBits_g      => SlotBits_c,
            ReleaseBuffer_g => ReleaseBuffer_g,
            ReleaseBytes_g  => ReleaseBytes_g
        )
        port map (
            Clk             => Clk_i,
            Rst             => Rst,
            S_Job_Valid     => Job_Valid,
            S_Job_Ready     => Job_Ready,
            S_Job_Decrypt   => Job_Decrypt,
            S_Job_Key       => Job_Key,
            S_Job_H         => Job_H,
            S_Job_Iv        => Job_Iv,
            S_Job_IvOut     => Job_IvOut,
            S_Job_Err       => Job_Err,
            S_Job_Slot      => Job_Slot,
            S_In_Valid      => In_Valid,
            S_In_Ready      => In_Ready,
            S_In_Data       => In_Data,
            S_In_Keep       => In_Keep,
            S_In_Last       => In_Last,
            S_In_User       => In_User,
            M_Out_Valid     => Out_Valid,
            M_Out_Ready     => Out_Ready,
            M_Out_Data      => Out_Data,
            M_Out_Keep      => Out_Keep,
            M_Out_Last      => Out_Last,
            M_Out_User      => Out_User,
            M_Sts_Valid     => Sts_Valid,
            M_Sts_Ready     => Sts_Ready,
            M_Sts_Code      => Sts_Code,
            M_Sts_Decrypt   => Sts_Decrypt,
            M_Sts_Slot      => Sts_Slot,
            M_Sts_Iv        => Sts_Iv,
            M_Sts_AadBytes  => Sts_AadBytes,
            M_Sts_DataBytes => Sts_DataBytes,
            S_Aux_Valid     => Aux_InValid,
            S_Aux_Ready     => Aux_InReady,
            S_Aux_Key       => Aux_InKey,
            M_Aux_Valid     => Aux_OutValid,
            M_Aux_Ready     => Aux_OutReady,
            M_Aux_Block     => Aux_OutBlock,
            Ecc_Sec         => Ecc_Sec,
            Ecc_Ded         => Ecc_Ded,
            ErrInj_Sel      => ErrInj_Sel,
            ErrInj_BitFlip  => ErrInj_BitFlip,
            ErrInj_Valid    => ErrInj_Valid
        );

    i_job : entity work.ocr_gcm_job_source
        generic map (
            KeyBits_g  => KeyBits_g,
            SlotBits_g => SlotBits_c
        )
        port map (
            Clk         => Clk_i,
            Job_Valid   => Job_Valid,
            Job_Ready   => Job_Ready,
            Job_Decrypt => Job_Decrypt,
            Job_Key     => Job_Key,
            Job_H       => Job_H,
            Job_Iv      => Job_Iv,
            Job_IvOut   => Job_IvOut,
            Job_Err     => Job_Err,
            Job_Slot    => Job_Slot
        );

    i_source : entity work.ocr_tb_msg_source
        generic map (
            DataWidth_g => DataWidth_g
        )
        port map (
            Clk       => Clk_i,
            Out_Valid => In_Valid,
            Out_Ready => In_Ready,
            Out_Data  => In_Data,
            Out_Keep  => In_Keep,
            Out_Last  => In_Last,
            Out_User  => In_User
        );

    i_sink : entity work.ocr_tb_msg_sink
        generic map (
            DataWidth_g => DataWidth_g
        )
        port map (
            Clk      => Clk_i,
            In_Valid => Out_Valid,
            In_Ready => Out_Ready,
            In_Data  => Out_Data,
            In_Keep  => Out_Keep,
            In_Last  => Out_Last,
            In_User  => Out_User
        );

    i_sts : entity work.ocr_tb_sts_sink
        generic map (
            SlotBits_g => SlotBits_c,
            LenBits_g  => LenBits_g
        )
        port map (
            Clk          => Clk_i,
            In_Valid     => Sts_Valid,
            In_Ready     => Sts_Ready,
            In_Code      => Sts_Code,
            In_Decrypt   => Sts_Decrypt,
            In_Slot      => Sts_Slot,
            In_Iv        => Sts_Iv,
            In_AadBytes  => Sts_AadBytes,
            In_DataBytes => Sts_DataBytes
        );

end architecture;
