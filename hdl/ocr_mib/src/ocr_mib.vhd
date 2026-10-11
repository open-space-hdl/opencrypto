---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Register file of OpenCrypto (MG-1, MG-2): key load through self-clearing write-only staging
-- registers, zeroize, slot query, counters per status code, event flags with interrupt, the EDAC
-- monitor of the buffers and memories and the error injection, behind an AXI4-Lite slave. The register
-- map is generated from hdl/ocr_mib/regs/ocr_regs.yml.
--
-- Documentation: hdl/ocr_mib/docs/specification.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library olo;

library work;
    use work.ocr_pkg.all;
    use work.ocr_regs_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_mib is
    generic (
        DataWidth_g     : positive := 32;
        KeyBits_g       : positive := 256;
        NumKeys_g       : positive := 4;
        AesUnits_g      : positive := 6;
        GhashDigit_g    : positive := 64;
        LenBits_g       : positive := 32;
        ReleaseBuffer_g : boolean  := false;
        ReleaseBytes_g  : natural  := 0
    );
    port (
        -- Control
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        -- AXI4-Lite
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
        Irq               : out   std_logic;
        -- Key table: load, zeroize, busy
        M_Load_Valid      : out   std_logic;
        M_Load_Ready      : in    std_logic;
        M_Load_Slot       : out   std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        M_Load_Key        : out   std_logic_vector(KeyBits_g - 1 downto 0);
        M_Load_IvGen      : out   std_logic;
        M_Load_Fixed      : out   std_logic_vector(31 downto 0);
        M_Load_Counter    : out   std_logic_vector(63 downto 0);
        Zeroize           : out   std_logic;
        Kt_Busy           : in    std_logic;
        -- Key table: slot query
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
        -- Status of every message (one-cycle event when it is written)
        Evt_Valid         : in    std_logic;
        Evt_Code          : in    Status_t;
        Evt_Decrypt       : in    std_logic;
        -- ECC events of the 18 channels and error injection
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
architecture rtl of ocr_mib is

    constant SlotBits_c : positive := slotBits(NumKeys_g);
    constant Nk_c       : positive := KeyBits_g / 32;
    constant Events_c   : positive := 11;

    type KeyWords_t is array (0 to 7) of std_logic_vector(31 downto 0);

    -- Message counters: 0 encryptions, 1 decryptions, 2 to 9 the status codes 1 to 8
    type Counters_t is array (0 to 9) of unsigned(31 downto 0);

    type TwoProcess_r is record
        Key       : KeyWords_t;
        IvFixed   : std_logic_vector(31 downto 0);
        IvCount   : std_logic_vector(63 downto 0);
        LoadSlot  : std_logic_vector(SlotBits_c - 1 downto 0);
        LoadIvGen : std_logic;
        LoadReq   : std_logic;  -- load requested, not yet taken by the key table
        LoadRun   : std_logic;  -- load taken, the key table is busy with it
        Zeroize   : std_logic;
        QuerySlot : std_logic_vector(7 downto 0);
        QueryReq  : std_logic;
        QueryPend : std_logic;
        QValid    : std_logic;
        QIvGen    : std_logic;
        QExh      : std_logic;
        QDed      : std_logic;
        QFixed    : std_logic_vector(31 downto 0);
        QCounter  : std_logic_vector(63 downto 0);
        Cnt       : Counters_t;
        Events    : std_logic_vector(Events_c - 1 downto 0);
        IrqEn     : std_logic_vector(Events_c - 1 downto 0);
        Irq       : std_logic;
        EccSelect : std_logic_vector(4 downto 0);
        EccClr    : std_logic;
        EccRdClr  : std_logic;
        InjTarget : std_logic_vector(4 downto 0);
        InjPat    : std_logic_vector(1 downto 0);
        InjGcm    : std_logic;
        InjKt     : std_logic;
        RdValid   : std_logic;
        RdData    : std_logic_vector(31 downto 0);
    end record;

    signal r, r_next : TwoProcess_r;

    signal RbAddr    : std_logic_vector(7 downto 0);
    signal RbWr      : std_logic;
    signal RbWrData  : std_logic_vector(31 downto 0);
    signal RbRd      : std_logic;
    signal EccSecCnt : std_logic_vector(15 downto 0);
    signal EccDedCnt : std_logic_vector(15 downto 0);
    signal EccDed    : std_logic_vector(17 downto 0);
    signal EvtSec    : std_logic;
    signal EvtDed    : std_logic;

    function toSl (b : boolean) return std_logic is
    begin
        if b then
            return '1';
        end if;
        return '0';
    end function;

    -- Saturating counter step
    function incSat (c : unsigned) return unsigned is
    begin
        if c = (c'range => '1') then
            return c;
        end if;
        return c + 1;
    end function;

begin

    p_comb : process (all) is
        variable v      : TwoProcess_r;
        variable Addr_v : natural range 0 to 255;
        variable Wr_v   : std_logic_vector(31 downto 0);
        variable Rd_v   : std_logic_vector(31 downto 0);
        variable Code_v : natural range 0 to 15;
        variable Key_v  : std_logic_vector(255 downto 0);
    begin
        -- Hold variables stable
        v          := r;
        v.EccClr   := '0';
        v.EccRdClr := '0';
        v.InjGcm   := '0';
        v.InjKt    := '0';
        v.Zeroize  := '0';
        v.RdValid  := '0';

        -------------------------------------------------------------------------------------------
        -- Register writes; a clear is applied before the events of the same cycle
        -------------------------------------------------------------------------------------------
        Addr_v := to_integer(unsigned(std_logic_vector'(RbAddr(7 downto 2) & "00")));
        Wr_v   := RbWrData;
        if RbWr = '1' then
            if Addr_v >= RegKeyBase_c and Addr_v < RegKeyBase_c + 8 * RegKeyStride_c then
                v.Key((Addr_v - RegKeyBase_c) / RegKeyStride_c) := Wr_v;
            end if;

            case Addr_v is
                when RegCtrl_c =>
                    if Wr_v(CtrlZeroize_c) = '1' then
                        -- The staging registers are erased with the key table
                        v.Zeroize := '1';
                        v.Key     := (others => (others => '0'));
                        v.IvFixed := (others => '0');
                        v.IvCount := (others => '0');
                        v.LoadReq := '0';
                    end if;
                    if Wr_v(CtrlClear_c) = '1' then
                        v.Cnt := (others => (others => '0'));
                    end if;
                when RegEvents_c =>
                    v.Events := r.Events and not Wr_v(Events_c - 1 downto 0);
                when RegIrqEn_c =>
                    v.IrqEn := Wr_v(IrqEnEnableHi_c downto IrqEnEnableLo_c);
                when RegIvFixed_c =>
                    v.IvFixed := Wr_v;
                when RegIvCountLo_c =>
                    v.IvCount(31 downto 0) := Wr_v;
                when RegIvCountHi_c =>
                    v.IvCount(63 downto 32) := Wr_v;
                when RegKeyLoad_c =>
                    -- A load of a slot beyond the key table is ignored
                    if Wr_v(KeyLoadStart_c) = '1' and r.LoadReq = '0' and r.LoadRun = '0' and
                       unsigned(Wr_v(KeyLoadSlotHi_c downto KeyLoadSlotLo_c)) < NumKeys_g then
                        v.LoadReq   := '1';
                        v.LoadSlot  := Wr_v(KeyLoadSlotLo_c + SlotBits_c - 1 downto KeyLoadSlotLo_c);
                        v.LoadIvGen := Wr_v(KeyLoadIvGen_c);
                    end if;
                when RegSlotQuery_c =>
                    v.QuerySlot := Wr_v(SlotQuerySlotHi_c downto SlotQuerySlotLo_c);
                    v.QueryReq  := '1';
                    v.QueryPend := '1';
                when RegEncryptions_c => v.Cnt(0) := (others => '0');
                when RegDecryptions_c => v.Cnt(1) := (others => '0');
                when RegErrAuth_c => v.Cnt(2) := (others => '0');
                when RegErrFormat_c => v.Cnt(3) := (others => '0');
                when RegErrKey_c => v.Cnt(4) := (others => '0');
                when RegErrIvMode_c => v.Cnt(5) := (others => '0');
                when RegErrIvExhausted_c => v.Cnt(6) := (others => '0');
                when RegErrLength_c => v.Cnt(7) := (others => '0');
                when RegErrEcc_c => v.Cnt(8) := (others => '0');
                when RegErrOverflow_c => v.Cnt(9) := (others => '0');
                when RegEccStatus_c =>
                    v.EccClr := '1';
                when RegEccSelect_c =>
                    v.EccSelect := Wr_v(EccSelectChannelHi_c downto EccSelectChannelLo_c);
                when RegEccCount_c =>
                    v.EccRdClr := '1';
                when RegEccInject_c =>
                    v.InjTarget := Wr_v(EccInjectTargetHi_c downto EccInjectTargetLo_c);
                    v.InjPat    := Wr_v(EccInjectDouble_c) & (Wr_v(EccInjectSingle_c) or Wr_v(EccInjectDouble_c));
                    if Wr_v(EccInjectSingle_c) = '1' or Wr_v(EccInjectDouble_c) = '1' then
                        if Wr_v(EccInjectTargetHi_c) = '1' then
                            v.InjKt := '1';
                        else
                            v.InjGcm := '1';
                        end if;
                    end if;
                when others =>
                    null;
            end case;

        end if;

        -------------------------------------------------------------------------------------------
        -- Key load: the staging registers are cleared when the key table takes the load
        -------------------------------------------------------------------------------------------
        Key_v := (others => '0');

        for i in 0 to 7 loop
            Key_v(255 - 32 * i downto 224 - 32 * i) := r.Key(i);
        end loop;

        M_Load_Valid   <= r.LoadReq;
        M_Load_Slot    <= r.LoadSlot;
        M_Load_Key     <= Key_v(255 downto 256 - KeyBits_g);
        M_Load_IvGen   <= r.LoadIvGen;
        M_Load_Fixed   <= r.IvFixed;
        M_Load_Counter <= r.IvCount;
        if r.LoadReq = '1' and M_Load_Ready = '1' then
            v.LoadReq := '0';
            v.LoadRun := '1';
            v.Key     := (others => (others => '0'));
            v.IvFixed := (others => '0');
            v.IvCount := (others => '0');
        end if;
        if r.LoadRun = '1' and Kt_Busy = '0' then
            v.LoadRun    := '0';
            v.Events(10) := '1';
        end if;
        Zeroize <= r.Zeroize;

        -------------------------------------------------------------------------------------------
        -- Slot query
        -------------------------------------------------------------------------------------------
        M_Query_Valid <= r.QueryReq;
        M_Query_Slot  <= r.QuerySlot(SlotBits_c - 1 downto 0);
        if unsigned(r.QuerySlot) >= 2 ** SlotBits_c then
            -- Beyond the slot numbers: an invalid slot
            M_Query_Slot <= (others => '1');
        end if;
        if r.QueryReq = '1' and M_Query_Ready = '1' then
            v.QueryReq := '0';
        end if;
        if S_Query_Valid = '1' then
            v.QueryPend := '0';
            v.QValid    := S_Query_KeyValid;
            v.QIvGen    := S_Query_IvGen;
            v.QExh      := S_Query_Exhausted;
            v.QDed      := S_Query_Ded;
            v.QFixed    := S_Query_Fixed;
            v.QCounter  := S_Query_Counter;
            -- A slot beyond the key table reads as erased
            if unsigned(r.QuerySlot) >= NumKeys_g then
                v.QValid   := '0';
                v.QIvGen   := '0';
                v.QExh     := '0';
                v.QDed     := '0';
                v.QFixed   := (others => '0');
                v.QCounter := (others => '0');
            end if;
        end if;

        -------------------------------------------------------------------------------------------
        -- Status of the messages: counters and events
        -------------------------------------------------------------------------------------------
        if Evt_Valid = '1' then
            Code_v := to_integer(unsigned(Evt_Code));
            if Code_v = 0 then
                if Evt_Decrypt = '1' then
                    v.Cnt(1) := incSat(v.Cnt(1));
                else
                    v.Cnt(0) := incSat(v.Cnt(0));
                end if;
            elsif Code_v <= 8 then
                v.Cnt(Code_v + 1)    := incSat(v.Cnt(Code_v + 1));
                v.Events(Code_v - 1) := '1';
            end if;
        end if;
        if EvtSec = '1' then
            v.Events(8) := '1';
        end if;
        if EvtDed = '1' then
            v.Events(9) := '1';
        end if;
        v.Irq := toSl((r.Events and r.IrqEn) /= (r.Events'range => '0'));

        -------------------------------------------------------------------------------------------
        -- Register reads
        -------------------------------------------------------------------------------------------
        Addr_v := to_integer(unsigned(std_logic_vector'(RbAddr(7 downto 2) & "00")));
        Rd_v   := (others => '0');

        case Addr_v is
            when RegId_c =>
                Rd_v := RegMapId_c;
            when RegGenerics_c =>
                Rd_v(GenericsDataBytesHi_c downto GenericsDataBytesLo_c) := std_logic_vector(to_unsigned(DataWidth_g / 8, 5));
                Rd_v(GenericsKeyBitsHi_c downto GenericsKeyBitsLo_c)     := std_logic_vector(to_unsigned(KeyBits_g, 9));
                Rd_v(GenericsNumKeysHi_c downto GenericsNumKeysLo_c)     := std_logic_vector(to_unsigned(NumKeys_g, 9));
                Rd_v(GenericsRelease_c)                                  := toSl(ReleaseBuffer_g);
                Rd_v(GenericsAesUnitsHi_c downto GenericsAesUnitsLo_c)   := std_logic_vector(to_unsigned(AesUnits_g, 4));
            when RegGenerics2_c =>
                Rd_v(Generics2GhashDigitHi_c downto Generics2GhashDigitLo_c) := std_logic_vector(to_unsigned(GhashDigit_g, 8));
                Rd_v(Generics2LenBitsHi_c downto Generics2LenBitsLo_c)       := std_logic_vector(to_unsigned(LenBits_g, 6));
            when RegReleaseBytes_c =>
                if ReleaseBuffer_g then
                    Rd_v := std_logic_vector(to_unsigned(ReleaseBytes_g, 32));
                end if;
            when RegStatus_c =>
                Rd_v(StatusBusy_c) := Kt_Busy or r.LoadReq or r.LoadRun;
            when RegEvents_c =>
                Rd_v(Events_c - 1 downto 0) := r.Events;
            when RegIrqEn_c =>
                Rd_v(Events_c - 1 downto 0) := r.IrqEn;
            when RegIrqStatus_c =>
                Rd_v(IrqStatusIrq_c) := r.Irq;
            when RegSlotQuery_c =>
                Rd_v(7 downto 0) := r.QuerySlot;
            when RegSlotStatus_c =>
                Rd_v(SlotStatusValid_c)     := r.QValid;
                Rd_v(SlotStatusIvGen_c)     := r.QIvGen;
                Rd_v(SlotStatusExhausted_c) := r.QExh;
                Rd_v(SlotStatusDed_c)       := r.QDed;
                Rd_v(SlotStatusPending_c)   := r.QueryPend;
            when RegSlotFixed_c =>
                Rd_v := r.QFixed;
            when RegSlotCountLo_c =>
                Rd_v := r.QCounter(31 downto 0);
            when RegSlotCountHi_c =>
                Rd_v := r.QCounter(63 downto 32);
            when RegEncryptions_c => Rd_v := std_logic_vector(r.Cnt(0));
            when RegDecryptions_c => Rd_v := std_logic_vector(r.Cnt(1));
            when RegErrAuth_c => Rd_v := std_logic_vector(r.Cnt(2));
            when RegErrFormat_c => Rd_v := std_logic_vector(r.Cnt(3));
            when RegErrKey_c => Rd_v := std_logic_vector(r.Cnt(4));
            when RegErrIvMode_c => Rd_v := std_logic_vector(r.Cnt(5));
            when RegErrIvExhausted_c => Rd_v := std_logic_vector(r.Cnt(6));
            when RegErrLength_c => Rd_v := std_logic_vector(r.Cnt(7));
            when RegErrEcc_c => Rd_v := std_logic_vector(r.Cnt(8));
            when RegErrOverflow_c => Rd_v := std_logic_vector(r.Cnt(9));
            when RegEccStatus_c =>
                Rd_v(EccStatusDedHi_c downto EccStatusDedLo_c) := EccDed;
            when RegEccSelect_c =>
                Rd_v(EccSelectChannelHi_c downto EccSelectChannelLo_c) := r.EccSelect;
            when RegEccCount_c =>
                Rd_v(EccCountSecHi_c downto EccCountSecLo_c) := EccSecCnt;
                Rd_v(EccCountDedHi_c downto EccCountDedLo_c) := EccDedCnt;
            when others =>
                null;
        end case;

        if RbRd = '1' then
            v.RdValid := '1';
            v.RdData  := Rd_v;
        end if;

        -- Error injection
        Gcm_ErrInj_Sel   <= r.InjTarget(3 downto 0);
        Kt_ErrInj_Sel    <= r.InjTarget(1 downto 0);
        ErrInj_BitFlip   <= r.InjPat;
        Gcm_ErrInj_Valid <= r.InjGcm;
        Kt_ErrInj_Valid  <= r.InjKt;

        Irq <= r.Irq;

        -- Assign signal
        r_next <= v;
    end process;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Key       <= (others => (others => '0'));
                r.IvFixed   <= (others => '0');
                r.IvCount   <= (others => '0');
                r.LoadSlot  <= (others => '0');
                r.LoadIvGen <= '0';
                r.LoadReq   <= '0';
                r.LoadRun   <= '0';
                r.Zeroize   <= '0';
                r.QuerySlot <= (others => '0');
                r.QueryReq  <= '0';
                r.QueryPend <= '0';
                r.QValid    <= '0';
                r.QIvGen    <= '0';
                r.QExh      <= '0';
                r.QDed      <= '0';
                r.QFixed    <= (others => '0');
                r.QCounter  <= (others => '0');
                r.Cnt       <= (others => (others => '0'));
                r.Events    <= (others => '0');
                r.IrqEn     <= (others => '0');
                r.Irq       <= '0';
                r.EccSelect <= (others => '0');
                r.EccClr    <= '0';
                r.EccRdClr  <= '0';
                r.InjTarget <= (others => '0');
                r.InjPat    <= (others => '0');
                r.InjGcm    <= '0';
                r.InjKt     <= '0';
                r.RdValid   <= '0';
            end if;
        end if;
    end process;

    -- MG-1: AXI4-Lite slave
    i_axi : entity olo.olo_axi_lite_slave
        generic map (
            AxiAddrWidth_g => 8,
            AxiDataWidth_g => 32
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
            Rb_Addr           => RbAddr,
            Rb_Wr             => RbWr,
            Rb_WrData         => RbWrData,
            Rb_Rd             => RbRd,
            Rb_RdData         => r.RdData,
            Rb_RdValid        => r.RdValid
        );

    -- MG-2: EDAC monitor of the 18 channels
    i_ecc : entity olo.olo_ft_ecc_monitor
        generic map (
            Channels_g     => 18,
            CounterWidth_g => 16
        )
        port map (
            Clk        => Clk,
            Rst        => Rst,
            Clr        => r.EccClr,
            In_EccSec  => Ecc_Sec,
            In_EccDed  => Ecc_Ded,
            DedSticky  => EccDed,
            Evt_Sec    => EvtSec,
            Evt_Ded    => EvtDed,
            Rd_Channel => r.EccSelect,
            Rd_Ena     => '1',
            Rd_Clr     => r.EccRdClr,
            Rd_SecCnt  => EccSecCnt,
            Rd_DedCnt  => EccDedCnt,
            Rd_Valid   => open
        );

end architecture;
