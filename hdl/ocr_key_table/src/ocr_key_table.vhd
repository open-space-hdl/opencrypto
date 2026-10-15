---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Key table of OpenCrypto (KT-1 to KT-4): key, hash subkey and IV state of NumKeys_g key slots in
-- three scrubbed FT RAMs. Erases all slots after the reset and on zeroize, loads a slot and computes
-- its hash subkey with the AES engine, resolves the context of every message into a job (key, H, IV)
-- with the checks of the slot and of its IV construction, and generates IVs with the deterministic
-- construction of NIST SP 800-38D 8.2.1. Keys and hash subkeys have no read path.
--
-- Documentation: hdl/ocr_key_table/docs/architecture.md

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

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_key_table is
    generic (
        KeyBits_g     : positive range 128 to 256 := 256;
        NumKeys_g     : positive range 1 to 256   := 4;
        ClkFreqHz_g   : real                      := 100.0e6;
        ScrubPeriod_g : real                      := 0.0
    );
    port (
        -- Control
        Clk               : in    std_logic;
        Rst               : in    std_logic;
        -- Contexts, one per message
        S_Ctx_Valid       : in    std_logic;
        S_Ctx_Ready       : out   std_logic;
        S_Ctx_Decrypt     : in    std_logic;
        S_Ctx_Slot        : in    std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        S_Ctx_IvGen       : in    std_logic;
        S_Ctx_Iv          : in    std_logic_vector(95 downto 0);
        -- Jobs, one per context
        M_Job_Valid       : out   std_logic;
        M_Job_Ready       : in    std_logic;
        M_Job_Decrypt     : out   std_logic;
        M_Job_Key         : out   std_logic_vector(KeyBits_g - 1 downto 0);
        M_Job_H           : out   Block_t;
        M_Job_Iv          : out   std_logic_vector(95 downto 0);
        M_Job_IvOut       : out   std_logic;
        M_Job_Err         : out   Status_t;
        M_Job_Slot        : out   std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        -- Key load: key, IV construction ('1' generated IVs), fixed field and first invocation counter
        S_Load_Valid      : in    std_logic;
        S_Load_Ready      : out   std_logic;
        S_Load_Slot       : in    std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        S_Load_Key        : in    std_logic_vector(KeyBits_g - 1 downto 0);
        S_Load_IvGen      : in    std_logic;
        S_Load_Fixed      : in    std_logic_vector(31 downto 0);
        S_Load_Counter    : in    std_logic_vector(63 downto 0);
        -- Zeroize (one-cycle command); Busy: erasure, zeroize or load in progress
        Zeroize           : in    std_logic;
        Busy              : out   std_logic;
        -- Slot query: never the key or the hash subkey
        S_Query_Valid     : in    std_logic;
        S_Query_Ready     : out   std_logic;
        S_Query_Slot      : in    std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        M_Query_Valid     : out   std_logic;
        M_Query_KeyValid  : out   std_logic;
        M_Query_IvGen     : out   std_logic;
        M_Query_Exhausted : out   std_logic;
        M_Query_Fixed     : out   std_logic_vector(31 downto 0);
        M_Query_Counter   : out   std_logic_vector(63 downto 0);
        M_Query_Ded       : out   std_logic;
        -- Hash subkey requests to the AES engine: H = CIPH_K(0^128)
        M_Aux_Valid       : out   std_logic;
        M_Aux_Ready       : in    std_logic;
        M_Aux_Key         : out   std_logic_vector(KeyBits_g - 1 downto 0);
        S_Aux_Valid       : in    std_logic;
        S_Aux_Ready       : out   std_logic;
        S_Aux_Block       : in    Block_t;
        -- ECC events: reads of the key, H and IV memory (0 to 2), their scrubbers (3 to 5), job FIFO (6)
        Ecc_Sec           : out   std_logic_vector(6 downto 0);
        Ecc_Ded           : out   std_logic_vector(6 downto 0);
        -- Error injection into the next load of a slot: its key (0), H (1) or IV (2) word, or into the next job (3).
        -- The pattern flips the first two parity bits ("01" single error, "11" double error); it is applied
        -- together with the write, so that a write-back of the scrubber does not take it.
        ErrInj_Sel        : in    std_logic_vector(1 downto 0) := (others => '0');
        ErrInj_BitFlip    : in    std_logic_vector(1 downto 0) := (others => '0');
        ErrInj_Valid      : in    std_logic                    := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_key_table is

    constant SlotBits_c : positive := slotBits(NumKeys_g);
    constant Depth_c    : positive := maximum(2, NumKeys_g);
    constant AddrBits_c : positive := log2ceil(Depth_c);
    -- Key word: valid, IV construction, key; H word: valid, H; IV word: fixed field, invocation counter
    constant KeyW_c     : positive                      := KeyBits_g + 2;
    constant HW_c       : positive                      := 129;
    constant IvW_c      : positive                      := 96;
    constant JobW_c     : positive                      := 1 + KeyBits_g + 128 + 96 + 1 + 4 + SlotBits_c;
    constant JobDepth_c : positive                      := 4;
    constant CntMax_c   : std_logic_vector(63 downto 0) := (others => '1');

    type LoadState_t is (LdIdle_s, LdAux_s, LdWait_s);

    type TwoProcess_r is record
        Init      : std_logic;
        InitAddr  : unsigned(AddrBits_c - 1 downto 0);
        ZeroPend  : std_logic;
        LoadState : LoadState_t;
        LoadSlot  : std_logic_vector(SlotBits_c - 1 downto 0);
        LoadKey   : std_logic_vector(KeyBits_g - 1 downto 0);
        -- Read issued in the previous cycle
        RdValid   : std_logic;
        RdQuery   : std_logic;
        RdDec     : std_logic;
        RdSlot    : std_logic_vector(SlotBits_c - 1 downto 0);
        RdIvGen   : std_logic;
        RdIv      : std_logic_vector(95 downto 0);
        RdInRange : std_logic;
        JobCredit : unsigned(2 downto 0);
        -- Query response
        QValid    : std_logic;
        QKeyValid : std_logic;
        QIvGen    : std_logic;
        QExh      : std_logic;
        QFixed    : std_logic_vector(31 downto 0);
        QCounter  : std_logic_vector(63 downto 0);
        QDed      : std_logic;
        -- Pending error injection into a memory
        InjPend   : std_logic;
        InjSel    : std_logic_vector(1 downto 0);
        InjPat    : std_logic_vector(1 downto 0);
    end record;

    signal r, r_next : TwoProcess_r;

    -- Memories
    signal Wr_Addr      : std_logic_vector(AddrBits_c - 1 downto 0);
    signal Rd_Addr      : std_logic_vector(AddrBits_c - 1 downto 0);
    signal Rd_Ena       : std_logic;
    signal Key_WrEna    : std_logic;
    signal Key_WrData   : std_logic_vector(KeyW_c - 1 downto 0);
    signal Key_RdData   : std_logic_vector(KeyW_c - 1 downto 0);
    signal Key_RdValid  : std_logic;
    signal Key_RdSec    : std_logic;
    signal Key_RdDed    : std_logic;
    signal H_WrAddr     : std_logic_vector(AddrBits_c - 1 downto 0);
    signal H_WrEna      : std_logic;
    signal H_WrData     : std_logic_vector(HW_c - 1 downto 0);
    signal H_RdData     : std_logic_vector(HW_c - 1 downto 0);
    signal H_RdSec      : std_logic;
    signal H_RdDed      : std_logic;
    signal Iv_WrAddr    : std_logic_vector(AddrBits_c - 1 downto 0);
    signal Iv_WrEna     : std_logic;
    signal Iv_WrData    : std_logic_vector(IvW_c - 1 downto 0);
    signal Iv_RdData    : std_logic_vector(IvW_c - 1 downto 0);
    signal Iv_RdSec     : std_logic;
    signal Iv_RdDed     : std_logic;
    -- Jobs
    signal Job_InValid  : std_logic;
    signal Job_InData   : std_logic_vector(JobW_c - 1 downto 0);
    signal Job_OutValid : std_logic;
    signal Job_OutData  : std_logic_vector(JobW_c - 1 downto 0);
    signal Job_Sec      : std_logic;
    signal Job_Ded      : std_logic;
    signal Scrub_Sec    : std_logic_vector(2 downto 0);
    signal Scrub_Ded    : std_logic_vector(2 downto 0);
    signal Inj_Valid    : std_logic_vector(2 downto 0);

    -- Codeword-wide injection pattern
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

begin

    assert KeyBits_g = 128 or KeyBits_g = 192 or KeyBits_g = 256
        report "ocr_key_table: KeyBits_g must be 128, 192 or 256"
        severity failure;

    p_comb : process (all) is
        variable v       : TwoProcess_r;
        variable Ded_v   : std_logic;
        variable Err_v   : Status_t;
        variable Iv_v    : std_logic_vector(95 downto 0);
        variable Key_v   : std_logic_vector(KeyBits_g - 1 downto 0);
        variable H_v     : Block_t;
        variable IvOut_v : std_logic;
        variable WrBk_v  : boolean;
        variable Issue_v : boolean;
        variable Slot_v  : unsigned(SlotBits_c - 1 downto 0);
    begin
        -- hold variables stable
        v := r;
        -- The query response is valid for one cycle; a response of the read of the previous cycle follows directly
        v.QValid := '0';

        -- Default: memories idle
        Wr_Addr     <= std_logic_vector(resize(unsigned(S_Load_Slot), AddrBits_c));
        Key_WrEna   <= '0';
        Key_WrData  <= '1' & S_Load_IvGen & S_Load_Key;
        H_WrAddr    <= std_logic_vector(resize(unsigned(S_Load_Slot), AddrBits_c));
        H_WrEna     <= '0';
        H_WrData    <= (others => '0');
        Iv_WrAddr   <= std_logic_vector(resize(unsigned(S_Load_Slot), AddrBits_c));
        Iv_WrEna    <= '0';
        Iv_WrData   <= S_Load_Fixed & S_Load_Counter;
        Rd_Ena      <= '0';
        Rd_Addr     <= std_logic_vector(resize(unsigned(S_Ctx_Slot), AddrBits_c));
        Job_InValid <= '0';
        Inj_Valid   <= (others => '0');
        if ErrInj_Valid = '1' and ErrInj_Sel /= "11" then
            v.InjPend := '1';
            v.InjSel  := ErrInj_Sel;
            v.InjPat  := ErrInj_BitFlip;
        end if;

        -------------------------------------------------------------------------------------------
        -- KT-3, KT-4: context of the read of the previous cycle
        -------------------------------------------------------------------------------------------
        WrBk_v  := false;
        Ded_v   := Key_RdDed or H_RdDed or Iv_RdDed;
        Err_v   := StsOk_c;
        Iv_v    := r.RdIv;
        Key_v   := Key_RdData(KeyBits_g - 1 downto 0);
        H_v     := H_RdData(127 downto 0);
        IvOut_v := '0';
        if r.RdInRange = '0' or Key_RdData(KeyBits_g + 1) = '0' or H_RdData(128) = '0' then
            -- Slot out of range or not loaded (its hash subkey not yet computed)
            Err_v := StsKey_c;
        elsif r.RdIvGen = '1' then
            -- GCM 8.2: generated IVs only for encryptions with a slot of the deterministic construction
            if r.RdDec = '1' or Key_RdData(KeyBits_g) = '0' then
                Err_v := StsIvMode_c;
            elsif Iv_RdData(63 downto 0) = CntMax_c then
                -- GCM 8.3: the invocation counter is exhausted
                Err_v := StsIvExhausted_c;
            else
                -- GCM 8.2.1: IV = fixed field || invocation field
                Iv_v    := Iv_RdData;
                IvOut_v := '1';
                WrBk_v  := true;
            end if;
        elsif r.RdDec = '0' and Key_RdData(KeyBits_g) = '1' then
            -- GCM 8.2: a slot of the deterministic construction encrypts only with generated IVs
            Err_v := StsIvMode_c;
        end if;
        if Ded_v = '1' then
            Err_v  := StsEcc_c;
            WrBk_v := false;
        end if;
        if Err_v /= StsOk_c then
            Key_v   := (others => '0');
            H_v     := (others => '0');
            IvOut_v := '0';
        end if;
        Job_InData <= r.RdDec & Key_v & H_v & Iv_v & IvOut_v & Err_v & r.RdSlot;

        if r.RdValid = '1' then
            if r.RdQuery = '1' then
                v.QValid    := '1';
                v.QKeyValid := Key_RdData(KeyBits_g + 1) and H_RdData(128) and r.RdInRange;
                v.QIvGen    := Key_RdData(KeyBits_g);
                v.QFixed    := Iv_RdData(95 downto 64);
                v.QCounter  := Iv_RdData(63 downto 0);
                v.QDed      := Ded_v;
                if Iv_RdData(63 downto 0) = CntMax_c then
                    v.QExh := '1';
                else
                    v.QExh := '0';
                end if;
            else
                Job_InValid <= '1';
                if WrBk_v then
                    -- The next IV of the slot: invocation counter + 1
                    Iv_WrEna  <= '1';
                    Iv_WrAddr <= std_logic_vector(resize(unsigned(r.RdSlot), AddrBits_c));
                    Iv_WrData <= Iv_RdData(95 downto 64) & std_logic_vector(unsigned(Iv_RdData(63 downto 0)) + 1);
                end if;
            end if;
        end if;
        if not (r.RdValid = '1' and r.RdQuery = '0') then
            WrBk_v := false;
        end if;
        v.RdValid := '0';

        -- Job credits: taken by a context read, returned when its job leaves the job FIFO
        if Job_OutValid = '1' and M_Job_Ready = '1' then
            v.JobCredit := v.JobCredit + 1;
        end if;

        -------------------------------------------------------------------------------------------
        -- Reads: a query, else a context. No read in the cycle of a counter update, so that a context of the same
        -- slot reads the updated counter.
        -------------------------------------------------------------------------------------------
        S_Ctx_Ready   <= '0';
        S_Query_Ready <= '0';
        Issue_v       := r.Init = '0' and r.ZeroPend = '0' and not WrBk_v;
        -- A slot out of range reads address 0; its result is discarded
        if Issue_v and S_Query_Valid = '1' and r.QValid = '0' then
            S_Query_Ready <= '1';
            Rd_Ena        <= '1';
            Slot_v        := unsigned(S_Query_Slot);
            if Slot_v < NumKeys_g then
                Rd_Addr     <= std_logic_vector(resize(Slot_v, AddrBits_c));
                v.RdInRange := '1';
            else
                Rd_Addr     <= (others => '0');
                v.RdInRange := '0';
            end if;
            v.RdValid := '1';
            v.RdQuery := '1';
        elsif Issue_v and S_Ctx_Valid = '1' and r.JobCredit /= 0 then
            S_Ctx_Ready <= '1';
            Rd_Ena      <= '1';
            Slot_v      := unsigned(S_Ctx_Slot);
            if Slot_v < NumKeys_g then
                Rd_Addr     <= std_logic_vector(resize(Slot_v, AddrBits_c));
                v.RdInRange := '1';
            else
                Rd_Addr     <= (others => '0');
                v.RdInRange := '0';
            end if;
            v.RdValid   := '1';
            v.RdQuery   := '0';
            v.RdDec     := S_Ctx_Decrypt;
            v.RdSlot    := S_Ctx_Slot;
            v.RdIvGen   := S_Ctx_IvGen;
            v.RdIv      := S_Ctx_Iv;
            v.JobCredit := v.JobCredit - 1;
        end if;

        -------------------------------------------------------------------------------------------
        -- KT-2: key load and hash subkey
        -------------------------------------------------------------------------------------------
        S_Load_Ready <= '0';
        M_Aux_Valid  <= '0';
        S_Aux_Ready  <= '0';

        case r.LoadState is
            when LdIdle_s =>
                -- Key, IV construction and IV state; the slot is not valid before its hash subkey is written
                if S_Load_Valid = '1' and r.Init = '0' and r.ZeroPend = '0' and not WrBk_v then
                    S_Load_Ready <= '1';
                    if unsigned(S_Load_Slot) < NumKeys_g then
                        Key_WrEna <= '1';
                        H_WrEna   <= '1';
                        Iv_WrEna  <= '1';
                        if r.InjPend = '1' and r.InjSel /= "01" then
                            Inj_Valid(to_integer(unsigned(r.InjSel))) <= '1';
                            v.InjPend                                 := '0';
                        end if;
                        v.LoadState := LdAux_s;
                        v.LoadSlot  := S_Load_Slot;
                        v.LoadKey   := S_Load_Key;
                    end if;
                end if;
            when LdAux_s =>
                M_Aux_Valid <= '1';
                if M_Aux_Ready = '1' then
                    v.LoadState := LdWait_s;
                end if;
            when LdWait_s =>
                -- GCM 7.1 step 1: H = CIPH_K(0^128)
                S_Aux_Ready <= '1';
                if S_Aux_Valid = '1' then
                    H_WrEna  <= '1';
                    H_WrAddr <= std_logic_vector(resize(unsigned(r.LoadSlot), AddrBits_c));
                    H_WrData <= '1' & S_Aux_Block;
                    if r.InjPend = '1' and r.InjSel = "01" then
                        Inj_Valid(1) <= '1';
                        v.InjPend    := '0';
                    end if;
                    v.LoadState := LdIdle_s;
                    v.LoadKey   := (others => '0');
                end if;
            -- coverage off
            when others =>
                -- Recovery of an illegal state
                v.LoadState := LdIdle_s;
            -- coverage on
        end case;

        M_Aux_Key <= r.LoadKey;

        -------------------------------------------------------------------------------------------
        -- KT-1: erasure after the reset and on zeroize, once no load and no read is in progress
        -------------------------------------------------------------------------------------------
        if Zeroize = '1' then
            v.ZeroPend := '1';
        end if;
        if r.Init = '0' and r.ZeroPend = '1' and r.LoadState = LdIdle_s and r.RdValid = '0' then
            v.Init     := '1';
            v.InitAddr := (others => '0');
            v.ZeroPend := Zeroize;
        end if;
        if r.Init = '1' then
            Wr_Addr    <= std_logic_vector(r.InitAddr);
            H_WrAddr   <= std_logic_vector(r.InitAddr);
            Iv_WrAddr  <= std_logic_vector(r.InitAddr);
            Key_WrEna  <= '1';
            H_WrEna    <= '1';
            Iv_WrEna   <= '1';
            Key_WrData <= (others => '0');
            H_WrData   <= (others => '0');
            Iv_WrData  <= (others => '0');
            if r.InitAddr = Depth_c - 1 then
                v.Init := '0';
            else
                v.InitAddr := r.InitAddr + 1;
            end if;
        end if;
        if r.LoadState /= LdIdle_s then
            Busy <= '1';
        else
            Busy <= r.Init or r.ZeroPend;
        end if;

        -- Query response
        M_Query_Valid     <= r.QValid;
        M_Query_KeyValid  <= r.QKeyValid;
        M_Query_IvGen     <= r.QIvGen;
        M_Query_Exhausted <= r.QExh;
        M_Query_Fixed     <= r.QFixed;
        M_Query_Counter   <= r.QCounter;
        M_Query_Ded       <= r.QDed;

        -- assign signal
        r_next <= v;
    end process;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                -- All slots are erased after the reset
                r.Init      <= '1';
                r.InitAddr  <= (others => '0');
                r.ZeroPend  <= '0';
                r.LoadState <= LdIdle_s;
                r.LoadKey   <= (others => '0');
                r.RdValid   <= '0';
                r.RdInRange <= '0';
                r.JobCredit <= to_unsigned(JobDepth_c, 3);
                r.QValid    <= '0';
                r.InjPend   <= '0';
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- KT-1: key, hash subkey and IV memories
    -----------------------------------------------------------------------------------------------
    i_key_ram : entity olo.olo_ft_ram_sdp_scrub
        generic map (
            Depth_g       => Depth_c,
            Width_g       => KeyW_c,
            ScrubClkHz_g  => ClkFreqHz_g,
            ScrubPeriod_g => ScrubPeriod_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Wr_Addr        => Wr_Addr,
            Wr_Ena         => Key_WrEna,
            Wr_Data        => Key_WrData,
            Rd_Addr        => Rd_Addr,
            Rd_Ena         => Rd_Ena,
            Rd_Data        => Key_RdData,
            Rd_Valid       => Key_RdValid,
            Rd_EccSec      => Key_RdSec,
            Rd_EccDed      => Key_RdDed,
            ErrInj_BitFlip => inj(KeyW_c, r.InjSel, 0, r.InjPat),
            ErrInj_Valid   => Inj_Valid(0),
            Scrub_EccSec   => Scrub_Sec(0),
            Scrub_EccDed   => Scrub_Ded(0)
        );

    i_h_ram : entity olo.olo_ft_ram_sdp_scrub
        generic map (
            Depth_g       => Depth_c,
            Width_g       => HW_c,
            ScrubClkHz_g  => ClkFreqHz_g,
            ScrubPeriod_g => ScrubPeriod_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Wr_Addr        => H_WrAddr,
            Wr_Ena         => H_WrEna,
            Wr_Data        => H_WrData,
            Rd_Addr        => Rd_Addr,
            Rd_Ena         => Rd_Ena,
            Rd_Data        => H_RdData,
            Rd_EccSec      => H_RdSec,
            Rd_EccDed      => H_RdDed,
            ErrInj_BitFlip => inj(HW_c, r.InjSel, 1, r.InjPat),
            ErrInj_Valid   => Inj_Valid(1),
            Scrub_EccSec   => Scrub_Sec(1),
            Scrub_EccDed   => Scrub_Ded(1)
        );

    i_iv_ram : entity olo.olo_ft_ram_sdp_scrub
        generic map (
            Depth_g       => Depth_c,
            Width_g       => IvW_c,
            ScrubClkHz_g  => ClkFreqHz_g,
            ScrubPeriod_g => ScrubPeriod_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Wr_Addr        => Iv_WrAddr,
            Wr_Ena         => Iv_WrEna,
            Wr_Data        => Iv_WrData,
            Rd_Addr        => Rd_Addr,
            Rd_Ena         => Rd_Ena,
            Rd_Data        => Iv_RdData,
            Rd_EccSec      => Iv_RdSec,
            Rd_EccDed      => Iv_RdDed,
            ErrInj_BitFlip => inj(IvW_c, r.InjSel, 2, r.InjPat),
            ErrInj_Valid   => Inj_Valid(2),
            Scrub_EccSec   => Scrub_Sec(2),
            Scrub_EccDed   => Scrub_Ded(2)
        );

    -----------------------------------------------------------------------------------------------
    -- Jobs: the credits guarantee room for every job of a read
    -----------------------------------------------------------------------------------------------
    i_job_fifo : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => JobW_c,
            Depth_g => JobDepth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => Job_InData,
            In_Valid          => Job_InValid,
            In_Ready          => open,
            Out_Data          => Job_OutData,
            Out_Valid         => Job_OutValid,
            Out_Ready         => M_Job_Ready,
            Out_EccSec        => Job_Sec,
            Out_EccDed        => Job_Ded,
            In_ErrInj_BitFlip => inj(JobW_c, ErrInj_Sel, 3, ErrInj_BitFlip),
            In_ErrInj_Valid   => ErrInj_Valid
        );

    M_Job_Valid   <= Job_OutValid;
    M_Job_Decrypt <= Job_OutData(JobW_c - 1);
    -- A job with an uncorrectable error is rejected and carries no key material
    M_Job_Key   <= (others => '0') when Job_Ded = '1' else Job_OutData(JobW_c - 2 downto JobW_c - 1 - KeyBits_g);
    M_Job_H     <= (others => '0') when Job_Ded = '1' else
                   Job_OutData(JobW_c - 2 - KeyBits_g downto JobW_c - 129 - KeyBits_g);
    M_Job_Iv    <= Job_OutData(96 + 1 + 4 + SlotBits_c - 1 downto 1 + 4 + SlotBits_c);
    M_Job_IvOut <= Job_OutData(4 + SlotBits_c) and not Job_Ded;
    M_Job_Err   <= StsEcc_c when Job_Ded = '1' else Job_OutData(4 + SlotBits_c - 1 downto SlotBits_c);
    M_Job_Slot  <= Job_OutData(SlotBits_c - 1 downto 0);

    Ecc_Sec <= (Job_Sec and Job_OutValid and M_Job_Ready) & Scrub_Sec &
               (Iv_RdSec and Key_RdValid) & (H_RdSec and Key_RdValid) & (Key_RdSec and Key_RdValid);
    Ecc_Ded <= (Job_Ded and Job_OutValid and M_Job_Ready) & Scrub_Ded &
               (Iv_RdDed and Key_RdValid) & (H_RdDed and Key_RdValid) & (Key_RdDed and Key_RdValid);

end architecture;
