---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Internal formats of the GCM data path: the entries of the FIFOs between the input parser, the
-- combiner, the tag stage and the output assembly, with functions that pack them into vectors for
-- the FT FIFOs and unpack them. Records have the widths of the widest configuration (128-bit beats,
-- 32-bit byte counts, 8-bit slots); synthesis removes the unused bits.
--
-- Documentation: hdl/ocr_gcm/docs/architecture.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.ocr_pkg.all;

---------------------------------------------------------------------------------------------------
-- Package Header
---------------------------------------------------------------------------------------------------
package ocr_gcm_pkg is

    constant MaxSlotBits_c : positive := 8;

    -- FT buffers of the GCM data path: index of their ECC events and of their error injection
    constant GcmEccDat_c     : natural  := 0;  -- data FIFO
    constant GcmEccKs_c      : natural  := 1;  -- keystream FIFO
    constant GcmEccJ0_c      : natural  := 2;  -- J0 FIFO
    constant GcmEccHash_c    : natural  := 3;  -- hash FIFO (combiner to GHASH)
    constant GcmEccOut_c     : natural  := 4;  -- output FIFO (combiner to output assembly)
    constant GcmEccH_c       : natural  := 5;  -- hash subkey FIFO
    constant GcmEccDesc_c    : natural  := 6;  -- descriptor FIFO
    constant GcmEccSum_c     : natural  := 7;  -- summary FIFO
    constant GcmEccRes_c     : natural  := 8;  -- result FIFO
    constant GcmEccSts_c     : natural  := 9;  -- status FIFO
    constant GcmEccRel_c     : natural  := 10; -- release buffer
    constant GcmEccBuffers_c : positive := 11;

    -- Entry of the data FIFO (input parser to combiner): one beat with its flags
    type DatEntry_t is record
        Data     : std_logic_vector(127 downto 0);
        Keep     : std_logic_vector(15 downto 0);
        Sec      : Section_t;
        K        : unsigned(2 downto 0); -- beat of a DATA beat within its block
        KsPop    : std_logic;            -- the keystream block is used up after this beat
        SecLast  : std_logic;            -- last beat of its section
        BodyLast : std_logic;            -- last AAD or DATA beat of the message (end of the output body)
        MsgLast  : std_logic;            -- last entry of the message
        NoBody   : std_logic;            -- first TAG beat of a message without AAD and DATA beats
        FmtErr   : std_logic;            -- format error of the message
        Rej      : std_logic;            -- marker of a message that its context rejected
        Dec      : std_logic;            -- message is a decryption
    end record;

    function datWidth (dataWidth : positive) return positive;
    function datPack (
        e         : DatEntry_t;
        dataWidth : positive) return std_logic_vector;
    function datUnpack (
        v         : std_logic_vector;
        dataWidth : positive) return DatEntry_t;

    -- Entry of the output FIFO (combiner to output assembly) and of the hash FIFO (combiner to GHASH)
    type BeatEntry_t is record
        Data : std_logic_vector(127 downto 0);
        Keep : std_logic_vector(15 downto 0);
        Sec  : Section_t; -- hash FIFO: SecAad_c or SecData_c (ciphertext)
        SecL : std_logic; -- last beat of the section
        Last : std_logic; -- last beat of the body of the message
    end record;

    function beatWidth (dataWidth : positive) return positive;
    function beatPack (
        e         : BeatEntry_t;
        dataWidth : positive) return std_logic_vector;
    function beatUnpack (
        v         : std_logic_vector;
        dataWidth : positive) return BeatEntry_t;

    -- Summary of a message (combiner to tag stage)
    type Summary_t is record
        Dec    : std_logic;
        Rej    : std_logic;
        FmtErr : std_logic;
        EccErr : std_logic;
        RxTag  : Block_t;
    end record;

    constant SummaryWidth_c : positive := 132;
    function sumPack (e : Summary_t) return std_logic_vector;
    function sumUnpack (v : std_logic_vector) return Summary_t;

    -- Descriptor of a message (input parser to output assembly)
    type Desc_t is record
        Dec   : std_logic;
        IvOut : std_logic;
        Iv    : std_logic_vector(95 downto 0);
        Slot  : std_logic_vector(MaxSlotBits_c - 1 downto 0);
        Err   : Status_t;
    end record;

    constant DescWidth_c : positive := 110;
    function descPack (e : Desc_t) return std_logic_vector;
    function descUnpack (v : std_logic_vector) return Desc_t;

    -- Result of a message (tag stage to output assembly)
    type Result_t is record
        Code     : Status_t;
        Tag      : Block_t;
        AadBytes : unsigned(31 downto 0);
        DatBytes : unsigned(31 downto 0);
    end record;

    constant ResultWidth_c : positive := 196;
    function resPack (e : Result_t) return std_logic_vector;
    function resUnpack (v : std_logic_vector) return Result_t;

end package;

