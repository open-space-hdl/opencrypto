---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Input parser of the GCM data path (IN-1, IN-2): takes the job of every message, holds one beat back
-- to find the end of each section, checks the format of the message, issues the AES requests for J0
-- and for the counter block of every DATA block, and forwards the beats with their flags to the data
-- FIFO. Messages that their job rejects are consumed and replaced by one marker entry; a message with
-- a format error is cut at the error and ended by a marker entry.
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
entity ocr_gcm_input is
    generic (
        DataWidth_g : positive := 32;
        KeyBits_g   : positive := 256;
        SlotBits_g  : positive := 2
    );
    port (
        -- Control
        Clk           : in    std_logic;
        Rst           : in    std_logic;
        -- Jobs, one per message
        S_Job_Valid   : in    std_logic;
        S_Job_Ready   : out   std_logic;
        S_Job_Decrypt : in    std_logic;
        S_Job_Key     : in    std_logic_vector(KeyBits_g - 1 downto 0);
        S_Job_H       : in    Block_t;
        S_Job_Iv      : in    std_logic_vector(95 downto 0);
        S_Job_IvOut   : in    std_logic;
        S_Job_Err     : in    Status_t;
        S_Job_Slot    : in    std_logic_vector(SlotBits_g - 1 downto 0);
        -- Input messages; TUser: section
        S_In_Valid    : in    std_logic;
        S_In_Ready    : out   std_logic;
        S_In_Data     : in    std_logic_vector(DataWidth_g - 1 downto 0);
        S_In_Keep     : in    std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        S_In_Last     : in    std_logic;
        S_In_User     : in    Section_t;
        -- Data FIFO
        M_Dat_Valid   : out   std_logic;
        M_Dat_Ready   : in    std_logic;
        M_Dat_Data    : out   std_logic_vector(datWidth(DataWidth_g) - 1 downto 0);
        -- AES requests; Dest '0' keystream block, '1' J0
        M_Req_Valid   : out   std_logic;
        M_Req_Ready   : in    std_logic;
        M_Req_Key     : out   std_logic_vector(KeyBits_g - 1 downto 0);
        M_Req_Block   : out   Block_t;
        M_Req_Dest    : out   std_logic;
        -- Hash subkey (GHASH) and descriptor (output assembly) of every message
        M_H_Valid     : out   std_logic;
        M_H_Ready     : in    std_logic;
        M_H_Data      : out   Block_t;
        M_Desc_Valid  : out   std_logic;
        M_Desc_Ready  : in    std_logic;
        M_Desc_Data   : out   std_logic_vector(DescWidth_c - 1 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_gcm_input is

    constant Bytes_c : positive := DataWidth_g / 8;
    constant Beats_c : positive := 128 / DataWidth_g;

    type Job_r is record
        Valid  : std_logic;
        Dec    : std_logic;
        Key    : std_logic_vector(KeyBits_g - 1 downto 0);
        Iv     : std_logic_vector(95 downto 0);
        Rej    : std_logic;
        J0Done : std_logic;
    end record;

    type TwoProcess_r is record
        Cur      : Job_r;
        Nxt      : Job_r;
        CurEnded : std_logic;  -- all beats of the current message are processed (J0 may be pending)
        -- Held beat
        HbValid  : std_logic;
        HbData   : std_logic_vector(DataWidth_g - 1 downto 0);
        HbKeep   : std_logic_vector(Bytes_c - 1 downto 0);
        HbLast   : std_logic;
        HbSec    : Section_t;
        -- State of the current message
        MsgFirst : std_logic;  -- the held beat is the first beat of the message
        PrevSec  : Section_t;
        Drop     : std_logic;
        BodyDone : std_logic;
        K        : unsigned(2 downto 0);
        Ctr      : unsigned(31 downto 0);
        KsOut    : std_logic;  -- keystream block of the current DATA block requested, not yet used up
        TagCnt   : unsigned(4 downto 0);
    end record;

    signal r, r_next : TwoProcess_r;

    function rank (s : Section_t) return natural is
    begin

        case s is
            when SecAad_c => return 0;
            when SecData_c => return 1;
            when SecTag_c => return 2;
            when others => return 3;
        end case;

    end function;

begin

    p_comb : process (all) is
        variable v         : TwoProcess_r;
        variable E_v       : DatEntry_t;
        variable Full_v    : boolean;
        variable Contig_v  : boolean;
        variable Empty_v   : boolean;
        variable SecLast_v : std_logic;
        variable SecFst_v  : boolean;
        variable Proc_v    : boolean;
        variable Err_v     : boolean;
        variable Fwd_v     : boolean;
        variable Marker_v  : boolean;
        variable NeedKs_v  : boolean;
        variable Done_v    : boolean;
        variable KsReq_v   : boolean;
        variable J0Cur_v   : boolean;
        variable J0Nxt_v   : boolean;
        variable CurFree_v : boolean;
        variable JobAcc_v  : boolean;
        variable NxtFree_v : boolean;
    begin
        -- hold variables stable
        v := r;

        -------------------------------------------------------------------------------------------
        -- Classification of the held beat; its successor shows whether it ends its section
        -------------------------------------------------------------------------------------------
        Full_v   := r.HbKeep = (r.HbKeep'range => '1');
        Empty_v  := r.HbKeep = (r.HbKeep'range => '0');
        Contig_v := true;

        for i in 1 to Bytes_c - 1 loop
            if r.HbKeep(i) = '1' and r.HbKeep(i - 1) = '0' then
                Contig_v := false;
            end if;
        end loop;

        if r.HbLast = '1' or S_In_User /= r.HbSec then
            SecLast_v := '1';
        else
            SecLast_v := '0';
        end if;
        SecFst_v := r.MsgFirst = '1' or r.HbSec /= r.PrevSec;

        -- The held beat can be processed when it belongs to the current message and its successor is known
        Proc_v := r.HbValid = '1' and r.Cur.Valid = '1' and r.CurEnded = '0' and
                  (r.HbLast = '1' or S_In_Valid = '1');

        -- Format of the message (docs/architecture.md, section 6)
        Err_v := false;
        if r.HbSec = SecIv_c then
            Err_v := true;
        end if;
        if r.MsgFirst = '0' and rank(r.HbSec) < rank(r.PrevSec) then
            Err_v := true;
        end if;
        if r.HbSec = SecTag_c and r.Cur.Dec = '0' then
            Err_v := true;
        end if;
        -- Only the last beat of a section is partial; an empty beat is a section of its own (an empty beat that is not
        -- the last of its section is already partial)
        if not Contig_v or (SecLast_v = '0' and not Full_v) or (Empty_v and not SecFst_v) then
            Err_v := true;
        end if;
        -- GCM 7.2 step 1: the tag has 16 bytes
        if r.HbSec = SecTag_c and (not Full_v or r.TagCnt >= Beats_c or (SecLast_v = '1' and r.TagCnt /= Beats_c - 1)) then
            Err_v := true;
        end if;

        Fwd_v    := false;
        Marker_v := false;
        if r.Cur.Rej = '1' or r.Drop = '1' or Err_v then
            -- Rejected or cut message: the beat is dropped, the last one is replaced by a marker
            Marker_v := r.HbLast = '1';
        else
            Fwd_v := true;
        end if;

        -- Entry of the data FIFO
        E_v.Data                           := (others => '0');
        E_v.Keep                           := (others => '0');
        E_v.Data(DataWidth_g - 1 downto 0) := r.HbData;
        E_v.Keep(Bytes_c - 1 downto 0)     := r.HbKeep;
        E_v.Sec                            := r.HbSec;
        E_v.K                              := (others => '0');
        E_v.KsPop                          := '0';
        E_v.SecLast                        := SecLast_v;
        E_v.BodyLast                       := '0';
        E_v.MsgLast                        := r.HbLast;
        E_v.NoBody                         := '0';
        E_v.FmtErr                         := '0';
        E_v.Rej                            := '0';
        E_v.Dec                            := r.Cur.Dec;
        -- A DATA beat uses the keystream block of its block; an empty DATA section uses none
        if r.HbSec = SecData_c and not Empty_v then
            E_v.K := r.K;
            if r.K = Beats_c - 1 or SecLast_v = '1' then
                E_v.KsPop := '1';
            end if;
        end if;
        if (r.HbSec = SecAad_c or r.HbSec = SecData_c) and (r.HbLast = '1' or S_In_User = SecTag_c) then
            E_v.BodyLast := '1';
        end if;
        if r.HbSec = SecTag_c and SecFst_v and r.BodyDone = '0' then
            E_v.NoBody := '1';
        end if;
        -- A decryption without TAG section
        if r.Cur.Dec = '1' and r.HbLast = '1' and r.HbSec /= SecTag_c then
            E_v.FmtErr := '1';
        end if;
        if Marker_v then
            E_v.Data     := (others => '0');
            E_v.Keep     := (others => '0');
            E_v.K        := (others => '0');
            E_v.KsPop    := r.KsOut;
            E_v.SecLast  := '1';
            E_v.MsgLast  := '1';
            E_v.NoBody   := '0';
            E_v.Rej      := r.Cur.Rej;
            E_v.FmtErr   := not r.Cur.Rej;
            E_v.BodyLast := not r.BodyDone;
            if r.BodyDone = '1' then
                E_v.Sec := SecTag_c;
            else
                E_v.Sec := SecData_c;
            end if;
        end if;
        M_Dat_Data <= datPack(E_v, DataWidth_g);

        -------------------------------------------------------------------------------------------
        -- AES requests: the keystream block of a DATA block first, then J0 of the current or next message
        -------------------------------------------------------------------------------------------
        NeedKs_v := Proc_v and Fwd_v and r.HbSec = SecData_c and not Empty_v and r.K = 0;
        KsReq_v  := NeedKs_v and M_Dat_Ready = '1';
        J0Cur_v  := false;
        J0Nxt_v  := false;
        if not KsReq_v then
            if r.Cur.Valid = '1' and r.Cur.Rej = '0' and r.Cur.J0Done = '0' then
                J0Cur_v := true;
            elsif r.Nxt.Valid = '1' and r.Nxt.Rej = '0' and r.Nxt.J0Done = '0' then
                -- The current message has no J0 pending
                J0Nxt_v := true;
            end if;
        end if;

        M_Req_Valid <= '0';
        M_Req_Dest  <= '0';
        M_Req_Key   <= r.Cur.Key;
        -- GCM 6.2, 6.5: counter block inc32^i(J0) of the DATA block i
        M_Req_Block <= r.Cur.Iv & std_logic_vector(r.Ctr);
        if KsReq_v then
            M_Req_Valid <= '1';
        elsif J0Cur_v or J0Nxt_v then
            -- GCM 7.1 step 2: J0 = IV || 0^31 || 1
            M_Req_Valid <= '1';
            M_Req_Dest  <= '1';
            if J0Nxt_v then
                M_Req_Key   <= r.Nxt.Key;
                M_Req_Block <= r.Nxt.Iv & x"00000001";
            else
                M_Req_Block <= r.Cur.Iv & x"00000001";
            end if;
        end if;
        if not KsReq_v and M_Req_Ready = '1' then
            if J0Cur_v then
                v.Cur.J0Done := '1';
            elsif J0Nxt_v then
                v.Nxt.J0Done := '1';
            end if;
        end if;

        -------------------------------------------------------------------------------------------
        -- Processing of the held beat
        -------------------------------------------------------------------------------------------
        M_Dat_Valid <= '0';
        Done_v      := false;
        if Proc_v then
            if Fwd_v or Marker_v then
                if NeedKs_v then
                    if M_Dat_Ready = '1' then
                        M_Req_Valid <= '1';
                    end if;
                    if M_Req_Ready = '1' then
                        M_Dat_Valid <= '1';
                    end if;
                    Done_v := M_Dat_Ready = '1' and M_Req_Ready = '1';
                else
                    M_Dat_Valid <= '1';
                    Done_v      := M_Dat_Ready = '1';
                end if;
            else
                -- Dropped beat
                Done_v := true;
            end if;
        end if;

        if Done_v then
            if Fwd_v then
                v.PrevSec := r.HbSec;
                if r.HbSec = SecData_c and not Empty_v then
                    if r.K = 0 then
                        v.Ctr   := r.Ctr + 1;
                        v.KsOut := '1';
                    end if;
                    if E_v.KsPop = '1' then
                        v.K     := (others => '0');
                        v.KsOut := '0';
                    else
                        v.K := r.K + 1;
                    end if;
                end if;
                if r.HbSec = SecTag_c then
                    v.TagCnt := r.TagCnt + 1;
                end if;
                if E_v.BodyLast = '1' or E_v.NoBody = '1' then
                    v.BodyDone := '1';
                end if;
            elsif r.Cur.Rej = '0' then
                -- Format error: the rest of the message is dropped
                v.Drop := '1';
            end if;
            v.MsgFirst := '0';
            v.HbValid  := '0';
            if r.HbLast = '1' then
                -- End of the message
                v.CurEnded := '1';
                v.MsgFirst := '1';
                v.Drop     := '0';
                v.BodyDone := '0';
                v.K        := (others => '0');
                v.KsOut    := '0';
                v.TagCnt   := (others => '0');
                v.PrevSec  := SecAad_c;
            end if;
        end if;

        -- Next beat into the hold register
        S_In_Ready <= '0';
        if r.HbValid = '0' or Done_v then
            S_In_Ready <= '1';
            if S_In_Valid = '1' then
                v.HbValid := '1';
                v.HbData  := S_In_Data;
                v.HbKeep  := S_In_Keep;
                v.HbLast  := S_In_Last;
                v.HbSec   := S_In_User;
            end if;
        end if;

        -------------------------------------------------------------------------------------------
        -- Jobs: the next job follows when the current message has ended and its J0 is requested
        -------------------------------------------------------------------------------------------
        CurFree_v := r.Cur.Valid = '0' or
                     (v.CurEnded = '1' and (v.Cur.J0Done = '1' or r.Cur.Rej = '1'));
        if CurFree_v then
            v.Cur       := v.Nxt;
            v.CurEnded  := '0';
            v.Ctr       := to_unsigned(2, 32);
            v.Nxt.Valid := '0';
        end if;

        -- A job is taken when the next-job register is free; its hash subkey and descriptor enter their FIFOs with it
        NxtFree_v := v.Nxt.Valid = '0';
        JobAcc_v  := S_Job_Valid = '1' and NxtFree_v and M_H_Ready = '1' and M_Desc_Ready = '1';
        if JobAcc_v then
            v.Nxt.Valid  := '1';
            v.Nxt.Dec    := S_Job_Decrypt;
            v.Nxt.Key    := S_Job_Key;
            v.Nxt.Iv     := S_Job_Iv;
            v.Nxt.J0Done := '0';
            if S_Job_Err /= StsOk_c then
                v.Nxt.Rej := '1';
            else
                v.Nxt.Rej := '0';
            end if;
        end if;
        S_Job_Ready  <= '1' when NxtFree_v and M_H_Ready = '1' and M_Desc_Ready = '1' else '0';
        M_H_Valid    <= '1' when S_Job_Valid = '1' and NxtFree_v and M_Desc_Ready = '1' else '0';
        M_Desc_Valid <= '1' when S_Job_Valid = '1' and NxtFree_v and M_H_Ready = '1' else '0';
        -- A rejected message has no hash subkey
        if S_Job_Err /= StsOk_c then
            M_H_Data <= (others => '0');
        else
            M_H_Data <= S_Job_H;
        end if;
        M_Desc_Data <= descPack((Dec   => S_Job_Decrypt,
                                 IvOut => S_Job_IvOut,
                                 Iv    => S_Job_Iv,
                                 Slot  => std_logic_vector(resize(unsigned(S_Job_Slot), MaxSlotBits_c)),
                                 Err   => S_Job_Err));

        -- assign signal
        r_next <= v;
    end process;

    p_seq : process (Clk) is
    begin
        if rising_edge(Clk) then
            r <= r_next;
            if Rst = '1' then
                r.Cur.Valid <= '0';
                r.Nxt.Valid <= '0';
                r.CurEnded  <= '0';
                r.HbValid   <= '0';
                r.MsgFirst  <= '1';
                r.PrevSec   <= SecAad_c;
                r.Drop      <= '0';
                r.BodyDone  <= '0';
                r.K         <= (others => '0');
                r.Ctr       <= to_unsigned(2, 32);
                r.KsOut     <= '0';
                r.TagCnt    <= (others => '0');
            end if;
        end if;
    end process;

end architecture;
