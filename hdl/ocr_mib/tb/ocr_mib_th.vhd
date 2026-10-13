---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Test harness of ocr_mib: clock, the UVVM engine, the register file and an AXI4-Lite VVC (index 0).
-- The interfaces to the key table and to the data path are ports of the harness: the test sequencer
-- plays the key table (load handshake, busy, query response) and the data path (status events, ECC
-- events) and observes the commands and the error injection.
--
-- Documentation: hdl/ocr_mib/docs/verification_plan.md

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
    use work.ocr_tb_axi_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_mib_th is
    generic (
        KeyBits_g : positive := 256;
        NumKeys_g : positive := 4
    );
    port (
        Clk               : out   std_logic;
        Rst               : in    std_logic;
        Irq               : out   std_logic;
        M_Load_Valid      : out   std_logic;
        M_Load_Ready      : in    std_logic;
        M_Load_Slot       : out   std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        M_Load_Key        : out   std_logic_vector(KeyBits_g - 1 downto 0);
        M_Load_IvGen      : out   std_logic;
        M_Load_Fixed      : out   std_logic_vector(31 downto 0);
        M_Load_Counter    : out   std_logic_vector(63 downto 0);
        Zeroize           : out   std_logic;
        Kt_Busy           : in    std_logic;
        M_Query_Valid     : out   std_logic;
        M_Query_Ready     : in    std_logic;
        M_Query_Slot      : out   std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        S_Query_Valid     : in    std_logic;
        S_Query_KeyValid  : in    std_logic;
        S_Query_IvGen     : in    std_logic;
        S_Query_Exhausted : in    std_logic;
        S_Query_Fixed     : in    std_logic_vector(31 downto 0);
        S_Query_Counter   : in    std_logic_vector(63 downto 0);
        S_Query_Ded       : in    std_logic;
        Evt_Valid         : in    std_logic;
        Evt_Code          : in    Status_t;
        Evt_Decrypt       : in    std_logic;
        Ecc_Sec           : in    std_logic_vector(17 downto 0);
        Ecc_Ded           : in    std_logic_vector(17 downto 0);
        Gcm_ErrInj_Sel    : out   std_logic_vector(3 downto 0);
        Kt_ErrInj_Sel     : out   std_logic_vector(1 downto 0);
        ErrInj_BitFlip    : out   std_logic_vector(1 downto 0);
        Gcm_ErrInj_Valid  : out   std_logic;
        Kt_ErrInj_Valid   : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_mib_th is

    constant ClkPeriod_c : time := 10 ns;

    signal Clk_i   : std_logic := '0';
    signal ArAddr  : std_logic_vector(7 downto 0);
    signal ArValid : std_logic;
    signal ArReady : std_logic;
    signal AwAddr  : std_logic_vector(7 downto 0);
    signal AwValid : std_logic;
    signal AwReady : std_logic;
    signal WData   : std_logic_vector(31 downto 0);
    signal WStrb   : std_logic_vector(3 downto 0);
    signal WValid  : std_logic;
    signal WReady  : std_logic;
    signal BResp   : std_logic_vector(1 downto 0);
    signal BValid  : std_logic;
    signal BReady  : std_logic;
    signal RData   : std_logic_vector(31 downto 0);
    signal RResp   : std_logic_vector(1 downto 0);
    signal RValid  : std_logic;
    signal RReady  : std_logic;

begin

    i_ti_uvvm_engine : entity uvvm_vvc_framework.ti_uvvm_engine;

    Clk_i <= not Clk_i after ClkPeriod_c / 2;
    Clk   <= Clk_i;

    i_dut : entity work.ocr_mib
        generic map (
            DataWidth_g     => 64,
            KeyBits_g       => KeyBits_g,
            NumKeys_g       => NumKeys_g,
            AesUnits_g      => 10,
            GhashDigit_g    => 128,
            LenBits_g       => 20,
            ReleaseBuffer_g => true,
            ReleaseBytes_g  => 2048,
            DenseOutput_g   => true
        )
        port map (
            Clk               => Clk_i,
            Rst               => Rst,
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
            Irq               => Irq,
            M_Load_Valid      => M_Load_Valid,
            M_Load_Ready      => M_Load_Ready,
            M_Load_Slot       => M_Load_Slot,
            M_Load_Key        => M_Load_Key,
            M_Load_IvGen      => M_Load_IvGen,
            M_Load_Fixed      => M_Load_Fixed,
            M_Load_Counter    => M_Load_Counter,
            Zeroize           => Zeroize,
            Kt_Busy           => Kt_Busy,
            M_Query_Valid     => M_Query_Valid,
            M_Query_Ready     => M_Query_Ready,
            M_Query_Slot      => M_Query_Slot,
            S_Query_Valid     => S_Query_Valid,
            S_Query_KeyValid  => S_Query_KeyValid,
            S_Query_IvGen     => S_Query_IvGen,
            S_Query_Exhausted => S_Query_Exhausted,
            S_Query_Fixed     => S_Query_Fixed,
            S_Query_Counter   => S_Query_Counter,
            S_Query_Ded       => S_Query_Ded,
            Evt_Valid         => Evt_Valid,
            Evt_Code          => Evt_Code,
            Evt_Decrypt       => Evt_Decrypt,
            Ecc_Sec           => Ecc_Sec,
            Ecc_Ded           => Ecc_Ded,
            Gcm_ErrInj_Sel    => Gcm_ErrInj_Sel,
            Kt_ErrInj_Sel     => Kt_ErrInj_Sel,
            ErrInj_BitFlip    => ErrInj_BitFlip,
            Gcm_ErrInj_Valid  => Gcm_ErrInj_Valid,
            Kt_ErrInj_Valid   => Kt_ErrInj_Valid
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

end architecture;
