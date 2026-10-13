---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Test harness of ocr_framer: clock, the UVVM engine, the packet source of vector set 0 and the
-- framer. Without Core_g the framer output goes to a message sink (TUser(2): an IV section code was
-- seen in the message) and its contexts to a context checker (channel 1). With Core_g the framer feeds
-- ocr_core with the dense output (AXI4-Lite VVC index 0), whose output and status go to a dense message
-- sink and a status sink.
--
-- Documentation: hdl/ocr_framer/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;
    use ieee.math_real.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library uvvm_vvc_framework;
    use uvvm_vvc_framework.ti_vvc_framework_support_pkg.all;

library work;
    use work.ocr_pkg.all;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;
    use work.ocr_tb_axi_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_framer_th is
    generic (
        DataWidth_g    : positive := 32;
        KeyBits_g      : positive := 256;
        NumKeys_g      : positive := 4;
        ChunkBytes_g   : positive := 64;
        BufferChunks_g : positive := 2;
        Core_g         : boolean  := false
    );
    port (
        Clk            : out   std_logic;
        Rst            : in    std_logic;
        CfgSlot        : in    std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        ErrInj_Sel     : in    std_logic;
        ErrInj_BitFlip : in    std_logic_vector(1 downto 0);
        ErrInj_Valid   : in    std_logic;
        Ecc_Sec        : out   std_logic_vector(1 downto 0);
        Ecc_Ded        : out   std_logic_vector(1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_framer_th is

    constant ClkPeriod_c : time     := 10 ns;
    constant SlotBits_c  : positive := slotBits(NumKeys_g);
    constant Bytes_c     : positive := DataWidth_g / 8;

    signal Clk_i    : std_logic := '0';
    -- Source to framer
    signal InValid  : std_logic;
    signal InReady  : std_logic;
    signal InData   : std_logic_vector(DataWidth_g - 1 downto 0);
    signal InKeep   : std_logic_vector(Bytes_c - 1 downto 0);
    signal InLast   : std_logic;
    -- Framer to core (or to the checkers)
    signal CtxValid : std_logic;
    signal CtxReady : std_logic;
    signal CtxDec   : std_logic;
    signal CtxSlot  : std_logic_vector(SlotBits_c - 1 downto 0);
    signal CtxIvGen : std_logic;
    signal CtxIv    : std_logic_vector(95 downto 0);
    signal MsgValid : std_logic;
    signal MsgReady : std_logic;
    signal MsgData  : std_logic_vector(DataWidth_g - 1 downto 0);
    signal MsgKeep  : std_logic_vector(Bytes_c - 1 downto 0);
    signal MsgLast  : std_logic;
    signal MsgUser  : std_logic_vector(1 downto 0);
    -- Framer alone: IV section code seen in the message
    signal IvSeen   : std_logic := '0';
    signal MsgFlag  : std_logic;
    -- Core
    signal OutValid : std_logic;
    signal OutReady : std_logic;
    signal OutData  : std_logic_vector(DataWidth_g - 1 downto 0);
    signal OutKeep  : std_logic_vector(Bytes_c - 1 downto 0);
    signal OutLast  : std_logic;
    signal OutUser  : std_logic_vector(2 downto 0);
    signal StsValid : std_logic;
    signal StsReady : std_logic;
    signal StsCode  : std_logic_vector(3 downto 0);
    signal StsDec   : std_logic;
    signal StsSlot  : std_logic_vector(SlotBits_c - 1 downto 0);
    signal StsIv    : std_logic_vector(95 downto 0);
    signal StsAad   : std_logic_vector(31 downto 0);
    signal StsData  : std_logic_vector(31 downto 0);
    signal Irq      : std_logic;
    signal ArAddr   : std_logic_vector(7 downto 0);
    signal ArValid  : std_logic;
    signal ArReady  : std_logic;
    signal AwAddr   : std_logic_vector(7 downto 0);
    signal AwValid  : std_logic;
    signal AwReady  : std_logic;
    signal WData    : std_logic_vector(31 downto 0);
    signal WStrb    : std_logic_vector(3 downto 0);
    signal WValid   : std_logic;
    signal WReady   : std_logic;
    signal BResp    : std_logic_vector(1 downto 0);
    signal BValid   : std_logic;
    signal BReady   : std_logic;
    signal RData    : std_logic_vector(31 downto 0);
    signal RResp    : std_logic_vector(1 downto 0);
    signal RValid   : std_logic;
    signal RReady   : std_logic;

begin

    i_ti_uvvm_engine : entity uvvm_vvc_framework.ti_uvvm_engine;

    -- The clock is driven on the port, so that testbench and DUT see the same signal (no delta cycle between them)
    Clk_i <= not Clk_i after ClkPeriod_c / 2;
    Clk   <= Clk_i;

    i_source : entity work.ocr_tb_msg_source
        generic map (
            DataWidth_g => DataWidth_g,
            Plain_g     => true
        )
        port map (
            Clk       => Clk_i,
            Out_Valid => InValid,
            Out_Ready => InReady,
            Out_Data  => InData,
            Out_Keep  => InKeep,
            Out_Last  => InLast,
            Out_User  => open,
            Out_Err   => open
        );

    i_dut : entity work.ocr_framer
        generic map (
            DataWidth_g    => DataWidth_g,
            NumKeys_g      => NumKeys_g,
            ChunkBytes_g   => ChunkBytes_g,
            BufferChunks_g => BufferChunks_g
        )
        port map (
            Clk            => Clk_i,
            Rst            => Rst,
            Cfg_Slot       => CfgSlot,
            S_In_Valid     => InValid,
            S_In_Ready     => InReady,
            S_In_Data      => InData,
            S_In_Keep      => InKeep,
            S_In_Last      => InLast,
            M_Ctx_Valid    => CtxValid,
            M_Ctx_Ready    => CtxReady,
            M_Ctx_Decrypt  => CtxDec,
            M_Ctx_Slot     => CtxSlot,
            M_Ctx_IvGen    => CtxIvGen,
            M_Ctx_Iv       => CtxIv,
            M_Out_Valid    => MsgValid,
            M_Out_Ready    => MsgReady,
            M_Out_Data     => MsgData,
            M_Out_Keep     => MsgKeep,
            M_Out_Last     => MsgLast,
            M_Out_User     => MsgUser,
            Ecc_Sec        => Ecc_Sec,
            Ecc_Ded        => Ecc_Ded,
            ErrInj_Sel     => ErrInj_Sel,
            ErrInj_BitFlip => ErrInj_BitFlip,
            ErrInj_Valid   => ErrInj_Valid
        );

    -----------------------------------------------------------------------------------------------
    -- Framer alone
    -----------------------------------------------------------------------------------------------
    g_alone : if not Core_g generate

        -- Context checker: random cycles without ready; every context is an encryption with a generated IV of
        -- the configured slot; counts the contexts as beats of channel 1
        p_ctx : process is
            variable Seed1_v : positive := 77;
            variable Seed2_v : positive := 991;
            variable Rand_v  : real;
        begin
            CtxReady <= '0';
            wait until rising_edge(Clk_i);

            loop
                uniform(Seed1_v, Seed2_v, Rand_v);
                if Rand_v >= OcrVec_v.stall(0, ChCtx_c) then
                    CtxReady <= '1';
                else
                    CtxReady <= '0';
                end if;
                wait until rising_edge(Clk_i);
                if CtxValid = '1' and CtxReady = '1' then
                    check_value(CtxDec, '0', ERROR, "context direction", "ocr_framer_th");
                    check_value(CtxIvGen, '1', ERROR, "context IV source", "ocr_framer_th");
                    check_value(CtxSlot, CfgSlot, ERROR, "context slot", "ocr_framer_th");
                    check_value(CtxIv, (95 downto 0 => '0'), ERROR, "context IV", "ocr_framer_th");
                    OcrVec_v.addBeat(0, ChCtx_c, now);
                end if;
            end loop;

        end process;

        -- An IV section code in a message (double error) is reported on TUser(2), sticky until the end of the message
        p_iv : process (Clk_i) is
        begin
            if rising_edge(Clk_i) then
                if MsgValid = '1' and MsgReady = '1' then
                    if MsgLast = '1' then
                        IvSeen <= '0';
                    elsif MsgUser = SecIv_c then
                        IvSeen <= '1';
                    end if;
                end if;
                if Rst = '1' then
                    IvSeen <= '0';
                end if;
            end if;
        end process;

        MsgFlag <= '1' when IvSeen = '1' or MsgUser = SecIv_c else '0';

        i_sink : entity work.ocr_tb_msg_sink
            generic map (
                Channel_g   => ChSink_c,
                DataWidth_g => DataWidth_g
            )
            port map (
                Clk      => Clk_i,
                In_Valid => MsgValid,
                In_Ready => MsgReady,
                In_Data  => MsgData,
                In_Keep  => MsgKeep,
                In_Last  => MsgLast,
                In_User  => MsgFlag & MsgUser
            );

    end generate;

    -----------------------------------------------------------------------------------------------
    -- Framer and core with the dense output
    -----------------------------------------------------------------------------------------------
    g_core : if Core_g generate

        i_core : entity work.ocr_core
            generic map (
                DataWidth_g   => DataWidth_g,
                KeyBits_g     => KeyBits_g,
                NumKeys_g     => NumKeys_g,
                DenseOutput_g => true
            )
            port map (
                Clk               => Clk_i,
                Rst               => Rst,
                S_Ctx_Valid       => CtxValid,
                S_Ctx_Ready       => CtxReady,
                S_Ctx_Decrypt     => CtxDec,
                S_Ctx_Slot        => CtxSlot,
                S_Ctx_IvGen       => CtxIvGen,
                S_Ctx_Iv          => CtxIv,
                S_In_Valid        => MsgValid,
                S_In_Ready        => MsgReady,
                S_In_Data         => MsgData,
                S_In_Keep         => MsgKeep,
                S_In_Last         => MsgLast,
                S_In_User         => MsgUser,
                M_Out_Valid       => OutValid,
                M_Out_Ready       => OutReady,
                M_Out_Data        => OutData,
                M_Out_Keep        => OutKeep,
                M_Out_Last        => OutLast,
                M_Out_User        => OutUser,
                M_Sts_Valid       => StsValid,
                M_Sts_Ready       => StsReady,
                M_Sts_Code        => StsCode,
                M_Sts_Decrypt     => StsDec,
                M_Sts_Slot        => StsSlot,
                M_Sts_Iv          => StsIv,
                M_Sts_AadBytes    => StsAad,
                M_Sts_DataBytes   => StsData,
                S_AxiLite_ArAddr  => ArAddr,
                S_AxiLite_ArValid => ArValid,
                S_AxiLite_ArReady => ArReady,
                S_AxiLite_AwAddr  => AwAddr,
                S_AxiLite_AwValid => AwValid,
                S_AxiLite_AwReady => AwReady,
                S_AxiLite_WData   => WData,
                S_AxiLite_WStrb   => WStrb,
                S_AxiLite_WValid  => WValid,
                S_AxiLite_WReady  => WReady,
                S_AxiLite_BResp   => BResp,
                S_AxiLite_BValid  => BValid,
                S_AxiLite_BReady  => BReady,
                S_AxiLite_RData   => RData,
                S_AxiLite_RResp   => RResp,
                S_AxiLite_RValid  => RValid,
                S_AxiLite_RReady  => RReady,
                Irq               => Irq
            );

        i_axi : entity work.ocr_tb_axilite_master
            generic map (
                InstanceIdx_g => 0,
                AddrWidth_g   => AxiAddrBits_c
            )
            port map (
                Clk     => Clk_i,
                ArAddr  => ArAddr,
                ArValid => ArValid,
                ArReady => ArReady,
                AwAddr  => AwAddr,
                AwValid => AwValid,
                AwReady => AwReady,
                WData   => WData,
                WStrb   => WStrb,
                WValid  => WValid,
                WReady  => WReady,
                BResp   => BResp,
                BValid  => BValid,
                BReady  => BReady,
                RData   => RData,
                RResp   => RResp,
                RValid  => RValid,
                RReady  => RReady
            );

        i_sts : entity work.ocr_tb_sts_sink
            generic map (
                Channel_g  => ChSts_c,
                SlotBits_g => SlotBits_c,
                LenBits_g  => 32
            )
            port map (
                Clk          => Clk_i,
                In_Valid     => StsValid,
                In_Ready     => StsReady,
                In_Code      => StsCode,
                In_Decrypt   => StsDec,
                In_Slot      => StsSlot,
                In_Iv        => StsIv,
                In_AadBytes  => StsAad,
                In_DataBytes => StsData
            );

        i_sink : entity work.ocr_tb_msg_sink
            generic map (
                Channel_g   => ChSink_c,
                DataWidth_g => DataWidth_g,
                Dense_g     => true
            )
            port map (
                Clk      => Clk_i,
                In_Valid => OutValid,
                In_Ready => OutReady,
                In_Data  => OutData,
                In_Keep  => OutKeep,
                In_Last  => OutLast,
                In_User  => OutUser
            );

    end generate;

end architecture;