---------------------------------------------------------------------------------------------------
-- Package Body
---------------------------------------------------------------------------------------------------
package body ocr_gcm_pkg is

    function datWidth (dataWidth : positive) return positive is
    begin
        return dataWidth + dataWidth / 8 + 2 + 3 + 8;
    end function;

    function datPack (
        e         : DatEntry_t;
        dataWidth : positive) return std_logic_vector is
    begin
        return e.Data(dataWidth - 1 downto 0) & e.Keep(dataWidth / 8 - 1 downto 0) & e.Sec & std_logic_vector(e.K) &
               e.KsPop & e.SecLast & e.BodyLast & e.MsgLast & e.NoBody & e.FmtErr & e.Rej & e.Dec;
    end function;

    function datUnpack (
        v         : std_logic_vector;
        dataWidth : positive) return DatEntry_t is
        constant W_c : positive                           := datWidth(dataWidth);
        variable V_v : std_logic_vector(W_c - 1 downto 0) := v;
        variable R_v : DatEntry_t;
    begin
        R_v.Data                             := (others => '0');
        R_v.Keep                             := (others => '0');
        R_v.Data(dataWidth - 1 downto 0)     := V_v(W_c - 1 downto W_c - dataWidth);
        R_v.Keep(dataWidth / 8 - 1 downto 0) := V_v(W_c - dataWidth - 1 downto 13);
        R_v.Sec                              := V_v(12 downto 11);
        R_v.K                                := unsigned(V_v(10 downto 8));
        R_v.KsPop                            := V_v(7);
        R_v.SecLast                          := V_v(6);
        R_v.BodyLast                         := V_v(5);
        R_v.MsgLast                          := V_v(4);
        R_v.NoBody                           := V_v(3);
        R_v.FmtErr                           := V_v(2);
        R_v.Rej                              := V_v(1);
        R_v.Dec                              := V_v(0);
        return R_v;
    end function;

    function beatWidth (dataWidth : positive) return positive is
    begin
        return dataWidth + dataWidth / 8 + 4;
    end function;

    function beatPack (
        e         : BeatEntry_t;
        dataWidth : positive) return std_logic_vector is
    begin
        return e.Data(dataWidth - 1 downto 0) & e.Keep(dataWidth / 8 - 1 downto 0) & e.Sec & e.SecL & e.Last;
    end function;

    function beatUnpack (
        v         : std_logic_vector;
        dataWidth : positive) return BeatEntry_t is
        constant W_c : positive                           := beatWidth(dataWidth);
        variable V_v : std_logic_vector(W_c - 1 downto 0) := v;
        variable R_v : BeatEntry_t;
    begin
        R_v.Data                             := (others => '0');
        R_v.Keep                             := (others => '0');
        R_v.Data(dataWidth - 1 downto 0)     := V_v(W_c - 1 downto W_c - dataWidth);
        R_v.Keep(dataWidth / 8 - 1 downto 0) := V_v(W_c - dataWidth - 1 downto 4);
        R_v.Sec                              := V_v(3 downto 2);
        R_v.SecL                             := V_v(1);
        R_v.Last                             := V_v(0);
        return R_v;
    end function;

    function sumPack (e : Summary_t) return std_logic_vector is
    begin
        return e.Dec & e.Rej & e.FmtErr & e.EccErr & e.RxTag;
    end function;

    function sumUnpack (v : std_logic_vector) return Summary_t is
        variable V_v : std_logic_vector(SummaryWidth_c - 1 downto 0) := v;
        variable R_v : Summary_t;
    begin
        R_v.Dec    := V_v(131);
        R_v.Rej    := V_v(130);
        R_v.FmtErr := V_v(129);
        R_v.EccErr := V_v(128);
        R_v.RxTag  := V_v(127 downto 0);
        return R_v;
    end function;

    function descPack (e : Desc_t) return std_logic_vector is
    begin
        return e.Dec & e.IvOut & e.Iv & e.Slot & e.Err;
    end function;

    function descUnpack (v : std_logic_vector) return Desc_t is
        variable V_v : std_logic_vector(DescWidth_c - 1 downto 0) := v;
        variable R_v : Desc_t;
    begin
        R_v.Dec   := V_v(109);
        R_v.IvOut := V_v(108);
        R_v.Iv    := V_v(107 downto 12);
        R_v.Slot  := V_v(11 downto 4);
        R_v.Err   := V_v(3 downto 0);
        return R_v;
    end function;

    function resPack (e : Result_t) return std_logic_vector is
    begin
        return e.Code & e.Tag & std_logic_vector(e.AadBytes) & std_logic_vector(e.DatBytes);
    end function;

    function resUnpack (v : std_logic_vector) return Result_t is
        variable V_v : std_logic_vector(ResultWidth_c - 1 downto 0) := v;
        variable R_v : Result_t;
    begin
        R_v.Code     := V_v(195 downto 192);
        R_v.Tag      := V_v(191 downto 64);
        R_v.AadBytes := unsigned(V_v(63 downto 32));
        R_v.DatBytes := unsigned(V_v(31 downto 0));
        return R_v;
    end function;

end package body;
