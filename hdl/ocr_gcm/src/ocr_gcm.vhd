---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- GCM data path: authenticated encryption and decryption (NIST SP 800-38D 7.1, 7.2) of sectioned
-- messages with the key, hash subkey and IV that a job gives per message. Input parser, keystream
-- (AES engine), GCTR combiner, GHASH, tag stage, output assembly, optional release buffer and status;
-- one beat per clock cycle on every interface.
--
-- Documentation: hdl/ocr_gcm/docs/architecture.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library olo;
    use olo.olo_base_pkg_math.all;
    use olo.olo_ft_pkg_ecc.all;

library work;
    use work.ocr_pkg.all;
    use work.ocr_gcm_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_gcm is
    generic (
        DataWidth_g     : positive range 16 to 128  := 32;
        KeyBits_g       : positive range 128 to 256 := 256;
        AesUnits_g      : natural range 0 to 14     := 0;      -- 0: default of the width (D4)
        GhashDigit_g    : natural range 0 to 128    := 0;      -- 0: default of the width (D5)
        LenBits_g       : positive range 8 to 32    := 32;
        SlotBits_g      : positive range 1 to 8     := 2;
        ReleaseBuffer_g : boolean                   := false;
        ReleaseBytes_g  : positive                  := 4096    -- power of two, 16 beats to 65536 bytes
    );
    port (
        -- Control
        Clk             : in    std_logic;
        Rst             : in    std_logic;
        -- Jobs: one per message, in the order of the messages
        S_Job_Valid     : in    std_logic;
        S_Job_Ready     : out   std_logic;
        S_Job_Decrypt   : in    std_logic;
        S_Job_Key       : in    std_logic_vector(KeyBits_g - 1 downto 0);
        S_Job_H         : in    Block_t;
        S_Job_Iv        : in    std_logic_vector(95 downto 0);
        S_Job_IvOut     : in    std_logic;
        S_Job_Err       : in    Status_t;
        S_Job_Slot      : in    std_logic_vector(SlotBits_g - 1 downto 0);
        -- Input messages; TUser: section
        S_In_Valid      : in    std_logic;
        S_In_Ready      : out   std_logic;
        S_In_Data       : in    std_logic_vector(DataWidth_g - 1 downto 0);
        S_In_Keep       : in    std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        S_In_Last       : in    std_logic;
        S_In_User       : in    std_logic_vector(1 downto 0);
        -- Output messages; TUser: section (1:0), error flag on the last beat (2)
        M_Out_Valid     : out   std_logic;
        M_Out_Ready     : in    std_logic                                := '1';
        M_Out_Data      : out   std_logic_vector(DataWidth_g - 1 downto 0);
        M_Out_Keep      : out   std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        M_Out_Last      : out   std_logic;
        M_Out_User      : out   std_logic_vector(2 downto 0);
        -- Status of every message
        M_Sts_Valid     : out   std_logic;
        M_Sts_Ready     : in    std_logic                                := '1';
        M_Sts_Code      : out   Status_t;
        M_Sts_Decrypt   : out   std_logic;
        M_Sts_Slot      : out   std_logic_vector(SlotBits_g - 1 downto 0);
        M_Sts_Iv        : out   std_logic_vector(95 downto 0);
        M_Sts_AadBytes  : out   std_logic_vector(LenBits_g - 1 downto 0);
        M_Sts_DataBytes : out   std_logic_vector(LenBits_g - 1 downto 0);
        -- Status event: one cycle when the status of a message is written (for the counters)
        Evt_Valid       : out   std_logic;
        Evt_Code        : out   Status_t;
        Evt_Decrypt     : out   std_logic;
        -- Hash subkey requests of the key table: H = CIPH_K(0^128)
        S_Aux_Valid     : in    std_logic                                := '0';
        S_Aux_Ready     : out   std_logic;
        S_Aux_Key       : in    std_logic_vector(KeyBits_g - 1 downto 0) := (others => '0');
        M_Aux_Valid     : out   std_logic;
        M_Aux_Ready     : in    std_logic                                := '1';
        M_Aux_Block     : out   Block_t;
        -- ECC events of the buffers (one-cycle pulses per entry read), index: see GcmEcc*_c
        Ecc_Sec         : out   std_logic_vector(GcmEccBuffers_c - 1 downto 0);
        Ecc_Ded         : out   std_logic_vector(GcmEccBuffers_c - 1 downto 0);
        -- Error injection into the buffer ErrInj_Sel: the pattern flips the first two parity bits of the next entry
        -- written ("01" single error, "11" double error); the data stays unchanged
        ErrInj_Sel      : in    std_logic_vector(3 downto 0)             := (others => '0');
        ErrInj_BitFlip  : in    std_logic_vector(1 downto 0)             := (others => '0');
        ErrInj_Valid    : in    std_logic                                := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_gcm is

    constant Bytes_c     : positive := DataWidth_g / 8;
    constant Units_c     : positive := choose(AesUnits_g = 0, aesDefaultUnits(KeyBits_g, DataWidth_g), AesUnits_g);
    constant Digit_c     : positive := choose(GhashDigit_g = 0, ghashDefaultDigit(DataWidth_g), GhashDigit_g);
    -- Buffer depths: the data and keystream FIFOs cover the latency of the AES engine at full rate, the message
    -- FIFOs the messages between the input parser and the output assembly
    constant DatDepth_c  : positive := 32;
    constant KsDepth_c   : positive := 32;
    constant MsgDepth_c  : positive := choose(DataWidth_g >= 64, 32, 16);
    constant OutDepth_c  : positive := 32;
    constant HashDepth_c : positive := 16;
    constant StsDepth_c  : positive := 16;
    constant RelDepth_c  : positive := ReleaseBytes_g / Bytes_c;
    constant StsWidth_c  : positive := 4 + 1 + SlotBits_g + 96 + 2 * LenBits_g;
    constant OutWidth_c  : positive := DataWidth_g + Bytes_c + 3;

    -- Codeword-wide injection pattern for a buffer of a data width
    function inj (
        width : positive;
        sel   : std_logic_vector;
        idx   : natural;
        pat   : std_logic_vector) return std_logic_vector is
        variable R_v : std_logic_vector(eccCodewordWidth(width) - 1 downto 0) := (others => '0');
    begin
        if unsigned(sel) = idx then
            R_v(1 downto 0) := pat;
        end if;
        return R_v;
    end function;

    -- Input parser to data FIFO and keystream
    signal Dat_InValid   : std_logic;
    signal Dat_InReady   : std_logic;
    signal Dat_InData    : std_logic_vector(datWidth(DataWidth_g) - 1 downto 0);
    signal Dat_OutValid  : std_logic;
    signal Dat_OutReady  : std_logic;
    signal Dat_OutData   : std_logic_vector(datWidth(DataWidth_g) - 1 downto 0);
    signal Dat_Sec       : std_logic;
    signal Dat_Ded       : std_logic;
    signal Req_Valid     : std_logic;
    signal Req_Ready     : std_logic;
    signal Req_Key       : std_logic_vector(KeyBits_g - 1 downto 0);
    signal Req_Block     : Block_t;
    signal Req_Dest      : std_logic;
    signal Ks_Valid      : std_logic;
    signal Ks_Ready      : std_logic;
    signal Ks_Block      : Block_t;
    signal Ks_Sec        : std_logic;
    signal Ks_Ded        : std_logic;
    signal J0_Valid      : std_logic;
    signal J0_Ready      : std_logic;
    signal J0_Block      : Block_t;
    signal J0_Sec        : std_logic;
    signal J0_Ded        : std_logic;
    -- Message FIFOs
    signal H_InValid     : std_logic;
    signal H_InReady     : std_logic;
    signal H_InData      : Block_t;
    signal H_OutValid    : std_logic;
    signal H_OutReady    : std_logic;
    signal H_OutData     : Block_t;
    signal H_Sec         : std_logic;
    signal H_Ded         : std_logic;
    signal Desc_InValid  : std_logic;
    signal Desc_InReady  : std_logic;
    signal Desc_InData   : std_logic_vector(DescWidth_c - 1 downto 0);
    signal Desc_OutValid : std_logic;
    signal Desc_OutReady : std_logic;
    signal Desc_OutData  : std_logic_vector(DescWidth_c - 1 downto 0);
    signal Desc_Sec      : std_logic;
    signal Desc_Ded      : std_logic;
    -- Combiner to output, GHASH and tag stage
    signal Out_InValid   : std_logic;
    signal Out_InReady   : std_logic;
    signal Out_InData    : std_logic_vector(beatWidth(DataWidth_g) - 1 downto 0);
    signal Out_OutValid  : std_logic;
    signal Out_OutReady  : std_logic;
    signal Out_OutData   : std_logic_vector(beatWidth(DataWidth_g) - 1 downto 0);
    signal Out_Sec       : std_logic;
    signal Out_Ded       : std_logic;
    signal Hash_InValid  : std_logic;
    signal Hash_InReady  : std_logic;
    signal Hash_InData   : std_logic_vector(beatWidth(DataWidth_g) - 1 downto 0);
    signal Hash_OutValid : std_logic;
    signal Hash_OutReady : std_logic;
    signal Hash_OutData  : std_logic_vector(beatWidth(DataWidth_g) - 1 downto 0);
    signal Hash_Sec      : std_logic;
    signal Hash_Ded      : std_logic;
    signal Hash_Beat     : BeatEntry_t;
    signal Hash_Aad      : std_logic;
    signal Sum_InValid   : std_logic;
    signal Sum_InReady   : std_logic;
    signal Sum_InData    : std_logic_vector(SummaryWidth_c - 1 downto 0);
    signal Sum_OutValid  : std_logic;
    signal Sum_OutReady  : std_logic;
    signal Sum_OutData   : std_logic_vector(SummaryWidth_c - 1 downto 0);
    signal Sum_Sec       : std_logic;
    signal Sum_Ded       : std_logic;
    -- GHASH and tag stage
    signal Gh_Valid      : std_logic;
    signal Gh_Ready      : std_logic;
    signal Gh_S          : Block_t;
    signal Gh_Aad        : std_logic_vector(LenBits_g - 1 downto 0);
    signal Gh_Data       : std_logic_vector(LenBits_g - 1 downto 0);
    signal Gh_LenErr     : std_logic;
    signal Gh_EccErr     : std_logic;
    signal Res_InValid   : std_logic;
    signal Res_InReady   : std_logic;
    signal Res_InData    : std_logic_vector(ResultWidth_c - 1 downto 0);
    signal Res_OutValid  : std_logic;
    signal Res_OutReady  : std_logic;
    signal Res_OutData   : std_logic_vector(ResultWidth_c - 1 downto 0);
    signal Res_Sec       : std_logic;
    signal Res_Ded       : std_logic;
    -- Output assembly
    signal Oa_Valid      : std_logic;
    signal Oa_Ready      : std_logic;
    signal Oa_Data       : std_logic_vector(DataWidth_g - 1 downto 0);
    signal Oa_Keep       : std_logic_vector(Bytes_c - 1 downto 0);
    signal Oa_Last       : std_logic;
    signal Oa_User       : std_logic_vector(2 downto 0);
    signal Oa_Drop       : std_logic;
    signal Oa_IsDropped  : std_logic;
    signal Sts_InValid   : std_logic;
    signal Sts_InReady   : std_logic;
    signal Sts_InData    : std_logic_vector(StsWidth_c - 1 downto 0);
    signal Sts_OutData   : std_logic_vector(StsWidth_c - 1 downto 0);
    signal Sts_OutValid  : std_logic;
    signal Sts_Sec       : std_logic;
    signal Sts_Ded       : std_logic;
    signal Sts_Code      : Status_t;
    signal Sts_Decrypt   : std_logic;
    signal Sts_Slot      : std_logic_vector(SlotBits_g - 1 downto 0);
    signal Sts_Iv        : std_logic_vector(95 downto 0);
    signal Sts_Aad       : std_logic_vector(LenBits_g - 1 downto 0);
    signal Sts_Data      : std_logic_vector(LenBits_g - 1 downto 0);
    signal Rel_Sec       : std_logic;
    signal Rel_Ded       : std_logic;

begin

    assert DataWidth_g = 16 or DataWidth_g = 32 or DataWidth_g = 64 or DataWidth_g = 128
        report "ocr_gcm: DataWidth_g must be 16, 32, 64 or 128"
        severity failure;
    assert Units_c >= aesMinUnits(KeyBits_g, DataWidth_g)
        report "ocr_gcm: AesUnits_g below ceil(Nr / R) cannot sustain one beat per clock cycle"
        severity failure;
    assert Digit_c >= DataWidth_g
        report "ocr_gcm: GhashDigit_g below DataWidth_g cannot sustain one beat per clock cycle"
        severity failure;
    assert not ReleaseBuffer_g or (log2(RelDepth_c) = log2ceil(RelDepth_c) and RelDepth_c >= 16 and
                                   ReleaseBytes_g <= 65536)
        report "ocr_gcm: ReleaseBytes_g must be a power of two from 16 beats to 65536 bytes"
        severity failure;

    -----------------------------------------------------------------------------------------------
    -- Input parser (IN-1, IN-2)
    -----------------------------------------------------------------------------------------------
    i_input : entity work.ocr_gcm_input
        generic map (
            DataWidth_g => DataWidth_g,
            KeyBits_g   => KeyBits_g,
            SlotBits_g  => SlotBits_g
        )
        port map (
            Clk           => Clk,
            Rst           => Rst,
            S_Job_Valid   => S_Job_Valid,
            S_Job_Ready   => S_Job_Ready,
            S_Job_Decrypt => S_Job_Decrypt,
            S_Job_Key     => S_Job_Key,
            S_Job_H       => S_Job_H,
            S_Job_Iv      => S_Job_Iv,
            S_Job_IvOut   => S_Job_IvOut,
            S_Job_Err     => S_Job_Err,
            S_Job_Slot    => S_Job_Slot,
            S_In_Valid    => S_In_Valid,
            S_In_Ready    => S_In_Ready,
            S_In_Data     => S_In_Data,
            S_In_Keep     => S_In_Keep,
            S_In_Last     => S_In_Last,
            S_In_User     => S_In_User,
            M_Dat_Valid   => Dat_InValid,
            M_Dat_Ready   => Dat_InReady,
            M_Dat_Data    => Dat_InData,
            M_Req_Valid   => Req_Valid,
            M_Req_Ready   => Req_Ready,
            M_Req_Key     => Req_Key,
            M_Req_Block   => Req_Block,
            M_Req_Dest    => Req_Dest,
            M_H_Valid     => H_InValid,
            M_H_Ready     => H_InReady,
            M_H_Data      => H_InData,
            M_Desc_Valid  => Desc_InValid,
            M_Desc_Ready  => Desc_InReady,
            M_Desc_Data   => Desc_InData
        );

    i_dat_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => datWidth(DataWidth_g),
            Depth_g => DatDepth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => Dat_InData,
            In_Valid          => Dat_InValid,
            In_Ready          => Dat_InReady,
            Out_Data          => Dat_OutData,
            Out_Valid         => Dat_OutValid,
            Out_Ready         => Dat_OutReady,
            Out_EccSec        => Dat_Sec,
            Out_EccDed        => Dat_Ded,
            In_ErrInj_BitFlip => inj(datWidth(DataWidth_g), ErrInj_Sel, GcmEccDat_c, ErrInj_BitFlip),
            In_ErrInj_Valid   => ErrInj_Valid
        );

    i_h_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => 128,
            Depth_g => MsgDepth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => H_InData,
            In_Valid          => H_InValid,
            In_Ready          => H_InReady,
            Out_Data          => H_OutData,
            Out_Valid         => H_OutValid,
            Out_Ready         => H_OutReady,
            Out_EccSec        => H_Sec,
            Out_EccDed        => H_Ded,
            In_ErrInj_BitFlip => inj(128, ErrInj_Sel, GcmEccH_c, ErrInj_BitFlip),
            In_ErrInj_Valid   => ErrInj_Valid
        );

    i_desc_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => DescWidth_c,
            Depth_g => MsgDepth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => Desc_InData,
            In_Valid          => Desc_InValid,
            In_Ready          => Desc_InReady,
            Out_Data          => Desc_OutData,
            Out_Valid         => Desc_OutValid,
            Out_Ready         => Desc_OutReady,
            Out_EccSec        => Desc_Sec,
            Out_EccDed        => Desc_Ded,
            In_ErrInj_BitFlip => inj(DescWidth_c, ErrInj_Sel, GcmEccDesc_c, ErrInj_BitFlip),
            In_ErrInj_Valid   => ErrInj_Valid
        );

    -----------------------------------------------------------------------------------------------
    -- Keystream (AE-1)
    -----------------------------------------------------------------------------------------------
    i_keystream : entity work.ocr_gcm_keystream
        generic map (
            KeyBits_g => KeyBits_g,
            Units_g   => Units_c,
            KsDepth_g => KsDepth_c,
            J0Depth_g => MsgDepth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            S_Req_Valid       => Req_Valid,
            S_Req_Ready       => Req_Ready,
            S_Req_Key         => Req_Key,
            S_Req_Block       => Req_Block,
            S_Req_Dest        => Req_Dest,
            S_Aux_Valid       => S_Aux_Valid,
            S_Aux_Ready       => S_Aux_Ready,
            S_Aux_Key         => S_Aux_Key,
            M_Aux_Valid       => M_Aux_Valid,
            M_Aux_Ready       => M_Aux_Ready,
            M_Aux_Block       => M_Aux_Block,
            M_Ks_Valid        => Ks_Valid,
            M_Ks_Ready        => Ks_Ready,
            M_Ks_Block        => Ks_Block,
            M_Ks_EccSec       => Ks_Sec,
            M_Ks_EccDed       => Ks_Ded,
            M_J0_Valid        => J0_Valid,
            M_J0_Ready        => J0_Ready,
            M_J0_Block        => J0_Block,
            M_J0_EccSec       => J0_Sec,
            M_J0_EccDed       => J0_Ded,
            Ks_ErrInj_BitFlip => inj(128, ErrInj_Sel, GcmEccKs_c, ErrInj_BitFlip),
            Ks_ErrInj_Valid   => ErrInj_Valid,
            J0_ErrInj_BitFlip => inj(128, ErrInj_Sel, GcmEccJ0_c, ErrInj_BitFlip),
            J0_ErrInj_Valid   => ErrInj_Valid
        );

    -----------------------------------------------------------------------------------------------
    -- GCTR combiner (CT-1)
    -----------------------------------------------------------------------------------------------
    i_combine : entity work.ocr_gcm_combine
        generic map (
            DataWidth_g => DataWidth_g
        )
        port map (
            Clk          => Clk,
            Rst          => Rst,
            S_Dat_Valid  => Dat_OutValid,
            S_Dat_Ready  => Dat_OutReady,
            S_Dat_Data   => Dat_OutData,
            S_Dat_EccDed => Dat_Ded,
            S_Ks_Valid   => Ks_Valid,
            S_Ks_Ready   => Ks_Ready,
            S_Ks_Block   => Ks_Block,
            S_Ks_EccDed  => Ks_Ded,
            M_Out_Valid  => Out_InValid,
            M_Out_Ready  => Out_InReady,
            M_Out_Data   => Out_InData,
            M_Hash_Valid => Hash_InValid,
            M_Hash_Ready => Hash_InReady,
            M_Hash_Data  => Hash_InData,
            M_Sum_Valid  => Sum_InValid,
            M_Sum_Ready  => Sum_InReady,
            M_Sum_Data   => Sum_InData
        );

    i_out_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => beatWidth(DataWidth_g),
            Depth_g => OutDepth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => Out_InData,
            In_Valid          => Out_InValid,
            In_Ready          => Out_InReady,
            Out_Data          => Out_OutData,
            Out_Valid         => Out_OutValid,
            Out_Ready         => Out_OutReady,
            Out_EccSec        => Out_Sec,
            Out_EccDed        => Out_Ded,
            In_ErrInj_BitFlip => inj(beatWidth(DataWidth_g), ErrInj_Sel, GcmEccOut_c, ErrInj_BitFlip),
            In_ErrInj_Valid   => ErrInj_Valid
        );

    i_hash_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => beatWidth(DataWidth_g),
            Depth_g => HashDepth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => Hash_InData,
            In_Valid          => Hash_InValid,
            In_Ready          => Hash_InReady,
            Out_Data          => Hash_OutData,
            Out_Valid         => Hash_OutValid,
            Out_Ready         => Hash_OutReady,
            Out_EccSec        => Hash_Sec,
            Out_EccDed        => Hash_Ded,
            In_ErrInj_BitFlip => inj(beatWidth(DataWidth_g), ErrInj_Sel, GcmEccHash_c, ErrInj_BitFlip),
            In_ErrInj_Valid   => ErrInj_Valid
        );

    i_sum_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => SummaryWidth_c,
            Depth_g => MsgDepth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => Sum_InData,
            In_Valid          => Sum_InValid,
            In_Ready          => Sum_InReady,
            Out_Data          => Sum_OutData,
            Out_Valid         => Sum_OutValid,
            Out_Ready         => Sum_OutReady,
            Out_EccSec        => Sum_Sec,
            Out_EccDed        => Sum_Ded,
            In_ErrInj_BitFlip => inj(SummaryWidth_c, ErrInj_Sel, GcmEccSum_c, ErrInj_BitFlip),
            In_ErrInj_Valid   => ErrInj_Valid
        );

    -----------------------------------------------------------------------------------------------
    -- GHASH (GH-1) and tag stage (TG-1)
    -----------------------------------------------------------------------------------------------
    Hash_Beat <= beatUnpack(Hash_OutData, DataWidth_g);
    Hash_Aad  <= '1' when Hash_Beat.Sec = SecAad_c else '0';

    i_ghash : entity work.ocr_ghash
        generic map (
            DataWidth_g => DataWidth_g,
            Digit_g     => Digit_c,
            LenBits_g   => LenBits_g
        )
        port map (
            Clk           => Clk,
            Rst           => Rst,
            In_Valid      => Hash_OutValid,
            In_Ready      => Hash_OutReady,
            In_Data       => Hash_Beat.Data(DataWidth_g - 1 downto 0),
            In_Keep       => Hash_Beat.Keep(Bytes_c - 1 downto 0),
            In_Aad        => Hash_Aad,
            In_SecLast    => Hash_Beat.SecL,
            In_MsgLast    => Hash_Beat.Last,
            In_Err        => Hash_Ded,
            H_Valid       => H_OutValid,
            H_Ready       => H_OutReady,
            H_Data        => H_OutData,
            H_Err         => H_Ded,
            Out_Valid     => Gh_Valid,
            Out_Ready     => Gh_Ready,
            Out_S         => Gh_S,
            Out_AadBytes  => Gh_Aad,
            Out_DataBytes => Gh_Data,
            Out_LenErr    => Gh_LenErr,
            Out_EccErr    => Gh_EccErr
        );

    i_tag : entity work.ocr_gcm_tag
        generic map (
            LenBits_g => LenBits_g
        )
        port map (
            Clk          => Clk,
            Rst          => Rst,
            S_Gh_Valid   => Gh_Valid,
            S_Gh_Ready   => Gh_Ready,
            S_Gh_S       => Gh_S,
            S_Gh_Aad     => Gh_Aad,
            S_Gh_Data    => Gh_Data,
            S_Gh_LenErr  => Gh_LenErr,
            S_Gh_EccErr  => Gh_EccErr,
            S_Sum_Valid  => Sum_OutValid,
            S_Sum_Ready  => Sum_OutReady,
            S_Sum_Data   => Sum_OutData,
            S_Sum_EccDed => Sum_Ded,
            S_J0_Valid   => J0_Valid,
            S_J0_Ready   => J0_Ready,
            S_J0_Block   => J0_Block,
            S_J0_EccDed  => J0_Ded,
            M_Res_Valid  => Res_InValid,
            M_Res_Ready  => Res_InReady,
            M_Res_Data   => Res_InData
        );

    i_res_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => ResultWidth_c,
            Depth_g => MsgDepth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => Res_InData,
            In_Valid          => Res_InValid,
            In_Ready          => Res_InReady,
            Out_Data          => Res_OutData,
            Out_Valid         => Res_OutValid,
            Out_Ready         => Res_OutReady,
            Out_EccSec        => Res_Sec,
            Out_EccDed        => Res_Ded,
            In_ErrInj_BitFlip => inj(ResultWidth_c, ErrInj_Sel, GcmEccRes_c, ErrInj_BitFlip),
            In_ErrInj_Valid   => ErrInj_Valid
        );

    -----------------------------------------------------------------------------------------------
    -- Output assembly (OU-1), release buffer (OU-2), status (OU-3)
    -----------------------------------------------------------------------------------------------
    i_output : entity work.ocr_gcm_output
        generic map (
            DataWidth_g => DataWidth_g,
            SlotBits_g  => SlotBits_g,
            LenBits_g   => LenBits_g
        )
        port map (
            Clk             => Clk,
            Rst             => Rst,
            S_Beat_Valid    => Out_OutValid,
            S_Beat_Ready    => Out_OutReady,
            S_Beat_Data     => Out_OutData,
            S_Beat_EccDed   => Out_Ded,
            S_Desc_Valid    => Desc_OutValid,
            S_Desc_Ready    => Desc_OutReady,
            S_Desc_Data     => Desc_OutData,
            S_Desc_EccDed   => Desc_Ded,
            S_Res_Valid     => Res_OutValid,
            S_Res_Ready     => Res_OutReady,
            S_Res_Data      => Res_OutData,
            S_Res_EccDed    => Res_Ded,
            M_Out_Valid     => Oa_Valid,
            M_Out_Ready     => Oa_Ready,
            M_Out_Data      => Oa_Data,
            M_Out_Keep      => Oa_Keep,
            M_Out_Last      => Oa_Last,
            M_Out_User      => Oa_User,
            M_Out_Drop      => Oa_Drop,
            M_Out_IsDropped => Oa_IsDropped,
            M_Sts_Valid     => Sts_InValid,
            M_Sts_Ready     => Sts_InReady,
            M_Sts_Code      => Sts_Code,
            M_Sts_Decrypt   => Sts_Decrypt,
            M_Sts_Slot      => Sts_Slot,
            M_Sts_Iv        => Sts_Iv,
            M_Sts_AadBytes  => Sts_Aad,
            M_Sts_DataBytes => Sts_Data
        );

    g_direct : if not ReleaseBuffer_g generate
        M_Out_Valid  <= Oa_Valid;
        Oa_Ready     <= M_Out_Ready;
        M_Out_Data   <= Oa_Data;
        M_Out_Keep   <= Oa_Keep;
        M_Out_Last   <= Oa_Last;
        M_Out_User   <= Oa_User;
        Oa_IsDropped <= '0';
        Rel_Sec      <= '0';
        Rel_Ded      <= '0';
    end generate;

    -- GCM 7.2 step 8: a decrypted message leaves the core only when its tag was verified (D10)
    g_release : if ReleaseBuffer_g generate
        signal Rel_InData   : std_logic_vector(OutWidth_c - 1 downto 0);
        signal Rel_OutData  : std_logic_vector(OutWidth_c - 1 downto 0);
        signal Rel_OutValid : std_logic;
        signal Rel_OutLast  : std_logic;
        signal Rel_OutDed   : std_logic;
        signal Rel_DedSeen  : std_logic;
    begin
        Rel_InData <= Oa_Data & Oa_Keep & Oa_User;

        i_release : entity olo.olo_ft_fifo_packet
            generic map (
                Width_g      => OutWidth_c,
                Depth_g      => RelDepth_c,
                MaxPackets_g => 32
            )
            port map (
                Clk               => Clk,
                Rst               => Rst,
                In_Valid          => Oa_Valid,
                In_Ready          => Oa_Ready,
                In_Data           => Rel_InData,
                In_Last           => Oa_Last,
                In_Drop           => Oa_Drop,
                In_IsDropped      => Oa_IsDropped,
                Out_Valid         => Rel_OutValid,
                Out_Ready         => M_Out_Ready,
                Out_Data          => Rel_OutData,
                Out_Last          => Rel_OutLast,
                Out_EccSec        => Rel_Sec,
                Out_EccDed        => Rel_OutDed,
                In_ErrInj_BitFlip => inj(OutWidth_c, ErrInj_Sel, GcmEccRel_c, ErrInj_BitFlip),
                In_ErrInj_Valid   => ErrInj_Valid
            );

        -- A double error in a released message sets the error flag on its last beat
        p_ded : process (Clk) is
        begin
            if rising_edge(Clk) then
                if Rel_OutValid = '1' and M_Out_Ready = '1' then
                    if Rel_OutLast = '1' then
                        Rel_DedSeen <= '0';
                    elsif Rel_OutDed = '1' then
                        Rel_DedSeen <= '1';
                    end if;
                end if;
                if Rst = '1' then
                    Rel_DedSeen <= '0';
                end if;
            end if;
        end process;

        M_Out_Valid <= Rel_OutValid;
        M_Out_Data  <= Rel_OutData(OutWidth_c - 1 downto Bytes_c + 3);
        M_Out_Keep  <= Rel_OutData(Bytes_c + 2 downto 3);
        M_Out_Last  <= Rel_OutLast;
        M_Out_User  <= (Rel_OutData(2) or (Rel_OutLast and (Rel_DedSeen or Rel_OutDed))) & Rel_OutData(1 downto 0);
        Rel_Ded     <= Rel_OutDed;
    end generate;

    Sts_InData <= Sts_Code & Sts_Decrypt & Sts_Slot & Sts_Iv & Sts_Aad & Sts_Data;

    Evt_Valid   <= Sts_InValid and Sts_InReady;
    Evt_Code    <= Sts_Code;
    Evt_Decrypt <= Sts_Decrypt;

    i_sts_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => StsWidth_c,
            Depth_g => StsDepth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => Sts_InData,
            In_Valid          => Sts_InValid,
            In_Ready          => Sts_InReady,
            Out_Data          => Sts_OutData,
            Out_Valid         => Sts_OutValid,
            Out_Ready         => M_Sts_Ready,
            Out_EccSec        => Sts_Sec,
            Out_EccDed        => Sts_Ded,
            In_ErrInj_BitFlip => inj(StsWidth_c, ErrInj_Sel, GcmEccSts_c, ErrInj_BitFlip),
            In_ErrInj_Valid   => ErrInj_Valid
        );

    -- An unreliable status entry reports ECC
    M_Sts_Valid     <= Sts_OutValid;
    M_Sts_Code      <= StsEcc_c when Sts_Ded = '1' else Sts_OutData(StsWidth_c - 1 downto StsWidth_c - 4);
    M_Sts_Decrypt   <= Sts_OutData(StsWidth_c - 5);
    M_Sts_Slot      <= Sts_OutData(StsWidth_c - 6 downto StsWidth_c - 5 - SlotBits_g);
    M_Sts_Iv        <= Sts_OutData(2 * LenBits_g + 95 downto 2 * LenBits_g);
    M_Sts_AadBytes  <= Sts_OutData(2 * LenBits_g - 1 downto LenBits_g);
    M_Sts_DataBytes <= Sts_OutData(LenBits_g - 1 downto 0);

    -----------------------------------------------------------------------------------------------
    -- ECC events: one pulse per entry read with a corrected (SEC) or uncorrectable (DED) error
    -----------------------------------------------------------------------------------------------
    Ecc_Sec(GcmEccDat_c)  <= Dat_Sec and Dat_OutValid and Dat_OutReady;
    Ecc_Ded(GcmEccDat_c)  <= Dat_Ded and Dat_OutValid and Dat_OutReady;
    Ecc_Sec(GcmEccKs_c)   <= Ks_Sec and Ks_Valid and Ks_Ready;
    Ecc_Ded(GcmEccKs_c)   <= Ks_Ded and Ks_Valid and Ks_Ready;
    Ecc_Sec(GcmEccJ0_c)   <= J0_Sec and J0_Valid and J0_Ready;
    Ecc_Ded(GcmEccJ0_c)   <= J0_Ded and J0_Valid and J0_Ready;
    Ecc_Sec(GcmEccHash_c) <= Hash_Sec and Hash_OutValid and Hash_OutReady;
    Ecc_Ded(GcmEccHash_c) <= Hash_Ded and Hash_OutValid and Hash_OutReady;
    Ecc_Sec(GcmEccOut_c)  <= Out_Sec and Out_OutValid and Out_OutReady;
    Ecc_Ded(GcmEccOut_c)  <= Out_Ded and Out_OutValid and Out_OutReady;
    Ecc_Sec(GcmEccH_c)    <= H_Sec and H_OutValid and H_OutReady;
    Ecc_Ded(GcmEccH_c)    <= H_Ded and H_OutValid and H_OutReady;
    Ecc_Sec(GcmEccDesc_c) <= Desc_Sec and Desc_OutValid and Desc_OutReady;
    Ecc_Ded(GcmEccDesc_c) <= Desc_Ded and Desc_OutValid and Desc_OutReady;
    Ecc_Sec(GcmEccSum_c)  <= Sum_Sec and Sum_OutValid and Sum_OutReady;
    Ecc_Ded(GcmEccSum_c)  <= Sum_Ded and Sum_OutValid and Sum_OutReady;
    Ecc_Sec(GcmEccRes_c)  <= Res_Sec and Res_OutValid and Res_OutReady;
    Ecc_Ded(GcmEccRes_c)  <= Res_Ded and Res_OutValid and Res_OutReady;
    Ecc_Sec(GcmEccSts_c)  <= Sts_Sec and Sts_OutValid and M_Sts_Ready;
    Ecc_Ded(GcmEccSts_c)  <= Sts_Ded and Sts_OutValid and M_Sts_Ready;
    Ecc_Sec(GcmEccRel_c)  <= Rel_Sec and M_Out_Valid and M_Out_Ready;
    Ecc_Ded(GcmEccRel_c)  <= Rel_Ded and M_Out_Valid and M_Out_Ready;

end architecture;
