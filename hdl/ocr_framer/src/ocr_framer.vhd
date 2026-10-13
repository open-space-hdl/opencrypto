---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Framer of OpenCrypto (FR-1): cuts a stream of packets of any length into chunks of ChunkBytes_g
-- bytes and hands every chunk to ocr_core as one message with a 4-byte AAD section that tells the
-- position of the chunk in its packet, together with one context for an encryption with a generated IV.
--
-- Documentation: hdl/ocr_framer/docs/architecture.md

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
entity ocr_framer is
    generic (
        DataWidth_g    : positive range 16 to 128 := 32;   -- 16, 32, 64 or 128
        NumKeys_g      : positive range 1 to 256  := 4;    -- as ocr_core: width of the slot
        ChunkBytes_g   : positive                 := 4096; -- a multiple of 16
        BufferChunks_g : positive range 2 to 64   := 2;    -- chunk buffer size in chunks
        RamStyle_g     : string                   := "auto"
    );
    port (
        -- Control
        Clk            : in    std_logic;
        Rst            : in    std_logic;
        -- Key slot of the contexts (static configuration)
        Cfg_Slot       : in    std_logic_vector(slotBits(NumKeys_g) - 1 downto 0) := (others => '0');
        -- Input packets: all bytes of a beat valid except in the last beat, contiguous from lane 0
        S_In_Valid     : in    std_logic;
        S_In_Ready     : out   std_logic;
        S_In_Data      : in    std_logic_vector(DataWidth_g - 1 downto 0);
        S_In_Keep      : in    std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        S_In_Last      : in    std_logic;
        -- Contexts to ocr_core S_Ctx: one per chunk
        M_Ctx_Valid    : out   std_logic;
        M_Ctx_Ready    : in    std_logic;
        M_Ctx_Decrypt  : out   std_logic;
        M_Ctx_Slot     : out   std_logic_vector(slotBits(NumKeys_g) - 1 downto 0);
        M_Ctx_IvGen    : out   std_logic;
        M_Ctx_Iv       : out   std_logic_vector(95 downto 0);
        -- Messages to ocr_core S_In: AAD section with the chunk position, then the chunk as DATA section
        M_Out_Valid    : out   std_logic;
        M_Out_Ready    : in    std_logic;
        M_Out_Data     : out   std_logic_vector(DataWidth_g - 1 downto 0);
        M_Out_Keep     : out   std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        M_Out_Last     : out   std_logic;
        M_Out_User     : out   std_logic_vector(1 downto 0);
        -- Memory errors (pulses per buffer: 0 chunk buffer, 1 position FIFO): corrected single error, double error
        Ecc_Sec        : out   std_logic_vector(1 downto 0);
        Ecc_Ded        : out   std_logic_vector(1 downto 0);
        -- Error injection into the next word written to buffer ErrInj_Sel ("01" single, "11" double error)
        ErrInj_Sel     : in    std_logic                                          := '0';
        ErrInj_BitFlip : in    std_logic_vector(1 downto 0)                       := (others => '0');
        ErrInj_Valid   : in    std_logic                                          := '0'
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_framer is

    constant Bytes_c       : positive := DataWidth_g / 8;
    constant ChunkBeats_c  : positive := ChunkBytes_g / Bytes_c;
    constant BufDepth_c    : positive := 2 ** log2ceil(BufferChunks_g * ChunkBeats_c);
    constant MaxPackets_c  : positive := 4 * BufferChunks_g;
    constant PosDepth_c    : positive := 2 ** log2ceil(MaxPackets_c);
    constant BufWidth_c    : positive := DataWidth_g + Bytes_c;
    constant AadBeats_c    : positive := (4 + Bytes_c - 1) / Bytes_c;
    -- Contexts handed over ahead of their chunks
    constant MaxCtxAhead_c : positive := MaxPackets_c + 2;

    -- Position of a chunk in its packet (CCSDS sequence flag encoding)
    constant PosMiddle_c : std_logic_vector(1 downto 0) := "00";
    constant PosFirst_c  : std_logic_vector(1 downto 0) := "01";
    constant PosLast_c   : std_logic_vector(1 downto 0) := "10";
    constant PosSingle_c : std_logic_vector(1 downto 0) := "11";

    type OutFsm_t is (Idle_s, Aad_s, Data_s);

    type TwoProcess_r is record
        -- Write side
        FirstNext : std_logic;  -- the next chunk is the first one of a packet
        ChunkNew  : std_logic;  -- the next beat starts a chunk
        CtxAhead  : natural range 0 to MaxCtxAhead_c;
        -- Read side
        OutFsm    : OutFsm_t;
        Pos       : std_logic_vector(1 downto 0);
        PosDed    : std_logic;
        AadIdx    : natural range 0 to AadBeats_c - 1;
    end record;

    signal r, r_next : TwoProcess_r;

    -- Chunker to the chunk buffer
    signal Chk_Valid    : std_logic;
    signal Chk_Ready    : std_logic;
    signal Chk_Data     : std_logic_vector(DataWidth_g - 1 downto 0);
    signal Chk_Keep     : std_logic_vector(Bytes_c - 1 downto 0);
    signal Chk_Last     : std_logic;
    signal Chk_InLast   : std_logic;
    -- Chunk buffer
    signal Buf_InValid  : std_logic;
    signal Buf_InReady  : std_logic;
    signal Buf_InData   : std_logic_vector(BufWidth_c - 1 downto 0);
    signal Buf_OutValid : std_logic;
    signal Buf_OutReady : std_logic;
    signal Buf_OutData  : std_logic_vector(BufWidth_c - 1 downto 0);
    signal Buf_OutLast  : std_logic;
    signal Buf_Sec      : std_logic;
    signal Buf_Ded      : std_logic;
    -- Position FIFO
    signal Pos_InValid  : std_logic;
    signal Pos_InReady  : std_logic;
    signal Pos_InData   : std_logic_vector(1 downto 0);
    signal Pos_OutValid : std_logic;
    signal Pos_OutReady : std_logic;
    signal Pos_OutData  : std_logic_vector(1 downto 0);
    signal Pos_Sec      : std_logic;
    signal Pos_Ded      : std_logic;
    -- Output stage
    signal Ou_Valid     : std_logic;
    signal Ou_Ready     : std_logic;
    signal Ou_Data      : std_logic_vector(DataWidth_g + Bytes_c + 2 downto 0);
    signal Pl_Data      : std_logic_vector(DataWidth_g + Bytes_c + 2 downto 0);

    -- Codeword-wide injection pattern of a buffer
    function inj (
        width : positive;
        sel   : std_logic;
        idx   : std_logic;
        pat   : std_logic_vector) return std_logic_vector is
        variable R_v : std_logic_vector(eccCodewordWidth(width) - 1 downto 0) := (others => '0');
    begin
        if sel = idx then
            R_v(1 downto 0) := pat;
        end if;
        return R_v;
    end function;

begin

    -----------------------------------------------------------------------------------------------
    -- Assertions
    -----------------------------------------------------------------------------------------------
    assert DataWidth_g = 16 or DataWidth_g = 32 or DataWidth_g = 64 or DataWidth_g = 128
        report "ocr_framer: DataWidth_g must be 16, 32, 64 or 128"
        severity failure;
    assert ChunkBytes_g mod 16 = 0
        report "ocr_framer: ChunkBytes_g must be a multiple of 16"
        severity failure;

    -----------------------------------------------------------------------------------------------
    -- Chunker
    -----------------------------------------------------------------------------------------------
    i_chunker : entity olo.olo_base_chunker
        generic map (
            Width_g      => DataWidth_g,
            ChunkBeats_g => ChunkBeats_c
        )
        port map (
            Clk        => Clk,
            Rst        => Rst,
            In_Valid   => S_In_Valid,
            In_Ready   => S_In_Ready,
            In_Data    => S_In_Data,
            In_Be      => S_In_Keep,
            In_Last    => S_In_Last,
            Out_Valid  => Chk_Valid,
            Out_Ready  => Chk_Ready,
            Out_Data   => Chk_Data,
            Out_Be     => Chk_Keep,
            Out_Last   => Chk_Last,
            Out_InLast => Chk_InLast
        );

    -----------------------------------------------------------------------------------------------
    -- Combinatorial Process
    -----------------------------------------------------------------------------------------------
    p_comb : process (all) is
        variable v       : TwoProcess_r;
        variable CtxOk_v : boolean;
        variable WrOk_v  : boolean;
        variable Wr_v    : boolean;
        variable Next_v  : boolean;
        variable AadD_v  : std_logic_vector(DataWidth_g - 1 downto 0);
        variable AadK_v  : std_logic_vector(Bytes_c - 1 downto 0);
        variable Byte_v  : natural;
        variable User_v  : std_logic_vector(1 downto 0);
    begin
        -- hold variables stable
        v := r;

        -- *** Write side: a beat goes into the chunk buffer, the position of a complete chunk into the position FIFO in
        -- the same cycle as its last beat. A chunk starts only when its context can be counted.
        CtxOk_v     := r.ChunkNew = '0' or r.CtxAhead < MaxCtxAhead_c;
        WrOk_v      := Buf_InReady = '1' and Pos_InReady = '1' and CtxOk_v;
        Wr_v        := WrOk_v and Chk_Valid = '1';
        Chk_Ready   <= '0';
        Buf_InValid <= '0';
        Pos_InValid <= '0';
        if WrOk_v then
            Chk_Ready <= '1';
        end if;
        if Chk_Valid = '1' and Pos_InReady = '1' and CtxOk_v then
            Buf_InValid <= '1';
        end if;
        if Chk_Valid = '1' and Chk_Last = '1' and Buf_InReady = '1' and CtxOk_v then
            Pos_InValid <= '1';
        end if;
        -- Position: first after the end of a packet, last at the end of a packet
        if r.FirstNext = '1' and Chk_InLast = '1' then
            Pos_InData <= PosSingle_c;
        elsif r.FirstNext = '1' then
            Pos_InData <= PosFirst_c;
        elsif Chk_InLast = '1' then
            Pos_InData <= PosLast_c;
        else
            Pos_InData <= PosMiddle_c;
        end if;
        if Wr_v then
            v.ChunkNew := Chk_Last;
            if Chk_Last = '1' then
                v.FirstNext := Chk_InLast;
            end if;
        end if;

        -- *** Contexts: one per chunk, handed over when the chunk starts
        M_Ctx_Valid <= '0';
        if r.CtxAhead /= 0 then
            M_Ctx_Valid <= '1';
            if M_Ctx_Ready = '1' then
                v.CtxAhead := v.CtxAhead - 1;
            end if;
        end if;
        if Wr_v and r.ChunkNew = '1' then
            v.CtxAhead := v.CtxAhead + 1;
        end if;

        -- *** Read side: the AAD section with the position, then the chunk from the buffer
        -- AAD: position in bits 7:6 of byte 0, bytes 1 to 3 zero
        AadD_v := (others => '0');
        AadK_v := (others => '0');

        for i in 0 to Bytes_c - 1 loop
            Byte_v := r.AadIdx * Bytes_c + i;
            if Byte_v < 4 then
                AadK_v(i) := '1';
                if Byte_v = 0 then
                    AadD_v(8 * i + 7 downto 8 * i + 6) := r.Pos;
                end if;
            end if;
        end loop;

        Pos_OutReady <= '0';
        Buf_OutReady <= '0';
        Ou_Valid     <= '0';
        Ou_Data      <= (others => '0');
        Next_v       := false;

        case r.OutFsm is
            when Idle_s =>
                Next_v := true;

            when Aad_s =>
                -- A double error in the position FIFO: the IV section code fails the message in the core (FORMAT)
                if r.PosDed = '1' then
                    User_v := SecIv_c;
                else
                    User_v := SecAad_c;
                end if;
                Ou_Valid <= '1';
                Ou_Data  <= User_v & '0' & AadK_v & AadD_v;
                if Ou_Ready = '1' then
                    if r.AadIdx = AadBeats_c - 1 then
                        v.OutFsm := Data_s;
                        v.AadIdx := 0;
                    else
                        v.AadIdx := r.AadIdx + 1;
                    end if;
                end if;

            when Data_s =>
                -- A double error in a word of the chunk: the IV section code fails the message in the core (FORMAT)
                if Buf_Ded = '1' then
                    User_v := SecIv_c;
                else
                    User_v := SecData_c;
                end if;
                Ou_Valid     <= Buf_OutValid;
                Buf_OutReady <= Ou_Ready;
                Ou_Data      <= User_v & Buf_OutLast & Buf_OutData;
                if Buf_OutValid = '1' and Ou_Ready = '1' and Buf_OutLast = '1' then
                    Next_v   := true;
                    v.OutFsm := Idle_s;
                end if;

            -- coverage off
            when others =>
                -- Recovery of an illegal state
                v.OutFsm := Idle_s;
            -- coverage on
        end case;

        -- Next chunk: its position is written together with its last beat, so the chunk is complete in the buffer
        if Next_v and Pos_OutValid = '1' then
            Pos_OutReady <= '1';
            v.Pos        := Pos_OutData;
            v.PosDed     := Pos_Ded;
            v.AadIdx     := 0;
            v.OutFsm     := Aad_s;
        end if;

        -- *** Outputs
        M_Ctx_Decrypt <= '0';
        M_Ctx_Slot    <= Cfg_Slot;
        M_Ctx_IvGen   <= '1';
        M_Ctx_Iv      <= (others => '0');

        -- assign signal
        r_next <= v;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Sequential Process
    -----------------------------------------------------------------------------------------------
    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.FirstNext <= '1';
                r.ChunkNew  <= '1';
                r.CtxAhead  <= 0;
                r.OutFsm    <= Idle_s;
            end if;
        end if;
    end process;

    -----------------------------------------------------------------------------------------------
    -- Chunk buffer: store and forward of complete chunks
    -----------------------------------------------------------------------------------------------
    Buf_InData <= Chk_Keep & Chk_Data;

    i_buffer : entity olo.olo_ft_fifo_packet
        generic map (
            Width_g      => BufWidth_c,
            Depth_g      => BufDepth_c,
            FeatureSet_g => "DROP_SKIP_ONLY",
            RamStyle_g   => RamStyle_g,
            MaxPackets_g => MaxPackets_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Valid          => Buf_InValid,
            In_Ready          => Buf_InReady,
            In_Data           => Buf_InData,
            In_Last           => Chk_Last,
            Out_Valid         => Buf_OutValid,
            Out_Ready         => Buf_OutReady,
            Out_Data          => Buf_OutData,
            Out_Last          => Buf_OutLast,
            Out_EccSec        => Buf_Sec,
            Out_EccDed        => Buf_Ded,
            In_ErrInj_BitFlip => inj(BufWidth_c, ErrInj_Sel, '0', ErrInj_BitFlip),
            In_ErrInj_Valid   => ErrInj_Valid
        );

    -----------------------------------------------------------------------------------------------
    -- Position FIFO: one entry per complete chunk
    -----------------------------------------------------------------------------------------------
    i_position : entity olo.olo_ft_fifo_sync
        generic map (
            Width_g => 2,
            Depth_g => PosDepth_c
        )
        port map (
            Clk               => Clk,
            Rst               => Rst,
            In_Data           => Pos_InData,
            In_Valid          => Pos_InValid,
            In_Ready          => Pos_InReady,
            Out_Data          => Pos_OutData,
            Out_Valid         => Pos_OutValid,
            Out_Ready         => Pos_OutReady,
            Out_EccSec        => Pos_Sec,
            Out_EccDed        => Pos_Ded,
            In_ErrInj_BitFlip => inj(2, ErrInj_Sel, '1', ErrInj_BitFlip),
            In_ErrInj_Valid   => ErrInj_Valid
        );

    -----------------------------------------------------------------------------------------------
    -- Output register
    -----------------------------------------------------------------------------------------------
    i_out_stage : entity olo.olo_base_pl_stage
        generic map (
            Width_g => DataWidth_g + Bytes_c + 3
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Valid  => Ou_Valid,
            In_Ready  => Ou_Ready,
            In_Data   => Ou_Data,
            Out_Valid => M_Out_Valid,
            Out_Ready => M_Out_Ready,
            Out_Data  => Pl_Data
        );

    M_Out_Data <= Pl_Data(DataWidth_g - 1 downto 0);
    M_Out_Keep <= Pl_Data(DataWidth_g + Bytes_c - 1 downto DataWidth_g);
    M_Out_Last <= Pl_Data(DataWidth_g + Bytes_c);
    M_Out_User <= Pl_Data(DataWidth_g + Bytes_c + 2 downto DataWidth_g + Bytes_c + 1);

    -- ECC events: once per word read
    Ecc_Sec(0) <= Buf_Sec and Buf_OutValid and Buf_OutReady;
    Ecc_Ded(0) <= Buf_Ded and Buf_OutValid and Buf_OutReady;
    Ecc_Sec(1) <= Pos_Sec and Pos_OutValid and Pos_OutReady;
    Ecc_Ded(1) <= Pos_Ded and Pos_OutValid and Pos_OutReady;

end architecture;
