---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- GHASH (NIST SP 800-38D 6.4) of the AAD and the ciphertext of a message: assembles 128-bit blocks
-- from the beats with zero padding at the end of each section, appends the length block
-- [len(A)]64 || [len(C)]64 and multiplies Y(i) = (Y(i-1) xor X(i)) * H with a digit-serial multiplier
-- of Digit_g bits per clock cycle. Delivers S and the byte counts of the sections per message.
--
-- Documentation: hdl/ocr_ghash/docs/architecture.md

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

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_ghash is
    generic (
        DataWidth_g : positive range 16 to 128 := 32;
        Digit_g     : positive range 16 to 128 := 64;
        LenBits_g   : positive range 8 to 32   := 32
    );
    port (
        -- Control
        Clk           : in    std_logic;
        Rst           : in    std_logic;
        -- AAD and ciphertext beats: In_Aad '1' AAD, '0' ciphertext; In_SecLast last beat of a section,
        -- In_MsgLast last beat of the message. A message has at least one beat; an empty section is one beat
        -- without byte enable.
        In_Valid      : in    std_logic;
        In_Ready      : out   std_logic;
        In_Data       : in    std_logic_vector(DataWidth_g - 1 downto 0);
        In_Keep       : in    std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        In_Aad        : in    std_logic;
        In_SecLast    : in    std_logic;
        In_MsgLast    : in    std_logic;
        In_Err        : in    std_logic := '0';
        -- Hash subkey of every message, in the order of the messages
        H_Valid       : in    std_logic;
        H_Ready       : out   std_logic;
        H_Data        : in    Block_t;
        H_Err         : in    std_logic := '0';
        -- Result per message; Out_LenErr: a section exceeded 2^LenBits_g - 1 bytes; Out_EccErr: an input beat or the
        -- hash subkey of the message came with In_Err or H_Err (uncorrectable error of a buffer in front)
        Out_Valid     : out   std_logic;
        Out_Ready     : in    std_logic := '1';
        Out_S         : out   Block_t;
        Out_AadBytes  : out   std_logic_vector(LenBits_g - 1 downto 0);
        Out_DataBytes : out   std_logic_vector(LenBits_g - 1 downto 0);
        Out_LenErr    : out   std_logic;
        Out_EccErr    : out   std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_ghash is

    constant Bytes_c       : positive                         := DataWidth_g / 8;
    constant Beats_c       : positive                         := 128 / DataWidth_g;
    constant Steps_c       : positive                         := 128 / Digit_g;
    constant KBits_c       : positive                         := log2ceil(Beats_c + 1);
    constant SBits_c       : positive                         := log2ceil(Steps_c + 1);
    constant LenMax_c      : unsigned(LenBits_g - 1 downto 0) := (others => '1');
    -- Block of the multiplier: X, first block of the message, length block, length and ECC error of the message.
    -- The byte counts of the message follow from the length block.
    constant BlkWidth_c    : positive := 128 + 4;
    -- Queue between assembly and multiplier: a multiplier of more than one step per block needs room for the
    -- short blocks of several messages, so that its idle cycles in long sections make up for them (D5)
    constant QueueStages_c : positive := choose(Steps_c = 1, 1, 3);

    type Asm_r is record
        X          : Block_t;
        K          : unsigned(KBits_c - 1 downto 0);
        HasBytes   : std_logic;
        First      : std_logic;
        LenA       : unsigned(LenBits_g - 1 downto 0);
        LenC       : unsigned(LenBits_g - 1 downto 0);
        LenErr     : std_logic;
        EccErr     : std_logic;
        LenPending : std_logic;
    end record;

    type Mul_r is record
        Step       : unsigned(SBits_c - 1 downto 0);
        Z          : Block_t;
        Y          : Block_t;
        H          : Block_t;
        HNext      : Block_t;
        HNextValid : std_logic;
        HNextErr   : std_logic;
        HErr       : std_logic;
        OutValid   : std_logic;
        OutS       : Block_t;
        OutLenA    : std_logic_vector(LenBits_g - 1 downto 0);
        OutLenC    : std_logic_vector(LenBits_g - 1 downto 0);
        OutLenErr  : std_logic;
        OutEccErr  : std_logic;
    end record;

    signal ra, ra_next : Asm_r;
    signal rp, rp_next : Mul_r;

    signal Blk_InValid  : std_logic;
    signal Blk_InReady  : std_logic;
    signal Blk_InData   : std_logic_vector(BlkWidth_c - 1 downto 0);
    signal Blk_OutValid : std_logic;
    signal Blk_OutReady : std_logic;
    signal Blk_OutData  : std_logic_vector(BlkWidth_c - 1 downto 0);

    function packBlk (
        x      : Block_t;
        first  : std_logic;
        last   : std_logic;
        lenErr : std_logic;
        eccErr : std_logic) return std_logic_vector is
    begin
        return x & first & last & lenErr & eccErr;
    end function;

begin

    assert DataWidth_g = 16 or DataWidth_g = 32 or DataWidth_g = 64 or DataWidth_g = 128
        report "ocr_ghash: DataWidth_g must be 16, 32, 64 or 128"
        severity failure;
    assert (Digit_g = 16 or Digit_g = 32 or Digit_g = 64 or Digit_g = 128) and Digit_g >= DataWidth_g
        report "ocr_ghash: Digit_g must be a power of two from DataWidth_g to 128"
        severity failure;

    -----------------------------------------------------------------------------------------------
    -- Block assembly (GCM 7.1 step 5: A || 0^v || C || 0^u || [len(A)]64 || [len(C)]64)
    -----------------------------------------------------------------------------------------------
    p_asm_comb : process (all) is
        variable v       : Asm_r;
        variable Bytes_v : natural range 0 to Bytes_c;
        variable Data_v  : std_logic_vector(DataWidth_g - 1 downto 0);
        variable X_v     : Block_t;
        variable Len_v   : unsigned(LenBits_g downto 0);
        variable LenA_v  : std_logic_vector(63 downto 0);
        variable LenC_v  : std_logic_vector(63 downto 0);
    begin
        -- hold variables stable
        v := ra;

        Blk_InValid <= '0';
        Blk_InData  <= packBlk(ra.X, ra.First, '0', ra.LenErr, ra.EccErr);

        -- Valid bytes of the beat (contiguous from lane 0); other lanes are zero (padding)
        Bytes_v := 0;
        Data_v  := In_Data;

        for i in 0 to Bytes_c - 1 loop
            if In_Keep(i) = '1' then
                Bytes_v := i + 1;
            else
                Data_v(8 * i + 7 downto 8 * i) := (others => '0');
            end if;
        end loop;

        X_v := beatToBlock(ra.X, Data_v, to_integer(ra.K), Bytes_c);

        if ra.LenPending = '1' then
            -- Length block of the message, in bits
            LenA_v      := std_logic_vector(resize(ra.LenA & "000", 64));
            LenC_v      := std_logic_vector(resize(ra.LenC & "000", 64));
            Blk_InValid <= '1';
            Blk_InData  <= packBlk(LenA_v & LenC_v, ra.First, '1', ra.LenErr, ra.EccErr);
            if Blk_InReady = '1' then
                v.LenPending := '0';
                v.First      := '1';
                v.LenA       := (others => '0');
                v.LenC       := (others => '0');
                v.LenErr     := '0';
                v.EccErr     := '0';
            end if;
        elsif In_Valid = '1' and Blk_InReady = '1' then
            if In_Err = '1' then
                v.EccErr := '1';
            end if;
            -- Byte counts, saturating at 2^LenBits_g - 1 (GCM 5.2.1.1: supported lengths)
            if In_Aad = '1' then
                Len_v := resize(ra.LenA, LenBits_g + 1) + Bytes_v;
            else
                Len_v := resize(ra.LenC, LenBits_g + 1) + Bytes_v;
            end if;
            if Len_v(LenBits_g) = '1' then
                Len_v    := '0' & LenMax_c;
                v.LenErr := '1';
            end if;
            if In_Aad = '1' then
                v.LenA := Len_v(LenBits_g - 1 downto 0);
            else
                v.LenC := Len_v(LenBits_g - 1 downto 0);
            end if;

            v.X := X_v;
            if Bytes_v /= 0 then
                v.HasBytes := '1';
            end if;
            if ra.K = Beats_c - 1 or In_SecLast = '1' then
                -- Block complete: full, or the end of a section (zero padding); an empty section has no block
                if ra.HasBytes = '1' or Bytes_v /= 0 then
                    Blk_InValid <= '1';
                    Blk_InData  <= packBlk(X_v, ra.First, '0', ra.LenErr, v.EccErr);
                    v.First     := '0';
                end if;
                v.X        := (others => '0');
                v.K        := (others => '0');
                v.HasBytes := '0';
            else
                v.K := ra.K + 1;
            end if;
            if In_MsgLast = '1' then
                v.LenPending := '1';
            end if;
        end if;

        In_Ready <= Blk_InReady and not ra.LenPending;

        -- assign signal
        ra_next <= v;
    end process;

    p_asm_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            ra <= ra_next;
            if Rst = '1' then
                ra.X          <= (others => '0');
                ra.K          <= (others => '0');
                ra.HasBytes   <= '0';
                ra.First      <= '1';
                ra.LenA       <= (others => '0');
                ra.LenC       <= (others => '0');
                ra.LenErr     <= '0';
                ra.EccErr     <= '0';
                ra.LenPending <= '0';
            end if;
        end if;
    end process;

    i_blk : entity olo.olo_base_pl_stage
        generic map (
            Width_g  => BlkWidth_c,
            Stages_g => QueueStages_c
        )
        port map (
            Clk       => Clk,
            Rst       => Rst,
            In_Valid  => Blk_InValid,
            In_Ready  => Blk_InReady,
            In_Data   => Blk_InData,
            Out_Valid => Blk_OutValid,
            Out_Ready => Blk_OutReady,
            Out_Data  => Blk_OutData
        );

    -----------------------------------------------------------------------------------------------
    -- Multiplier (GCM 6.3, 6.4): Steps_c digits of Y xor X per block, the highest-degree digit first
    -----------------------------------------------------------------------------------------------
    p_mul_comb : process (all) is
        variable v       : Mul_r;
        variable X_v     : Block_t;
        variable First_v : std_logic;
        variable Last_v  : std_logic;
        variable A_v     : Block_t;
        variable H_v     : Block_t;
        variable Zin_v   : Block_t;
        variable Dig_v   : std_logic_vector(Digit_g - 1 downto 0);
        variable Znew_v  : Block_t;
        variable Run_v   : std_logic;
        variable Fin_v   : std_logic;
    begin
        -- hold variables stable
        v := rp;

        X_v     := Blk_OutData(131 downto 4);
        First_v := Blk_OutData(3);
        Last_v  := Blk_OutData(2);

        -- Output register
        if Out_Ready = '1' then
            v.OutValid := '0';
        end if;

        -- A block runs when it is available, its H is known (first block of a message) and, for the length
        -- block, the output register is free
        Run_v := Blk_OutValid;
        if First_v = '1' and rp.Step = 0 and rp.HNextValid = '0' then
            Run_v := '0';
        end if;
        if Last_v = '1' and rp.OutValid = '1' and Out_Ready = '0' then
            Run_v := '0';
        end if;

        -- Y xor X; Y = 0 for the first block of a message (GCM 6.4 step 2)
        if First_v = '1' then
            A_v := X_v;
        else
            A_v := rp.Y xor X_v;
        end if;
        if First_v = '1' and rp.Step = 0 then
            H_v := rp.HNext;
        else
            H_v := rp.H;
        end if;
        if rp.Step = 0 then
            Zin_v := (others => '0');
        else
            Zin_v := rp.Z;
        end if;
        Dig_v := (others => '0');

        for s in 0 to Steps_c - 1 loop
            if rp.Step = s then
                Dig_v := A_v(Digit_g * s + Digit_g - 1 downto Digit_g * s);
            end if;
        end loop;

        Znew_v := gfMulDigit(Zin_v, Dig_v, H_v);

        Fin_v := '0';
        if rp.Step = Steps_c - 1 then
            Fin_v := '1';
        end if;

        Blk_OutReady <= Run_v and Fin_v;

        -- Hash subkey of the next message: loaded when the register is free or taken in this cycle
        if Run_v = '1' and First_v = '1' and rp.Step = 0 then
            v.H          := rp.HNext;
            v.HErr       := rp.HNextErr;
            v.HNextValid := '0';
        end if;
        H_Ready <= not v.HNextValid;
        if H_Valid = '1' and v.HNextValid = '0' then
            v.HNext      := H_Data;
            v.HNextErr   := H_Err;
            v.HNextValid := '1';
        end if;

        if Run_v = '1' then
            if Fin_v = '1' then
                v.Step := (others => '0');
                v.Y    := Znew_v;
                if Last_v = '1' then
                    -- S of the message (GCM 7.1 step 5)
                    v.OutValid := '1';
                    v.OutS     := Znew_v;
                    -- Byte counts from the bit lengths of the length block
                    v.OutLenA   := X_v(LenBits_g + 66 downto 67);
                    v.OutLenC   := X_v(LenBits_g + 2 downto 3);
                    v.OutLenErr := Blk_OutData(1);
                    v.OutEccErr := Blk_OutData(0) or v.HErr;
                end if;
            else
                v.Z    := Znew_v;
                v.Step := rp.Step + 1;
            end if;
        end if;

        Out_Valid     <= rp.OutValid;
        Out_S         <= rp.OutS;
        Out_AadBytes  <= rp.OutLenA;
        Out_DataBytes <= rp.OutLenC;
        Out_LenErr    <= rp.OutLenErr;
        Out_EccErr    <= rp.OutEccErr;

        -- assign signal
        rp_next <= v;
    end process;

    p_mul_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            rp <= rp_next;
            if Rst = '1' then
                rp.Step       <= (others => '0');
                rp.HNextValid <= '0';
                rp.OutValid   <= '0';
            end if;
        end if;
    end process;

end architecture;
