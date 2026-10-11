---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- OpenCrypto core: AES-GCM authenticated encryption and decryption (FIPS 197, NIST SP 800-38D,
-- CCSDS 352.0-B-2) of sectioned messages on AXI4-Stream, with a key table of NumKeys_g slots, an IV
-- generation unit per slot and a register file behind an AXI4-Lite port.
--
-- Documentation: docs/user_guide.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library olo;
    use olo.olo_base_pkg_math.all;

library work;
    use work.ocr_pkg.all;
    use work.ocr_gcm_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_core is
    generic (
        -- Message streams and cipher
        DataWidth_g     : positive range 16 to 128  := 32;      -- 16, 32, 64 or 128
        KeyBits_g       : positive range 128 to 256 := 256;     -- 128, 192 or 256
        NumKeys_g       : positive range 1 to 256   := 4;
        AesUnits_g      : natural range 0 to 14     := 0;       -- 0: default of the width
        GhashDigit_g    : natural range 0 to 128    := 0;       -- 0: default of the width
        LenBits_g       : positive range 8 to 32    := 32;
        -- Release buffer of the output
        ReleaseBuffer_g : boolean                   := false;
        ReleaseBytes_g  : positive                  := 4096;
        -- Clock frequency and scrub period of the key table (0.0: free-running scrubber)
        ClkFreqHz_g     : real                      := 100.0e6;
        ScrubPeriod_g   : real                      := 0.0
    );
    port (
        -- Control
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        -- Contexts: one per message
        S_Ctx_Valid       : in    std_logic;
        S_Ctx_Ready       : out   std_logic;
        S_Ctx_Decrypt     : in    std_logic;
        S_Ctx_Slot        : in    std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        S_Ctx_IvGen       : in    std_logic;
        S_Ctx_Iv          : in    std_logic_vector(95 downto 0);
        -- Input messages; TUser: section
        S_In_Valid        : in    std_logic;
        S_In_Ready        : out   std_logic;
        S_In_Data         : in    std_logic_vector(DataWidth_g - 1 downto 0);
        S_In_Keep         : in    std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        S_In_Last         : in    std_logic;
        S_In_User         : in    std_logic_vector(1 downto 0);
        -- Output messages; TUser: section (1:0), error flag on the last beat (2)
        M_Out_Valid       : out   std_logic;
        M_Out_Ready       : in    std_logic := '1';
        M_Out_Data        : out   std_logic_vector(DataWidth_g - 1 downto 0);
        M_Out_Keep        : out   std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        M_Out_Last        : out   std_logic;
        M_Out_User        : out   std_logic_vector(2 downto 0);
        -- Status of every message
        M_Sts_Valid       : out   std_logic;
        M_Sts_Ready       : in    std_logic := '1';
        M_Sts_Code        : out   std_logic_vector(3 downto 0);
        M_Sts_Decrypt     : out   std_logic;
        M_Sts_Slot        : out   std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        M_Sts_Iv          : out   std_logic_vector(95 downto 0);
        M_Sts_AadBytes    : out   std_logic_vector(LenBits_g - 1 downto 0);
        M_Sts_DataBytes   : out   std_logic_vector(LenBits_g - 1 downto 0);
        -- Register file
        S_AxiLite_ArAddr  : in    std_logic_vector(7 downto 0);
        S_AxiLite_ArValid : in    std_logic;
        S_AxiLite_ArReady : out   std_logic;
        S_AxiLite_AwAddr  : in    std_logic_vector(7 downto 0);
        S_AxiLite_AwValid : in    std_logic;
        S_AxiLite_AwReady : out   std_logic;
        S_AxiLite_WData   : in    std_logic_vector(31 downto 0);
        S_AxiLite_WStrb   : in    std_logic_vector(3 downto 0);
        S_AxiLite_WValid  : in    std_logic;
        S_AxiLite_WReady  : out   std_logic;
        S_AxiLite_BResp   : out   std_logic_vector(1 downto 0);
        S_AxiLite_BValid  : out   std_logic;
        S_AxiLite_BReady  : in    std_logic;
        S_AxiLite_RData   : out   std_logic_vector(31 downto 0);
        S_AxiLite_RResp   : out   std_logic_vector(1 downto 0);
        S_AxiLite_RValid  : out   std_logic;
        S_AxiLite_RReady  : in    std_logic;
        Irq               : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture struct of ocr_core is

    constant SlotBits_c : positive := slotBits(NumKeys_g);
    constant Units_c    : positive := choose(AesUnits_g = 0, aesDefaultUnits(KeyBits_g, DataWidth_g), AesUnits_g);
    constant Digit_c    : positive := choose(GhashDigit_g = 0, ghashDefaultDigit(DataWidth_g), GhashDigit_g);

    -- Key table to GCM data path
    signal Job_Valid       : std_logic;
    signal Job_Ready       : std_logic;
    signal Job_Decrypt     : std_logic;
    signal Job_Key         : std_logic_vector(KeyBits_g - 1 downto 0);
    signal Job_H           : Block_t;
    signal Job_Iv          : std_logic_vector(95 downto 0);
    signal Job_IvOut       : std_logic;
    signal Job_Err         : Status_t;
    signal Job_Slot        : std_logic_vector(SlotBits_c - 1 downto 0);
    signal AuxReq_Valid    : std_logic;
    signal AuxReq_Ready    : std_logic;
    signal AuxReq_Key      : std_logic_vector(KeyBits_g - 1 downto 0);
    signal AuxRes_Valid    : std_logic;
    signal AuxRes_Ready    : std_logic;
    signal AuxRes_Block    : Block_t;
    -- Register file to key table
    signal Load_Valid      : std_logic;
    signal Load_Ready      : std_logic;
    signal Load_Slot       : std_logic_vector(SlotBits_c - 1 downto 0);
    signal Load_Key        : std_logic_vector(KeyBits_g - 1 downto 0);
    signal Load_IvGen      : std_logic;
    signal Load_Fixed      : std_logic_vector(31 downto 0);
    signal Load_Counter    : std_logic_vector(63 downto 0);
    signal Zeroize         : std_logic;
    signal Kt_Busy         : std_logic;
    signal Query_Valid     : std_logic;
    signal Query_Ready     : std_logic;
    signal Query_Slot      : std_logic_vector(SlotBits_c - 1 downto 0);
    signal QueryR_Valid    : std_logic;
    signal QueryR_KeyValid : std_logic;
    signal QueryR_IvGen    : std_logic;
    signal QueryR_Exh      : std_logic;
    signal QueryR_Fixed    : std_logic_vector(31 downto 0);
    signal QueryR_Counter  : std_logic_vector(63 downto 0);
    signal QueryR_Ded      : std_logic;
    -- Status events, ECC events, error injection
    signal Evt_Valid       : std_logic;
    signal Evt_Code        : Status_t;
    signal Evt_Decrypt     : std_logic;
    signal Ecc_Sec         : std_logic_vector(17 downto 0);
    signal Ecc_Ded         : std_logic_vector(17 downto 0);
    signal Gcm_InjSel      : std_logic_vector(3 downto 0);
    signal Kt_InjSel       : std_logic_vector(1 downto 0);
    signal InjBitFlip      : std_logic_vector(1 downto 0);
    signal Gcm_InjValid    : std_logic;
    signal Kt_InjValid     : std_logic;

begin

    -----------------------------------------------------------------------------------------------
    -- Key table (KT-1 to KT-4)
    -----------------------------------------------------------------------------------------------
    i_key_table : entity work.ocr_key_table
        generic map (
            KeyBits_g     => KeyBits_g,
            NumKeys_g     => NumKeys_g,
            ClkFreqHz_g   => ClkFreqHz_g,
            ScrubPeriod_g => ScrubPeriod_g
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            S_Ctx_Valid       => S_Ctx_Valid,
            S_Ctx_Ready       => S_Ctx_Ready,
            S_Ctx_Decrypt     => S_Ctx_Decrypt,
            S_Ctx_Slot        => S_Ctx_Slot,
            S_Ctx_IvGen       => S_Ctx_IvGen,
            S_Ctx_Iv          => S_Ctx_Iv,
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
            Busy              => Kt_Busy,
            S_Query_Valid     => Query_Valid,
            S_Query_Ready     => Query_Ready,
            S_Query_Slot      => Query_Slot,
            M_Query_Valid     => QueryR_Valid,
            M_Query_KeyValid  => QueryR_KeyValid,
            M_Query_IvGen     => QueryR_IvGen,
            M_Query_Exhausted => QueryR_Exh,
            M_Query_Fixed     => QueryR_Fixed,
            M_Query_Counter   => QueryR_Counter,
            M_Query_Ded       => QueryR_Ded,
            M_Aux_Valid       => AuxReq_Valid,
            M_Aux_Ready       => AuxReq_Ready,
            M_Aux_Key         => AuxReq_Key,
            S_Aux_Valid       => AuxRes_Valid,
            S_Aux_Ready       => AuxRes_Ready,
            S_Aux_Block       => AuxRes_Block,
            Ecc_Sec           => Ecc_Sec(17 downto 11),
            Ecc_Ded           => Ecc_Ded(17 downto 11),
            ErrInj_Sel        => Kt_InjSel,
            ErrInj_BitFlip    => InjBitFlip,
            ErrInj_Valid      => Kt_InjValid
        );

    -----------------------------------------------------------------------------------------------
    -- GCM data path (IN, AE, CT, GH, TG, OU)
    -----------------------------------------------------------------------------------------------
    i_gcm : entity work.ocr_gcm
        generic map (
            DataWidth_g     => DataWidth_g,
            KeyBits_g       => KeyBits_g,
            AesUnits_g      => Units_c,
            GhashDigit_g    => Digit_c,
            LenBits_g       => LenBits_g,
            SlotBits_g      => SlotBits_c,
            ReleaseBuffer_g => ReleaseBuffer_g,
            ReleaseBytes_g  => ReleaseBytes_g
        )
        port map (
            Clk             => Clk,
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
            S_In_Valid      => S_In_Valid,
            S_In_Ready      => S_In_Ready,
            S_In_Data       => S_In_Data,
            S_In_Keep       => S_In_Keep,
            S_In_Last       => S_In_Last,
            S_In_User       => S_In_User,
            M_Out_Valid     => M_Out_Valid,
            M_Out_Ready     => M_Out_Ready,
            M_Out_Data      => M_Out_Data,
            M_Out_Keep      => M_Out_Keep,
            M_Out_Last      => M_Out_Last,
            M_Out_User      => M_Out_User,
            M_Sts_Valid     => M_Sts_Valid,
            M_Sts_Ready     => M_Sts_Ready,
            M_Sts_Code      => M_Sts_Code,
            M_Sts_Decrypt   => M_Sts_Decrypt,
            M_Sts_Slot      => M_Sts_Slot,
            M_Sts_Iv        => M_Sts_Iv,
            M_Sts_AadBytes  => M_Sts_AadBytes,
            M_Sts_DataBytes => M_Sts_DataBytes,
            Evt_Valid       => Evt_Valid,
            Evt_Code        => Evt_Code,
            Evt_Decrypt     => Evt_Decrypt,
            S_Aux_Valid     => AuxReq_Valid,
            S_Aux_Ready     => AuxReq_Ready,
            S_Aux_Key       => AuxReq_Key,
            M_Aux_Valid     => AuxRes_Valid,
            M_Aux_Ready     => AuxRes_Ready,
            M_Aux_Block     => AuxRes_Block,
            Ecc_Sec         => Ecc_Sec(10 downto 0),
            Ecc_Ded         => Ecc_Ded(10 downto 0),
            ErrInj_Sel      => Gcm_InjSel,
            ErrInj_BitFlip  => InjBitFlip,
            ErrInj_Valid    => Gcm_InjValid
        );

    -----------------------------------------------------------------------------------------------
    -- Register file (MG-1, MG-2)
    -----------------------------------------------------------------------------------------------
    i_mib : entity work.ocr_mib
        generic map (
            DataWidth_g     => DataWidth_g,
            KeyBits_g       => KeyBits_g,
            NumKeys_g       => NumKeys_g,
            AesUnits_g      => Units_c,
            GhashDigit_g    => Digit_c,
            LenBits_g       => LenBits_g,
            ReleaseBuffer_g => ReleaseBuffer_g,
            ReleaseBytes_g  => ReleaseBytes_g
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            S_AxiLite_ArAddr  => S_AxiLite_ArAddr,
            S_AxiLite_ArValid => S_AxiLite_ArValid,
            S_AxiLite_ArReady => S_AxiLite_ArReady,
            S_AxiLite_AwAddr  => S_AxiLite_AwAddr,
            S_AxiLite_AwValid => S_AxiLite_AwValid,
            S_AxiLite_AwReady => S_AxiLite_AwReady,
            S_AxiLite_WData   => S_AxiLite_WData,
            S_AxiLite_WStrb   => S_AxiLite_WStrb,
            S_AxiLite_WValid  => S_AxiLite_WValid,
            S_AxiLite_WReady  => S_AxiLite_WReady,
            S_AxiLite_BResp   => S_AxiLite_BResp,
            S_AxiLite_BValid  => S_AxiLite_BValid,
            S_AxiLite_BReady  => S_AxiLite_BReady,
            S_AxiLite_RData   => S_AxiLite_RData,
            S_AxiLite_RResp   => S_AxiLite_RResp,
            S_AxiLite_RValid  => S_AxiLite_RValid,
            S_AxiLite_RReady  => S_AxiLite_RReady,
            Irq               => Irq,
            M_Load_Valid      => Load_Valid,
            M_Load_Ready      => Load_Ready,
            M_Load_Slot       => Load_Slot,
            M_Load_Key        => Load_Key,
            M_Load_IvGen      => Load_IvGen,
            M_Load_Fixed      => Load_Fixed,
            M_Load_Counter    => Load_Counter,
            Zeroize           => Zeroize,
            Kt_Busy           => Kt_Busy,
            M_Query_Valid     => Query_Valid,
            M_Query_Ready     => Query_Ready,
            M_Query_Slot      => Query_Slot,
            S_Query_Valid     => QueryR_Valid,
            S_Query_KeyValid  => QueryR_KeyValid,
            S_Query_IvGen     => QueryR_IvGen,
            S_Query_Exhausted => QueryR_Exh,
            S_Query_Fixed     => QueryR_Fixed,
            S_Query_Counter   => QueryR_Counter,
            S_Query_Ded       => QueryR_Ded,
            Evt_Valid         => Evt_Valid,
            Evt_Code          => Evt_Code,
            Evt_Decrypt       => Evt_Decrypt,
            Ecc_Sec           => Ecc_Sec,
            Ecc_Ded           => Ecc_Ded,
            Gcm_ErrInj_Sel    => Gcm_InjSel,
            Kt_ErrInj_Sel     => Kt_InjSel,
            ErrInj_BitFlip    => InjBitFlip,
            Gcm_ErrInj_Valid  => Gcm_InjValid,
            Kt_ErrInj_Valid   => Kt_InjValid
        );

end architecture;
