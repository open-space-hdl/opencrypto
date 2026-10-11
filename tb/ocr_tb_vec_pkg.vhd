---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Vector store of the testbenches: reads the vector files of tools/ocr_vectors.py (AES examples,
-- key slots, messages with their input sections, expected output sections, GHASH results and
-- status) into up to TbSets_c sets, and keeps a cursor, a stall probability and statistics for
-- each model channel of a set. The models of tb/ process the messages of their set in order.
--
-- Documentation: docs/conventions.md (section Verification)

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library std;
    use std.textio.all;

---------------------------------------------------------------------------------------------------
-- Package Header
---------------------------------------------------------------------------------------------------
package ocr_tb_vec_pkg is

    constant TbSets_c     : natural := 4;
    constant TbChannels_c : natural := 8;
    constant TbMaxSec_c   : natural := 8;

    -- Model channels of a set (each has its own cursor through the messages)
    constant ChSource_c : natural := 0;
    constant ChCtx_c    : natural := 1;
    constant ChSink_c   : natural := 2;
    constant ChSts_c    : natural := 3;
    constant ChAux_c    : natural := 4;

    -- Bench options of a message (MSG flags of tools/ocr_vectors.py)
    constant FlagErrInjSec_c : natural := 1;
    constant FlagErrInjDed_c : natural := 2;
    constant FlagAbort_c     : natural := 4;
    constant FlagJobErr_c    : natural := 8;
    constant FlagOutOk_c     : natural := 16; -- the output is OK although the status is not (status FIFO error)
    constant FlagOutErr_c    : natural := 32; -- the output ends with the error flag although the status is OK

    -- Bytes of a section, first byte at the lowest index
    type TbBytes_t is array (natural range <>) of std_logic_vector(7 downto 0);

    -- True when flag is set in flags
    function tbFlag (
        flags : natural;
        flag  : natural) return boolean;

    -- '1' for true, '0' for false
    function tbSl (b : boolean) return std_logic;

    type VecStore_t is protected

        -- Reads a vector file into a set (the set is cleared first)
        procedure load (
            set      : natural;
            fileName : string);

        -- AES examples (ECB records)
        impure function ecbCount (set : natural) return natural;
        impure function ecbKeyBits (
            set : natural;
            e   : natural) return natural;
        impure function ecbKey (
            set : natural;
            e   : natural) return std_logic_vector; -- 256 bits, key left-aligned
        impure function ecbIn (
            set : natural;
            e   : natural) return std_logic_vector;
        impure function ecbOut (
            set : natural;
            e   : natural) return std_logic_vector;

        -- Key slots (KEY records)
        impure function keyCount (set : natural) return natural;
        impure function keySlot (
            set : natural;
            k   : natural) return natural;
        impure function keyBits (
            set : natural;
            k   : natural) return natural;
        impure function keyValue (
            set : natural;
            k   : natural) return std_logic_vector; -- 256 bits, key left-aligned
        impure function keyHash (
            set : natural;
            k   : natural) return std_logic_vector;
        impure function keyIvGen (
            set : natural;
            k   : natural) return boolean;
        impure function keyFixed (
            set : natural;
            k   : natural) return std_logic_vector;
        impure function keyCounter (
            set : natural;
            k   : natural) return std_logic_vector;
        -- Index of the KEY record that defines a slot (the last one in the file)
        impure function keyOfSlot (
            set  : natural;
            slot : natural) return natural;

        -- Messages
        impure function msgCount (set : natural) return natural;
        impure function msgDec (
            set : natural;
            m   : natural) return boolean;
        impure function msgSlot (
            set : natural;
            m   : natural) return natural;
        impure function msgIvGen (
            set : natural;
            m   : natural) return boolean;
        impure function msgIv (
            set : natural;
            m   : natural) return std_logic_vector;
        impure function msgFlags (
            set : natural;
            m   : natural) return natural;

        -- Input sections of a message
        impure function inCount (
            set : natural;
            m   : natural) return natural;
        impure function inCode (
            set : natural;
            m   : natural;
            s   : natural) return character;
        impure function inLen (
            set : natural;
            m   : natural;
            s   : natural) return natural;
        impure function inByte (
            set : natural;
            m   : natural;
            s   : natural;
            i   : natural) return std_logic_vector;

        -- Expected output sections of a message ('X': content not checked)
        impure function outCount (
            set : natural;
            m   : natural) return natural;
        impure function outCode (
            set : natural;
            m   : natural;
            s   : natural) return character;
        impure function outLen (
            set : natural;
            m   : natural;
            s   : natural) return natural;
        impure function outByte (
            set : natural;
            m   : natural;
            s   : natural;
            i   : natural) return std_logic_vector;

        -- Expected status and GHASH result
        impure function stsCode (
            set : natural;
            m   : natural) return natural;
        impure function stsAad (
            set : natural;
            m   : natural) return natural;
        impure function stsData (
            set : natural;
            m   : natural) return natural;
        impure function stsIv (
            set : natural;
            m   : natural) return std_logic_vector;
        impure function ghValid (
            set : natural;
            m   : natural) return boolean;
        impure function ghashValue (
            set : natural;
            m   : natural) return std_logic_vector;

        -- Model channels: cursor (next message), limit (messages to process), stall probability
        procedure setLimit (
            set   : natural;
            ch    : natural;
            limit : natural);
        impure function limit (
            set : natural;
            ch  : natural) return natural;
        impure function cursor (
            set : natural;
            ch  : natural) return natural;

        procedure advance (
            set : natural;
            ch  : natural);

        procedure setCursor (
            set : natural;
            ch  : natural;
            pos : natural);

        procedure setStall (
            set  : natural;
            ch   : natural;
            prob : real);
        impure function stall (
            set : natural;
            ch  : natural) return real;

        -- Release buffer mode of a sink: messages whose status is not OK are not expected at the output
        procedure setSkipFailed (
            set  : natural;
            ch   : natural;
            skip : boolean);
        impure function skipFailed (
            set : natural;
            ch  : natural) return boolean;

        -- Abort of the message in transfer (reset tests)
        procedure setAbort (
            set : natural;
            ch  : natural);
        impure function getAbort (
            set : natural;
            ch  : natural) return boolean;

        procedure clearAbort (
            set : natural;
            ch  : natural);

        -- Statistics of a channel: beats, cycles without transfer between the first and the last beat
        -- in which the model was ready to transfer (gaps), time of the first and the last beat
        procedure clearStats (
            set : natural;
            ch  : natural);

        procedure addBeat (
            set : natural;
            ch  : natural;
            t   : time);

        procedure addGap (
            set : natural;
            ch  : natural);
        impure function beats (
            set : natural;
            ch  : natural) return natural;
        impure function gaps (
            set : natural;
            ch  : natural) return natural;
        impure function firstTime (
            set : natural;
            ch  : natural) return time;
        impure function lastTime (
            set : natural;
            ch  : natural) return time;

    end protected;

