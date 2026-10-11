---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Test harness of ocr_core: clock, the UVVM engine, core A with the models of vector set 0 (context
-- source, message source, message sink, status sink) and an AXI4-Lite VVC (index 0). With Series_g a
-- second core B (AXI4-Lite VVC index 1) decrypts the output of core A: its context source, message sink
-- and status sink (channels 4 to 6) expect the decryption of the encryptions of set 0.
--
-- Documentation: hdl/ocr_core/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library uvvm_vvc_framework;
    use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

library work;
    use work.ocr_pkg.all;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_axi_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_core_th is
    generic (
        DataWidth_g     : positive := 32;
        KeyBits_g       : positive := 256;
        NumKeys_g       : positive := 4;
        ReleaseBuffer_g : boolean  := false;
        ReleaseBytes_g  : positive := 4096;
        Series_g        : boolean  := false
    );
    port (
        Clk  : out   std_logic;
        Rst  : in    std_logic;
        IrqA : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_core_th is

    constant ClkPeriod_c : time     := 10 ns;
    constant SlotBits_c  : positive := slotBits(NumKeys_g);
    constant Bytes_c     : positive := DataWidth_g / 8;

    signal Clk_i      : std_logic := '0';
    signal A_CtxValid : std_logic;
    signal A_CtxReady : std_logic;
    signal A_CtxDec   : std_logic;
    signal A_CtxSlot  : std_logic_vector(SlotBits_c - 1 downto 0);
    signal A_CtxIvGen : std_logic;
    signal A_CtxIv    : std_logic_vector(95 downto 0);
    signal A_InValid  : std_logic;
    signal A_InReady  : std_logic;
    signal A_InData   : std_logic_vector(DataWidth_g - 1 downto 0);
    signal A_InKeep   : std_logic_vector(Bytes_c - 1 downto 0);
    signal A_InLast   : std_logic;
    signal A_InUser   : std_logic_vector(1 downto 0);
    signal A_OutValid : std_logic;
    signal A_OutReady : std_logic;
    signal A_OutData  : std_logic_vector(DataWidth_g - 1 downto 0);
    signal A_OutKeep  : std_logic_vector(Bytes_c - 1 downto 0);
    signal A_OutLast  : std_logic;
    signal A_OutUser  : std_logic_vector(2 downto 0);
    signal A_StsValid : std_logic;
    signal A_StsReady : std_logic;
    signal A_StsCode  : std_logic_vector(3 downto 0);
    signal A_StsDec   : std_logic;
    signal A_StsSlot  : std_logic_vector(SlotBits_c - 1 downto 0);
    signal A_StsIv    : std_logic_vector(95 downto 0);
    signal A_StsAad   : std_logic_vector(31 downto 0);
    signal A_StsData  : std_logic_vector(31 downto 0);
    signal A_Irq      : std_logic;
    signal A_ArAddr   : std_logic_vector(7 downto 0);
    signal A_ArValid  : std_logic;
    signal A_ArReady  : std_logic;
    signal A_AwAddr   : std_logic_vector(7 downto 0);
    signal A_AwValid  : std_logic;
    signal A_AwReady  : std_logic;
    signal A_WData    : std_logic_vector(31 downto 0);
    signal A_WStrb    : std_logic_vector(3 downto 0);
    signal A_WValid   : std_logic;
    signal A_WReady   : std_logic;
    signal A_BResp    : std_logic_vector(1 downto 0);
    signal A_BValid   : std_logic;
    signal A_BReady   : std_logic;
    signal A_RData    : std_logic_vector(31 downto 0);
    signal A_RResp    : std_logic_vector(1 downto 0);
    signal A_RValid   : std_logic;
    signal A_RReady   : std_logic;
    signal B_CtxValid : std_logic;
    signal B_CtxReady : std_logic;
    signal B_CtxDec   : std_logic;
    signal B_CtxSlot  : std_logic_vector(SlotBits_c - 1 downto 0);
    signal B_CtxIvGen : std_logic;
    signal B_CtxIv    : std_logic_vector(95 downto 0);
    signal B_InValid  : std_logic;
    signal B_InReady  : std_logic;
    signal B_InData   : std_logic_vector(DataWidth_g - 1 downto 0);
    signal B_InKeep   : std_logic_vector(Bytes_c - 1 downto 0);
    signal B_InLast   : std_logic;
    signal B_InUser   : std_logic_vector(1 downto 0);
    signal B_OutValid : std_logic;
    signal B_OutReady : std_logic;
    signal B_OutData  : std_logic_vector(DataWidth_g - 1 downto 0);
    signal B_OutKeep  : std_logic_vector(Bytes_c - 1 downto 0);
    signal B_OutLast  : std_logic;
    signal B_OutUser  : std_logic_vector(2 downto 0);
    signal B_StsValid : std_logic;
    signal B_StsReady : std_logic;
    signal B_StsCode  : std_logic_vector(3 downto 0);
    signal B_StsDec   : std_logic;
    signal B_StsSlot  : std_logic_vector(SlotBits_c - 1 downto 0);
    signal B_StsIv    : std_logic_vector(95 downto 0);
    signal B_StsAad   : std_logic_vector(31 downto 0);
    signal B_StsData  : std_logic_vector(31 downto 0);
    signal B_Irq      : std_logic;
    signal B_ArAddr   : std_logic_vector(7 downto 0);
    signal B_ArValid  : std_logic;
    signal B_ArReady  : std_logic;
    signal B_AwAddr   : std_logic_vector(7 downto 0);
    signal B_AwValid  : std_logic;
    signal B_AwReady  : std_logic;
    signal B_WData    : std_logic_vector(31 downto 0);
    signal B_WStrb    : std_logic_vector(3 downto 0);
    signal B_WValid   : std_logic;
    signal B_WReady   : std_logic;
    signal B_BResp    : std_logic_vector(1 downto 0);
    signal B_BValid   : std_logic;
    signal B_BReady   : std_logic;
    signal B_RData    : std_logic_vector(31 downto 0);
    signal B_RResp    : std_logic_vector(1 downto 0);
    signal B_RValid   : std_logic;
    signal B_RReady   : std_logic;

begin

    i_ti_uvvm_engine : entity uvvm_vvc_framework.ti_uvvm_engine;

    -- The clock is driven on the port, so that testbench and DUT see the same signal (no delta cycle between them)
    Clk_i <= not Clk_i after ClkPeriod_c / 2;
    Clk   <= Clk_i;
    IrqA  <= A_Irq;

    -----------------------------------------------------------------------------------------------
    -- Core A: messages of set 0
    -----------------------------------------------------------------------------------------------
    i_core_a : entity work.ocr_core
        generic map (
            DataWidth_g     => DataWidth_g,
            KeyBits_g       => KeyBits_g,
            NumKeys_g       => NumKeys_g,
            ReleaseBuffer_g => ReleaseBuffer_g,
            ReleaseBytes_g  => ReleaseBytes_g
        )
        port map (
            Clk               => Clk_i,
            Rst               => Rst,
            S_Ctx_Valid       => A_CtxValid,
            S_Ctx_Ready       => A_CtxReady,
            S_Ctx_Decrypt     => A_CtxDec,
            S_Ctx_Slot        => A_CtxSlot,
            S_Ctx_IvGen       => A_CtxIvGen,
            S_Ctx_Iv          => A_CtxIv,
            S_In_Valid        => A_InValid,
            S_In_Ready        => A_InReady,
            S_In_Data         => A_InData,
            S_In_Keep         => A_InKeep,
            S_In_Last         => A_InLast,
            S_In_User         => A_InUser,
            M_Out_Valid       => A_OutValid,
            M_Out_Ready       => A_OutReady,
            M_Out_Data        => A_OutData,
            M_Out_Keep        => A_OutKeep,
            M_Out_Last        => A_OutLast,
            M_Out_User        => A_OutUser,
            M_Sts_Valid       => A_StsValid,
            M_Sts_Ready       => A_StsReady,
            M_Sts_Code        => A_StsCode,
            M_Sts_Decrypt     => A_StsDec,
            M_Sts_Slot        => A_StsSlot,
            M_Sts_Iv          => A_StsIv,
            M_Sts_AadBytes    => A_StsAad,
            M_Sts_DataBytes   => A_StsData,
            S_AxiLite_ArAddr  => A_ArAddr,
            S_AxiLite_ArValid => A_ArValid,
            S_AxiLite_ArReady => A_ArReady,
            S_AxiLite_AwAddr  => A_AwAddr,
            S_AxiLite_AwValid => A_AwValid,
            S_AxiLite_AwReady => A_AwReady,
            S_AxiLite_WData   => A_WData,
            S_AxiLite_WStrb   => A_WStrb,
            S_AxiLite_WValid  => A_WValid,
            S_AxiLite_WReady  => A_WReady,
            S_AxiLite_BResp   => A_BResp,
            S_AxiLite_BValid  => A_BValid,
            S_AxiLite_BReady  => A_BReady,
            S_AxiLite_RData   => A_RData,
            S_AxiLite_RResp   => A_RResp,
            S_AxiLite_RValid  => A_RValid,
            S_AxiLite_RReady  => A_RReady,
            Irq               => A_Irq
        );

    i_axi_a : entity work.ocr_tb_axilite_master
        generic map (
            InstanceIdx_g => 0,
            AddrWidth_g   => AxiAddrBits_c
        )
        port map (
            Clk     => Clk_i,
            ArAddr  => A_ArAddr,
            ArValid => A_ArValid,
            ArReady => A_ArReady,
            AwAddr  => A_AwAddr,
            AwValid => A_AwValid,
            AwReady => A_AwReady,
            WData   => A_WData,
            WStrb   => A_WStrb,
            WValid  => A_WValid,
            WReady  => A_WReady,
            BResp   => A_BResp,
            BValid  => A_BValid,
            BReady  => A_BReady,
            RData   => A_RData,
            RResp   => A_RResp,
            RValid  => A_RValid,
            RReady  => A_RReady
        );

    i_ctx_a : entity work.ocr_tb_ctx_source
        generic map (
            Channel_g  => ChCtx_c,
            SlotBits_g => SlotBits_c,
            Decrypt_g  => false
        )
        port map (
            Clk         => Clk_i,
            Ctx_Valid   => A_CtxValid,
            Ctx_Ready   => A_CtxReady,
            Ctx_Decrypt => A_CtxDec,
            Ctx_Slot    => A_CtxSlot,
            Ctx_IvGen   => A_CtxIvGen,
            Ctx_Iv      => A_CtxIv
        );

    i_sts_a : entity work.ocr_tb_sts_sink
        generic map (
            Channel_g  => ChSts_c,
            SlotBits_g => SlotBits_c,
            LenBits_g  => 32,
            Decrypt_g  => false
        )
        port map (
            Clk          => Clk_i,
            In_Valid     => A_StsValid,
            In_Ready     => A_StsReady,
            In_Code      => A_StsCode,
            In_Decrypt   => A_StsDec,
            In_Slot      => A_StsSlot,
            In_Iv        => A_StsIv,
            In_AadBytes  => A_StsAad,
            In_DataBytes => A_StsData
        );

    i_source_a : entity work.ocr_tb_msg_source
        generic map (
            DataWidth_g => DataWidth_g
        )
        port map (
            Clk       => Clk_i,
            Out_Valid => A_InValid,
            Out_Ready => A_InReady,
            Out_Data  => A_InData,
            Out_Keep  => A_InKeep,
            Out_Last  => A_InLast,
            Out_User  => A_InUser
        );

    g_single : if not Series_g generate

        i_sink_a : entity work.ocr_tb_msg_sink
            generic map (
                Channel_g   => ChSink_c,
                DataWidth_g => DataWidth_g,
                Decrypt_g   => false
            )
            port map (
                Clk      => Clk_i,
                In_Valid => A_OutValid,
                In_Ready => A_OutReady,
                In_Data  => A_OutData,
                In_Keep  => A_OutKeep,
                In_Last  => A_OutLast,
                In_User  => A_OutUser
            );

    end generate;

    -----------------------------------------------------------------------------------------------
    -- Core B: decrypts the output of core A
    -----------------------------------------------------------------------------------------------
    g_series : if Series_g generate
        B_InValid  <= A_OutValid;
        A_OutReady <= B_InReady;
        B_InData   <= A_OutData;
        B_InKeep   <= A_OutKeep;
        B_InLast   <= A_OutLast;
        B_InUser   <= A_OutUser(1 downto 0);

        i_core_b : entity work.ocr_core
            generic map (
                DataWidth_g     => DataWidth_g,
                KeyBits_g       => KeyBits_g,
                NumKeys_g       => NumKeys_g,
                ReleaseBuffer_g => ReleaseBuffer_g,
                ReleaseBytes_g  => ReleaseBytes_g
            )
            port map (
                Clk               => Clk_i,
                Rst               => Rst,
                S_Ctx_Valid       => B_CtxValid,
                S_Ctx_Ready       => B_CtxReady,
                S_Ctx_Decrypt     => B_CtxDec,
                S_Ctx_Slot        => B_CtxSlot,
                S_Ctx_IvGen       => B_CtxIvGen,
                S_Ctx_Iv          => B_CtxIv,
                S_In_Valid        => B_InValid,
                S_In_Ready        => B_InReady,
                S_In_Data         => B_InData,
                S_In_Keep         => B_InKeep,
                S_In_Last         => B_InLast,
                S_In_User         => B_InUser,
                M_Out_Valid       => B_OutValid,
                M_Out_Ready       => B_OutReady,
                M_Out_Data        => B_OutData,
                M_Out_Keep        => B_OutKeep,
                M_Out_Last        => B_OutLast,
                M_Out_User        => B_OutUser,
                M_Sts_Valid       => B_StsValid,
                M_Sts_Ready       => B_StsReady,
                M_Sts_Code        => B_StsCode,
                M_Sts_Decrypt     => B_StsDec,
                M_Sts_Slot        => B_StsSlot,
                M_Sts_Iv          => B_StsIv,
                M_Sts_AadBytes    => B_StsAad,
                M_Sts_DataBytes   => B_StsData,
                S_AxiLite_ArAddr  => B_ArAddr,
                S_AxiLite_ArValid => B_ArValid,
                S_AxiLite_ArReady => B_ArReady,
                S_AxiLite_AwAddr  => B_AwAddr,
                S_AxiLite_AwValid => B_AwValid,
                S_AxiLite_AwReady => B_AwReady,
                S_AxiLite_WData   => B_WData,
                S_AxiLite_WStrb   => B_WStrb,
                S_AxiLite_WValid  => B_WValid,
                S_AxiLite_WReady  => B_WReady,
                S_AxiLite_BResp   => B_BResp,
                S_AxiLite_BValid  => B_BValid,
                S_AxiLite_BReady  => B_BReady,
                S_AxiLite_RData   => B_RData,
                S_AxiLite_RResp   => B_RResp,
                S_AxiLite_RValid  => B_RValid,
                S_AxiLite_RReady  => B_RReady,
                Irq               => B_Irq
            );

        i_axi_b : entity work.ocr_tb_axilite_master
            generic map (
                InstanceIdx_g => 1,
                AddrWidth_g   => AxiAddrBits_c
            )
            port map (
                Clk     => Clk_i,
                ArAddr  => B_ArAddr,
                ArValid => B_ArValid,
                ArReady => B_ArReady,
                AwAddr  => B_AwAddr,
                AwValid => B_AwValid,
                AwReady => B_AwReady,
                WData   => B_WData,
                WStrb   => B_WStrb,
                WValid  => B_WValid,
                WReady  => B_WReady,
                BResp   => B_BResp,
                BValid  => B_BValid,
                BReady  => B_BReady,
                RData   => B_RData,
                RResp   => B_RResp,
                RValid  => B_RValid,
                RReady  => B_RReady
            );

        i_ctx_b : entity work.ocr_tb_ctx_source
            generic map (
                Channel_g  => 4,
                SlotBits_g => SlotBits_c,
                Decrypt_g  => true
            )
            port map (
                Clk         => Clk_i,
                Ctx_Valid   => B_CtxValid,
                Ctx_Ready   => B_CtxReady,
                Ctx_Decrypt => B_CtxDec,
                Ctx_Slot    => B_CtxSlot,
                Ctx_IvGen   => B_CtxIvGen,
                Ctx_Iv      => B_CtxIv
            );

        i_sts_b : entity work.ocr_tb_sts_sink
            generic map (
                Channel_g  => 6,
                SlotBits_g => SlotBits_c,
                LenBits_g  => 32,
                Decrypt_g  => true
            )
            port map (
                Clk          => Clk_i,
                In_Valid     => B_StsValid,
                In_Ready     => B_StsReady,
                In_Code      => B_StsCode,
                In_Decrypt   => B_StsDec,
                In_Slot      => B_StsSlot,
                In_Iv        => B_StsIv,
                In_AadBytes  => B_StsAad,
                In_DataBytes => B_StsData
            );

        i_sink_b : entity work.ocr_tb_msg_sink
            generic map (
                Channel_g   => 5,
                DataWidth_g => DataWidth_g,
                Decrypt_g   => true
            )
            port map (
                Clk      => Clk_i,
                In_Valid => B_OutValid,
                In_Ready => B_OutReady,
                In_Data  => B_OutData,
                In_Keep  => B_OutKeep,
                In_Last  => B_OutLast,
                In_User  => B_OutUser
            );

    end generate;

end architecture;
