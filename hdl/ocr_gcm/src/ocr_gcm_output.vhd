---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Output assembly of the GCM data path (OU-1, OU-3): emits the IV section of a generated IV, the AAD
-- and data beats, and the TAG section of an encryption (zeros when the message failed); holds the last
-- beat of a decryption until the verdict and marks a failed message with the error flag on its last
-- beat; replaces a message that its context rejected by one empty beat. Reports the status of every
-- message when its last beat leaves the output register.
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
    use work.ocr_gcm_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_gcm_output is
    generic (
        DataWidth_g : positive := 32;
        SlotBits_g  : positive := 2;
        LenBits_g   : positive := 32
    );
    port (
        -- Control
        Clk             : in    std_logic;
        Rst             : in    std_logic;
        -- Body beats of the combiner
        S_Beat_Valid    : in    std_logic;
        S_Beat_Ready    : out   std_logic;
        S_Beat_Data     : in    std_logic_vector(beatWidth(DataWidth_g) - 1 downto 0);
        S_Beat_EccDed   : in    std_logic;
        -- Descriptor of every message
        S_Desc_Valid    : in    std_logic;
        S_Desc_Ready    : out   std_logic;
        S_Desc_Data     : in    std_logic_vector(DescWidth_c - 1 downto 0);
        S_Desc_EccDed   : in    std_logic;
        -- Result of every message
        S_Res_Valid     : in    std_logic;
        S_Res_Ready     : out   std_logic;
        S_Res_Data      : in    std_logic_vector(ResultWidth_c - 1 downto 0);
        S_Res_EccDed    : in    std_logic;
        -- Output messages; TUser: section (1:0), error flag on the last beat (2). M_Out_Drop: the message is not
        -- OK (last beat); M_Out_IsDropped: the release buffer dropped the message (sampled with the last beat)
        M_Out_Valid     : out   std_logic;
        M_Out_Ready     : in    std_logic;
        M_Out_Data      : out   std_logic_vector(DataWidth_g - 1 downto 0);
        M_Out_Keep      : out   std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        M_Out_Last      : out   std_logic;
        M_Out_User      : out   std_logic_vector(2 downto 0);
        M_Out_Drop      : out   std_logic;
        M_Out_IsDropped : in    std_logic := '0';
        -- Status of every message
        M_Sts_Valid     : out   std_logic;
        M_Sts_Ready     : in    std_logic;
        M_Sts_Code      : out   Status_t;
        M_Sts_Decrypt   : out   std_logic;
        M_Sts_Slot      : out   std_logic_vector(SlotBits_g - 1 downto 0);
        M_Sts_Iv        : out   std_logic_vector(95 downto 0);
        M_Sts_AadBytes  : out   std_logic_vector(LenBits_g - 1 downto 0);
        M_Sts_DataBytes : out   std_logic_vector(LenBits_g - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_gcm_output is

    constant Bytes_c   : positive := DataWidth_g / 8;
    constant Beats_c   : positive := 128 / DataWidth_g;
    constant IvBeats_c : positive := (12 + Bytes_c - 1) / Bytes_c;

    type State_t is (Idle_s, Iv_s, Body_s, Final_s, Tag_s);

    type TwoProcess_r is record
        State     : State_t;
        Desc      : Desc_t;
        Idx       : unsigned(3 downto 0);
        PendValid : std_logic;
        PendData  : std_logic_vector(DataWidth_g - 1 downto 0);
        PendKeep  : std_logic_vector(Bytes_c - 1 downto 0);
        PendSec   : Section_t;
        Res       : Result_t;
        EccErr    : std_logic;  -- uncorrectable error of a buffer that held data of the message
        -- Output register; the status travels with the last beat
        OValid    : std_logic;
        OData     : std_logic_vector(DataWidth_g - 1 downto 0);
        OKeep     : std_logic_vector(Bytes_c - 1 downto 0);
        OLast     : std_logic;
        OSec      : Section_t;
        OErr      : std_logic;
        OCode     : Status_t;
        ODec      : std_logic;
        OSlot     : std_logic_vector(SlotBits_g - 1 downto 0);
        OIv       : std_logic_vector(95 downto 0);
        OAad      : std_logic_vector(LenBits_g - 1 downto 0);
        ODat      : std_logic_vector(LenBits_g - 1 downto 0);
    end record;

    signal r, r_next : TwoProcess_r;

begin

    p_comb : process (all) is
        variable v        : TwoProcess_r;
        variable B_v      : BeatEntry_t;
        variable D_v      : Desc_t;
        variable Res_v    : Result_t;
        variable Xfer_v   : boolean;
        variable Load_v   : boolean;
        variable Emit_v   : boolean;
        variable Fin_v    : boolean;
        variable Code_v   : Status_t;
        variable Tag_v    : Block_t;
        variable Iv_v     : Block_t;
        variable Next_v   : boolean;
        variable BEmpty_v : boolean;

        -- Loads a beat into the output register
        procedure emit (
            data : std_logic_vector;
            keep : std_logic_vector;
            sec  : Section_t;
            last : std_logic) is
        begin
            Emit_v  := true;
            v.OData := data;
            v.OKeep := keep;
            v.OSec  := sec;
            v.OLast := last;
            v.OErr  := '0';
        end procedure;

        -- Status of the message with the last beat
        procedure finish (
            res : Result_t;
            ded : std_logic) is
        begin
            Code_v := stsMerge(r.Desc.Err, res.Code);
            if v.EccErr = '1' or ded = '1' then
                Code_v := stsMerge(Code_v, StsEcc_c);
            end if;
            v.OCode := Code_v;
            if Code_v /= StsOk_c then
                v.OErr := '1';
            end if;
            v.ODec  := r.Desc.Dec;
            v.OSlot := r.Desc.Slot(SlotBits_g - 1 downto 0);
            v.OIv   := r.Desc.Iv;
            v.OAad  := std_logic_vector(res.AadBytes(LenBits_g - 1 downto 0));
            v.ODat  := std_logic_vector(res.DatBytes(LenBits_g - 1 downto 0));
            Next_v  := true;
        end procedure;

        -- Every beat of the message taken from the output FIFO. The error flag is a parameter: a signal that only
        -- a subprogram reads is not part of the sensitivity list of process (all) in every simulator.
        procedure takeBeat (ded : std_logic) is
        begin
            S_Beat_Ready <= '1';
            if ded = '1' then
                v.EccErr := '1';
            end if;
        end procedure;

    -- Output assembly
    begin
        -- hold variables stable
        v := r;

        B_v      := beatUnpack(S_Beat_Data, DataWidth_g);
        D_v      := descUnpack(S_Desc_Data);
        Res_v    := resUnpack(S_Res_Data);
        BEmpty_v := B_v.Keep(Bytes_c - 1 downto 0) = (Bytes_c - 1 downto 0 => '0');

        -- Output register: the last beat leaves together with the status of the message
        Xfer_v := r.OValid = '1' and M_Out_Ready = '1' and (r.OLast = '0' or M_Sts_Ready = '1');
        if Xfer_v then
            v.OValid := '0';
        end if;
        Load_v := r.OValid = '0' or Xfer_v;

        S_Beat_Ready <= '0';
        S_Desc_Ready <= '0';
        S_Res_Ready  <= '0';
        Emit_v       := false;
        Next_v       := false;
        Code_v       := StsOk_c;

        if Load_v then

            case r.State is
                when Idle_s =>
                    null;

                -- IV section of a generated IV, its first byte in lane 0
                when Iv_s =>
                    Iv_v := r.Desc.Iv & x"00000000";
                    emit(blockToBeat(Iv_v, to_integer(r.Idx), Bytes_c),
                         keepOf(minimum(Bytes_c, 12 - to_integer(r.Idx) * Bytes_c), Bytes_c), SecIv_c, '0');
                    if r.Idx = IvBeats_c - 1 then
                        v.State := Body_s;
                        v.Idx   := (others => '0');
                    else
                        v.Idx := r.Idx + 1;
                    end if;

                when Body_s =>
                    if S_Beat_Valid = '1' then
                        if r.Desc.Err /= StsOk_c then
                            -- Rejected message: one empty beat when the result is there
                            if S_Res_Valid = '1' then
                                takeBeat(S_Beat_EccDed);
                                S_Res_Ready <= '1';
                                emit((DataWidth_g - 1 downto 0 => '0'), (Bytes_c - 1 downto 0 => '0'), SecData_c, '1');
                                finish(Res_v, S_Res_EccDed);
                            end if;
                        elsif r.Desc.Dec = '0' then
                            -- Encryption: every beat with bytes; the TAG section follows the last beat
                            takeBeat(S_Beat_EccDed);
                            if not BEmpty_v then
                                emit(B_v.Data(DataWidth_g - 1 downto 0), B_v.Keep(Bytes_c - 1 downto 0), B_v.Sec, '0');
                            end if;
                            if B_v.Last = '1' then
                                v.State := Tag_s;
                                v.Idx   := (others => '0');
                            end if;
                        else
                            -- Decryption: one beat is held back, so that the last beat with bytes carries TLast
                            takeBeat(S_Beat_EccDed);
                            if not BEmpty_v then
                                if r.PendValid = '1' then
                                    emit(r.PendData, r.PendKeep, r.PendSec, '0');
                                end if;
                                v.PendValid := '1';
                                v.PendData  := B_v.Data(DataWidth_g - 1 downto 0);
                                v.PendKeep  := B_v.Keep(Bytes_c - 1 downto 0);
                                v.PendSec   := B_v.Sec;
                            end if;
                            if B_v.Last = '1' then
                                v.State := Final_s;
                            end if;
                        end if;
                    end if;

                -- Decryption: the last beat with the verdict (GCM 7.2 step 8); an empty beat without any byte
                when Final_s =>
                    if S_Res_Valid = '1' then
                        S_Res_Ready <= '1';
                        if r.PendValid = '1' then
                            emit(r.PendData, r.PendKeep, r.PendSec, '1');
                        else
                            emit((DataWidth_g - 1 downto 0 => '0'), (Bytes_c - 1 downto 0 => '0'), SecData_c, '1');
                        end if;
                        v.PendValid := '0';
                        finish(Res_v, S_Res_EccDed);
                    end if;

                -- Encryption: the tag (GCM 7.1 step 7), zeros when the message failed (D12)
                when Tag_s =>
                    -- The result is taken with the first tag beat and kept for the others
                    if r.Idx /= 0 then
                        Res_v := r.Res;
                    elsif S_Res_EccDed = '1' then
                        Res_v.Code := stsMerge(Res_v.Code, StsEcc_c);
                    end if;
                    if r.Idx /= 0 or S_Res_Valid = '1' then
                        if r.Idx = 0 then
                            S_Res_Ready <= '1';
                            v.Res       := Res_v;
                        end if;
                        Code_v := stsMerge(r.Desc.Err, Res_v.Code);
                        if v.EccErr = '1' then
                            Code_v := stsMerge(Code_v, StsEcc_c);
                        end if;
                        if Code_v = StsOk_c then
                            Tag_v := Res_v.Tag;
                        else
                            Tag_v := (others => '0');
                        end if;
                        if r.Idx = Beats_c - 1 then
                            emit(blockToBeat(Tag_v, to_integer(r.Idx), Bytes_c), (Bytes_c - 1 downto 0 => '1'),
                                 SecTag_c, '1');
                            finish(Res_v, '0');
                        else
                            emit(blockToBeat(Tag_v, to_integer(r.Idx), Bytes_c), (Bytes_c - 1 downto 0 => '1'),
                                 SecTag_c, '0');
                            v.Idx := r.Idx + 1;
                        end if;
                    end if;

                -- coverage off
                when others =>
                    -- Recovery of an illegal state
                    v.State := Idle_s;
                -- coverage on
            end case;

            -- Next message: its descriptor is taken in the cycle of the last beat of the previous one
            if Next_v or r.State = Idle_s then
                v.State := Idle_s;
                if S_Desc_Valid = '1' then
                    S_Desc_Ready <= '1';
                    v.Desc       := D_v;
                    v.Idx        := (others => '0');
                    v.EccErr     := S_Desc_EccDed;
                    if D_v.IvOut = '1' and D_v.Err = StsOk_c then
                        v.State := Iv_s;
                    else
                        v.State := Body_s;
                    end if;
                end if;
            end if;
        end if;

        if Emit_v then
            v.OValid := '1';
        end if;

        -- Outputs
        M_Out_Valid <= '0';
        if r.OValid = '1' and (r.OLast = '0' or M_Sts_Ready = '1') then
            M_Out_Valid <= '1';
        end if;
        M_Out_Data <= r.OData;
        M_Out_Keep <= r.OKeep;
        M_Out_Last <= r.OLast;
        M_Out_User <= r.OErr & r.OSec;
        -- The error flag is set on the last beat of a message only
        M_Out_Drop <= r.OErr;

        -- Status: OVERFLOW when the release buffer dropped a message that is otherwise OK
        M_Sts_Valid <= '0';
        if r.OValid = '1' and r.OLast = '1' and M_Out_Ready = '1' then
            M_Sts_Valid <= '1';
        end if;
        M_Sts_Code <= r.OCode;
        if r.OCode = StsOk_c and M_Out_IsDropped = '1' then
            M_Sts_Code <= StsOverflow_c;
        end if;
        M_Sts_Decrypt   <= r.ODec;
        M_Sts_Slot      <= r.OSlot;
        M_Sts_Iv        <= r.OIv;
        M_Sts_AadBytes  <= r.OAad;
        M_Sts_DataBytes <= r.ODat;

        -- assign signal
        r_next <= v;
    end process;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.State     <= Idle_s;
                r.PendValid <= '0';
                r.EccErr    <= '0';
                r.OValid    <= '0';
                r.OLast     <= '0';
            end if;
        end if;
    end process;

end architecture;