end package;

---------------------------------------------------------------------------------------------------
-- Package Body
---------------------------------------------------------------------------------------------------
package body ocr_tb_vec_pkg is

    function tbFlag (
        flags : natural;
        flag  : natural) return boolean is
    begin
        return (flags / flag) mod 2 = 1;
    end function;

    function tbSl (b : boolean) return std_logic is
    begin
        if b then
            return '1';
        end if;
        return '0';
    end function;

    type BytesPtr_t is access TbBytes_t;

    type Sec_t is record
        Code : character;
        Data : BytesPtr_t;
    end record;

    type SecArr_t is array (0 to TbMaxSec_c - 1) of Sec_t;

    type Msg_t is record
        Dec     : boolean;
        Slot    : natural;
        IvGen   : boolean;
        Iv      : std_logic_vector(95 downto 0);
        Flags   : natural;
        NIn     : natural;
        InSec   : SecArr_t;
        NOut    : natural;
        OutSec  : SecArr_t;
        StsCode : natural;
        StsAad  : natural;
        StsData : natural;
        StsIv   : std_logic_vector(95 downto 0);
        GhValid : boolean;
        GhS     : std_logic_vector(127 downto 0);
    end record;

    type MsgPtr_t is access Msg_t;

    type MsgArr_t is array (natural range <>) of MsgPtr_t;

    type MsgArrPtr_t is access MsgArr_t;

    type Key_t is record
        Slot    : natural;
        Bits    : natural;
        Key     : std_logic_vector(255 downto 0);
        H       : std_logic_vector(127 downto 0);
        IvGen   : boolean;
        Fixed   : std_logic_vector(31 downto 0);
        Counter : std_logic_vector(63 downto 0);
    end record;

    type KeyArr_t is array (natural range <>) of Key_t;

    type KeyArrPtr_t is access KeyArr_t;

    type Ecb_t is record
        Bits : natural;
        Key  : std_logic_vector(255 downto 0);
        Din  : std_logic_vector(127 downto 0);
        Dout : std_logic_vector(127 downto 0);
    end record;

    type EcbArr_t is array (natural range <>) of Ecb_t;

    type EcbArrPtr_t is access EcbArr_t;

    function hexVal (c : character) return natural is
    begin

        case c is
            when '0' to '9' => return character'pos(c) - character'pos('0');
            when 'a' to 'f' => return character'pos(c) - character'pos('a') + 10;
            when 'A' to 'F' => return character'pos(c) - character'pos('A') + 10;
            when others =>
                report "ocr_tb_vec_pkg: illegal hex character " & c severity failure;
                return 0;
        end case;

    end function;

    -- Next token of a line (separated by blanks); the line keeps the rest
    procedure getToken (
        L   : inout line;
        Tok : inout line) is
        variable S_v   : integer;
        variable E_v   : integer;
        variable Tmp_v : line;
    begin
        if Tok /= null then
            deallocate(Tok);
        end if;
        if L = null or L'length = 0 then
            Tok := new string'("");
            return;
        end if;
        S_v := L'left;

        while S_v <= L'right and (L(S_v) = ' ' or L(S_v) = HT) loop
            S_v := S_v + 1;
        end loop;

        E_v := S_v;

        while E_v <= L'right and L(E_v) /= ' ' and L(E_v) /= HT loop
            E_v := E_v + 1;
        end loop;

        if S_v > L'right then
            Tok := new string'("");
        else
            Tok := new string'(L(S_v to E_v - 1));
        end if;
        if E_v > L'right then
            Tmp_v := new string'("");
        else
            Tmp_v := new string'(L(E_v to L'right));
        end if;
        deallocate(L);
        L := Tmp_v;
    end procedure;

    -- Bytes of a hexadecimal token ("-": no byte)
    procedure hexBytes (
        Tok : inout line;
        B   : inout BytesPtr_t) is
        variable N_v : natural;
    begin
        if Tok.all = "-" then
            B := new TbBytes_t(0 to -1);
            return;
        end if;
        N_v := Tok'length / 2;
        B   := new TbBytes_t(0 to N_v - 1);

        for i in 0 to N_v - 1 loop
            B(i) := std_logic_vector(to_unsigned(16 * hexVal(Tok(Tok'left + 2 * i)) +
                                                 hexVal(Tok(Tok'left + 2 * i + 1)), 8));
        end loop;

    end procedure;

    -- Vector of a hexadecimal token, left-aligned in Width bits
    procedure hexVec (
        Tok   : inout line;
        Width : natural;
        V     : out std_logic_vector;
        Bits  : out natural) is
        variable R_v : std_logic_vector(Width - 1 downto 0) := (others => '0');
        variable N_v : natural;
    begin
        N_v := Tok'length;
        if Tok.all = "-" then
            N_v := 0;
        end if;
        assert 4 * N_v <= Width
            report "ocr_tb_vec_pkg: hex value too long: " & Tok.all
            severity failure;

        for i in 0 to N_v - 1 loop
            R_v(Width - 1 - 4 * i downto Width - 4 - 4 * i) := std_logic_vector(to_unsigned(hexVal(Tok(Tok'left + i)), 4));
        end loop;

        V    := R_v;
        Bits := 4 * N_v;
    end procedure;

    procedure decNat (
        Tok : inout line;
        N   : out natural) is
        variable R_v : natural := 0;
    begin

        for i in Tok'range loop
            R_v := 10 * R_v + hexVal(Tok(i));
        end loop;

        N := R_v;
    end procedure;

    procedure hexNat (
        Tok : inout line;
        N   : out natural) is
        variable R_v : natural := 0;
    begin

        for i in Tok'range loop
            R_v := 16 * R_v + hexVal(Tok(i));
        end loop;

        N := R_v;
    end procedure;

    type VecStore_t is protected body

        type SetMsgArr_t is array (0 to TbSets_c - 1) of MsgArrPtr_t;

        type SetKeyArr_t is array (0 to TbSets_c - 1) of KeyArrPtr_t;

        type SetEcbArr_t is array (0 to TbSets_c - 1) of EcbArrPtr_t;

        type SetNat_t is array (0 to TbSets_c - 1) of natural;

        type ChNat_t is array (0 to TbSets_c - 1, 0 to TbChannels_c - 1) of natural;

        type ChReal_t is array (0 to TbSets_c - 1, 0 to TbChannels_c - 1) of real;

        type ChBool_t is array (0 to TbSets_c - 1, 0 to TbChannels_c - 1) of boolean;

        type ChTime_t is array (0 to TbSets_c - 1, 0 to TbChannels_c - 1) of time;

        variable Msgs_v   : SetMsgArr_t;
        variable NMsg_v   : SetNat_t := (others => 0);
        variable Keys_v   : SetKeyArr_t;
        variable NKey_v   : SetNat_t := (others => 0);
        variable Ecbs_v   : SetEcbArr_t;
        variable NEcb_v   : SetNat_t := (others => 0);
        variable Cursor_v : ChNat_t  := (others => (others => 0));
        variable Limit_v  : ChNat_t  := (others => (others => 0));
        variable Stall_v  : ChReal_t := (others => (others => 0.0));
        variable Skip_v   : ChBool_t := (others => (others => false));
        variable Abort_v  : ChBool_t := (others => (others => false));
        variable Beats_v  : ChNat_t  := (others => (others => 0));
        variable Gaps_v   : ChNat_t  := (others => (others => 0));
        variable First_v  : ChTime_t := (others => (others => 0 ns));
        variable Last_v   : ChTime_t := (others => (others => 0 ns));

        procedure addMsg (
            set : natural;
            M   : inout MsgPtr_t) is
            variable New_v : MsgArrPtr_t;
        begin
            if Msgs_v(set) = null then
                Msgs_v(set) := new MsgArr_t(0 to 63);
            elsif NMsg_v(set) > Msgs_v(set)'high then
                New_v := new MsgArr_t(0 to 2 * Msgs_v(set)'length - 1);

                for i in Msgs_v(set)'range loop
                    New_v(i) := Msgs_v(set)(i);
                end loop;

                deallocate(Msgs_v(set));
                Msgs_v(set) := New_v;
            end if;
            Msgs_v(set)(NMsg_v(set)) := M;
            NMsg_v(set)              := NMsg_v(set) + 1;
        end procedure;

        procedure addKey (
            set : natural;
            K   : Key_t) is
            variable New_v : KeyArrPtr_t;
        begin
            if Keys_v(set) = null then
                Keys_v(set) := new KeyArr_t(0 to 63);
            elsif NKey_v(set) > Keys_v(set)'high then
                New_v := new KeyArr_t(0 to 2 * Keys_v(set)'length - 1);

                for i in Keys_v(set)'range loop
                    New_v(i) := Keys_v(set)(i);
                end loop;

                deallocate(Keys_v(set));
                Keys_v(set) := New_v;
            end if;
            Keys_v(set)(NKey_v(set)) := K;
            NKey_v(set)              := NKey_v(set) + 1;
        end procedure;

        procedure addEcb (
            set : natural;
            E   : Ecb_t) is
            variable New_v : EcbArrPtr_t;
        begin
            if Ecbs_v(set) = null then
                Ecbs_v(set) := new EcbArr_t(0 to 255);
            elsif NEcb_v(set) > Ecbs_v(set)'high then
                New_v := new EcbArr_t(0 to 2 * Ecbs_v(set)'length - 1);

                for i in Ecbs_v(set)'range loop
                    New_v(i) := Ecbs_v(set)(i);
                end loop;

                deallocate(Ecbs_v(set));
                Ecbs_v(set) := New_v;
            end if;
            Ecbs_v(set)(NEcb_v(set)) := E;
            NEcb_v(set)              := NEcb_v(set) + 1;
        end procedure;

        procedure load (
            set      : natural;
            fileName : string) is
            file F_v : text;

            variable Status_v : file_open_status;
            variable L_v      : line;
            variable Tok_v    : line;
            variable M_v      : MsgPtr_t;
            variable K_v      : Key_t;
            variable E_v      : Ecb_t;
            variable N_v      : natural;
            variable Bits_v   : natural;
            variable V_v      : std_logic_vector(255 downto 0);
            variable B_v      : BytesPtr_t;
        begin
            NMsg_v(set) := 0;
            NKey_v(set) := 0;
            NEcb_v(set) := 0;

            for ch in 0 to TbChannels_c - 1 loop
                Cursor_v(set, ch) := 0;
                Limit_v(set, ch)  := 0;
            end loop;

            file_open(Status_v, F_v, fileName, read_mode);
            assert Status_v = open_ok
                report "ocr_tb_vec_pkg: cannot open " & fileName
                severity failure;

            while not endfile(F_v) loop
                readline(F_v, L_v);
                getToken(L_v, Tok_v);
                if Tok_v.all = "ECB" then
                    getToken(L_v, Tok_v);
                    hexVec(Tok_v, 256, V_v, Bits_v);
                    E_v.Key  := V_v;
                    E_v.Bits := Bits_v;
                    getToken(L_v, Tok_v);
                    hexVec(Tok_v, 128, E_v.Din, Bits_v);
                    getToken(L_v, Tok_v);
                    hexVec(Tok_v, 128, E_v.Dout, Bits_v);
                    addEcb(set, E_v);
                elsif Tok_v.all = "KEY" then
                    getToken(L_v, Tok_v);
                    decNat(Tok_v, K_v.Slot);
                    getToken(L_v, Tok_v);
                    hexVec(Tok_v, 256, V_v, Bits_v);
                    K_v.Key   := V_v;
                    K_v.Bits  := Bits_v;
                    getToken(L_v, Tok_v);
                    hexVec(Tok_v, 128, K_v.H, Bits_v);
                    getToken(L_v, Tok_v);
                    K_v.IvGen := Tok_v.all = "1";
                    getToken(L_v, Tok_v);
                    hexVec(Tok_v, 32, K_v.Fixed, Bits_v);
                    getToken(L_v, Tok_v);
                    hexVec(Tok_v, 64, K_v.Counter, Bits_v);
                    addKey(set, K_v);
                elsif Tok_v.all = "MSG" then
                    M_v         := new Msg_t;
                    M_v.NIn     := 0;
                    M_v.NOut    := 0;
                    getToken(L_v, Tok_v);
                    M_v.Dec     := Tok_v.all = "1";
                    getToken(L_v, Tok_v);
                    decNat(Tok_v, M_v.Slot);
                    getToken(L_v, Tok_v);
                    M_v.IvGen   := Tok_v.all = "1";
                    getToken(L_v, Tok_v);
                    hexVec(Tok_v, 96, M_v.Iv, Bits_v);
                    getToken(L_v, Tok_v);
                    hexNat(Tok_v, M_v.Flags);
                    M_v.GhValid := false;
                    M_v.GhS     := (others => '0');
                elsif Tok_v.all = "IN" or Tok_v.all = "OUT" then
                    if Tok_v.all = "IN" then
                        N_v := 0;
                    else
                        N_v := 1;
                    end if;
                    getToken(L_v, Tok_v);
                    if N_v = 0 then
                        M_v.InSec(M_v.NIn).Code := Tok_v(Tok_v'left);
                    else
                        M_v.OutSec(M_v.NOut).Code := Tok_v(Tok_v'left);
                    end if;
                    getToken(L_v, Tok_v);
                    hexBytes(Tok_v, B_v);
                    if N_v = 0 then
                        M_v.InSec(M_v.NIn).Data := B_v;
                        M_v.NIn                 := M_v.NIn + 1;
                    else
                        M_v.OutSec(M_v.NOut).Data := B_v;
                        M_v.NOut                  := M_v.NOut + 1;
                    end if;
                elsif Tok_v.all = "GH" then
                    getToken(L_v, Tok_v);
                    hexVec(Tok_v, 128, M_v.GhS, Bits_v);
                    M_v.GhValid := true;
                elsif Tok_v.all = "STS" then
                    getToken(L_v, Tok_v);
                    decNat(Tok_v, M_v.StsCode);
                    getToken(L_v, Tok_v);
                    decNat(Tok_v, M_v.StsAad);
                    getToken(L_v, Tok_v);
                    decNat(Tok_v, M_v.StsData);
                    getToken(L_v, Tok_v);
                    hexVec(Tok_v, 96, M_v.StsIv, Bits_v);
                elsif Tok_v.all = "END" then
                    addMsg(set, M_v);
                end if;
                deallocate(L_v);
            end loop;

            file_close(F_v);
        end procedure;

        -- AES examples ------------------------------------------------------------------------------
        impure function ecbCount (set : natural) return natural is
        begin
            return NEcb_v(set);
        end function;

        impure function ecbKeyBits (
            set : natural;
            e   : natural) return natural is
        begin
            return Ecbs_v(set)(e).Bits;
        end function;

        impure function ecbKey (
            set : natural;
            e   : natural) return std_logic_vector is
        begin
            return Ecbs_v(set)(e).Key;
        end function;

        impure function ecbIn (
            set : natural;
            e   : natural) return std_logic_vector is
        begin
            return Ecbs_v(set)(e).Din;
        end function;

        impure function ecbOut (
            set : natural;
            e   : natural) return std_logic_vector is
        begin
            return Ecbs_v(set)(e).Dout;
        end function;

        -- Key slots ---------------------------------------------------------------------------------
        impure function keyCount (set : natural) return natural is
        begin
            return NKey_v(set);
        end function;

        impure function keySlot (
            set : natural;
            k   : natural) return natural is
        begin
            return Keys_v(set)(k).Slot;
        end function;

        impure function keyBits (
            set : natural;
            k   : natural) return natural is
        begin
            return Keys_v(set)(k).Bits;
        end function;

        impure function keyValue (
            set : natural;
            k   : natural) return std_logic_vector is
        begin
            return Keys_v(set)(k).Key;
        end function;

        impure function keyHash (
            set : natural;
            k   : natural) return std_logic_vector is
        begin
            return Keys_v(set)(k).H;
        end function;

        impure function keyIvGen (
            set : natural;
            k   : natural) return boolean is
        begin
            return Keys_v(set)(k).IvGen;
        end function;

        impure function keyFixed (
            set : natural;
            k   : natural) return std_logic_vector is
        begin
            return Keys_v(set)(k).Fixed;
        end function;

        impure function keyCounter (
            set : natural;
            k   : natural) return std_logic_vector is
        begin
            return Keys_v(set)(k).Counter;
        end function;

        impure function keyOfSlot (
            set  : natural;
            slot : natural) return natural is
            variable R_v : natural := 0;
        begin

            for k in 0 to NKey_v(set) - 1 loop
                if Keys_v(set)(k).Slot = slot then
                    R_v := k;
                end if;
            end loop;

            return R_v;
        end function;

        -- Messages ----------------------------------------------------------------------------------
        impure function msgCount (set : natural) return natural is
        begin
            return NMsg_v(set);
        end function;

        impure function msgDec (
            set : natural;
            m   : natural) return boolean is
        begin
            return Msgs_v(set)(m).Dec;
        end function;

        impure function msgSlot (
            set : natural;
            m   : natural) return natural is
        begin
            return Msgs_v(set)(m).Slot;
        end function;

        impure function msgIvGen (
            set : natural;
            m   : natural) return boolean is
        begin
            return Msgs_v(set)(m).IvGen;
        end function;

        impure function msgIv (
            set : natural;
            m   : natural) return std_logic_vector is
        begin
            return Msgs_v(set)(m).Iv;
        end function;

        impure function msgFlags (
            set : natural;
            m   : natural) return natural is
        begin
            return Msgs_v(set)(m).Flags;
        end function;

        impure function inCount (
            set : natural;
            m   : natural) return natural is
        begin
            return Msgs_v(set)(m).NIn;
        end function;

        impure function inCode (
            set : natural;
            m   : natural;
            s   : natural) return character is
        begin
            return Msgs_v(set)(m).InSec(s).Code;
        end function;

        impure function inLen (
            set : natural;
            m   : natural;
            s   : natural) return natural is
        begin
            return Msgs_v(set)(m).InSec(s).Data'length;
        end function;

        impure function inByte (
            set : natural;
            m   : natural;
            s   : natural;
            i   : natural) return std_logic_vector is
        begin
            return Msgs_v(set)(m).InSec(s).Data(i);
        end function;

        impure function outCount (
            set : natural;
            m   : natural) return natural is
        begin
            return Msgs_v(set)(m).NOut;
        end function;

        impure function outCode (
            set : natural;
            m   : natural;
            s   : natural) return character is
        begin
            return Msgs_v(set)(m).OutSec(s).Code;
        end function;

        impure function outLen (
            set : natural;
            m   : natural;
            s   : natural) return natural is
        begin
            return Msgs_v(set)(m).OutSec(s).Data'length;
        end function;

        impure function outByte (
            set : natural;
            m   : natural;
            s   : natural;
            i   : natural) return std_logic_vector is
        begin
            return Msgs_v(set)(m).OutSec(s).Data(i);
        end function;

        impure function stsCode (
            set : natural;
            m   : natural) return natural is
        begin
            return Msgs_v(set)(m).StsCode;
        end function;

        impure function stsAad (
            set : natural;
            m   : natural) return natural is
        begin
            return Msgs_v(set)(m).StsAad;
        end function;

        impure function stsData (
            set : natural;
            m   : natural) return natural is
        begin
            return Msgs_v(set)(m).StsData;
        end function;

        impure function stsIv (
            set : natural;
            m   : natural) return std_logic_vector is
        begin
            return Msgs_v(set)(m).StsIv;
        end function;

        impure function ghValid (
            set : natural;
            m   : natural) return boolean is
        begin
            return Msgs_v(set)(m).GhValid;
        end function;

        impure function ghashValue (
            set : natural;
            m   : natural) return std_logic_vector is
        begin
            return Msgs_v(set)(m).GhS;
        end function;

        -- Model channels ----------------------------------------------------------------------------
        procedure setLimit (
            set   : natural;
            ch    : natural;
            limit : natural) is
        begin
            Limit_v(set, ch) := limit;
        end procedure;

        impure function limit (
            set : natural;
            ch  : natural) return natural is
        begin
            return Limit_v(set, ch);
        end function;

        impure function cursor (
            set : natural;
            ch  : natural) return natural is
        begin
            return Cursor_v(set, ch);
        end function;

        procedure advance (
            set : natural;
            ch  : natural) is
        begin
            Cursor_v(set, ch) := Cursor_v(set, ch) + 1;
        end procedure;

        procedure setCursor (
            set : natural;
            ch  : natural;
            pos : natural) is
        begin
            Cursor_v(set, ch) := pos;
        end procedure;

        procedure setStall (
            set  : natural;
            ch   : natural;
            prob : real) is
        begin
            Stall_v(set, ch) := prob;
        end procedure;

        impure function stall (
            set : natural;
            ch  : natural) return real is
        begin
            return Stall_v(set, ch);
        end function;

        procedure setSkipFailed (
            set  : natural;
            ch   : natural;
            skip : boolean) is
        begin
            Skip_v(set, ch) := skip;
        end procedure;

        impure function skipFailed (
            set : natural;
            ch  : natural) return boolean is
        begin
            return Skip_v(set, ch);
        end function;

        procedure setAbort (
            set : natural;
            ch  : natural) is
        begin
            Abort_v(set, ch) := true;
        end procedure;

        impure function getAbort (
            set : natural;
            ch  : natural) return boolean is
        begin
            return Abort_v(set, ch);
        end function;

        procedure clearAbort (
            set : natural;
            ch  : natural) is
        begin
            Abort_v(set, ch) := false;
        end procedure;

        procedure clearStats (
            set : natural;
            ch  : natural) is
        begin
            Beats_v(set, ch) := 0;
            Gaps_v(set, ch)  := 0;
            First_v(set, ch) := 0 ns;
            Last_v(set, ch)  := 0 ns;
        end procedure;

        procedure addBeat (
            set : natural;
            ch  : natural;
            t   : time) is
        begin
            if Beats_v(set, ch) = 0 then
                First_v(set, ch) := t;
            end if;
            Beats_v(set, ch) := Beats_v(set, ch) + 1;
            Last_v(set, ch)  := t;
        end procedure;

        procedure addGap (
            set : natural;
            ch  : natural) is
        begin
            Gaps_v(set, ch) := Gaps_v(set, ch) + 1;
        end procedure;

        impure function beats (
            set : natural;
            ch  : natural) return natural is
        begin
            return Beats_v(set, ch);
        end function;

        impure function gaps (
            set : natural;
            ch  : natural) return natural is
        begin
            return Gaps_v(set, ch);
        end function;

        impure function firstTime (
            set : natural;
            ch  : natural) return time is
        begin
            return First_v(set, ch);
        end function;

        impure function lastTime (
            set : natural;
            ch  : natural) return time is
        begin
            return Last_v(set, ch);
        end function;

    end protected body;

end package body;
