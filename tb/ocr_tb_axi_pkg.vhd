---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Register access of the testbenches through the AXI-Lite VVC of UVVM: write, check and read of a
-- register, key load of a key slot from a KEY record of a vector set, query of a key slot.
--
-- Documentation: docs/conventions.md (section Verification)

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

library bitvis_vip_axilite;
    use bitvis_vip_axilite.td_target_support_pkg.all;
    context bitvis_vip_axilite.vvc_context;

library work;
    use work.ocr_regs_pkg.all;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;

---------------------------------------------------------------------------------------------------
-- Package Header
---------------------------------------------------------------------------------------------------
package ocr_tb_axi_pkg is

    constant AxiAddrBits_c : positive := 8;

    procedure regWrite (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : std_logic_vector(31 downto 0));

    procedure regCheck (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : std_logic_vector(31 downto 0);
        msg         : string);

    procedure regRead (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : out std_logic_vector(31 downto 0));

    -- Loads the key slot of KEY record k of a vector set through the registers and waits until it is valid
    procedure regLoadKey (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        set         : natural;
        k           : natural;
        keyBits     : positive);

    -- Loads all KEY records of a vector set
    procedure regLoadAll (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        set         : natural;
        keyBits     : positive);

    -- Queries a key slot: SLOT_STATUS, SLOT_FIXED and the invocation counter
    procedure regQuery (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        slot        : natural;
        status      : out std_logic_vector(31 downto 0);
        fixed       : out std_logic_vector(31 downto 0);
        counter     : out std_logic_vector(63 downto 0));

end package;

---------------------------------------------------------------------------------------------------
-- Package Body
---------------------------------------------------------------------------------------------------
package body ocr_tb_axi_pkg is

    procedure regWrite (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : std_logic_vector(31 downto 0)) is
    begin
        axilite_write(vvct, idx, to_unsigned(addr, AxiAddrBits_c), data,
                      "write 0x" & to_hstring(to_unsigned(addr, AxiAddrBits_c)));
        await_completion(vvct, idx, 100 us);
    end procedure;

    procedure regCheck (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : std_logic_vector(31 downto 0);
        msg         : string) is
    begin
        axilite_check(vvct, idx, to_unsigned(addr, AxiAddrBits_c), data, msg);
        await_completion(vvct, idx, 100 us);
    end procedure;

    procedure regRead (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        addr        : natural;
        data        : out std_logic_vector(31 downto 0)) is
        variable Cmd_v  : natural;
        variable Data_v : bitvis_vip_axilite.vvc_cmd_pkg.t_vvc_result;
        variable Ok_v   : boolean;
    begin
        axilite_read(vvct, idx, to_unsigned(addr, AxiAddrBits_c), "read 0x" & to_hstring(to_unsigned(addr, AxiAddrBits_c)));
        Cmd_v := get_last_received_cmd_idx(vvct, idx);
        await_completion(vvct, idx, 100 us);
        fetch_result(vvct, idx, Cmd_v, Data_v, Ok_v, "fetch read result");
        data  := Data_v(31 downto 0);
    end procedure;

    procedure regLoadKey (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        set         : natural;
        k           : natural;
        keyBits     : positive) is
        variable Key_v  : std_logic_vector(255 downto 0);
        variable Cnt_v  : std_logic_vector(63 downto 0);
        variable Ctl_v  : std_logic_vector(31 downto 0) := (others => '0');
        variable Sts_v  : std_logic_vector(31 downto 0);
        variable Wait_v : natural                       := 0;
    begin
        Key_v := OcrVec_v.keyValue(set, k);

        for i in 0 to keyBits / 32 - 1 loop
            regWrite(vvct, idx, RegKeyBase_c + RegKeyStride_c * i, Key_v(255 - 32 * i downto 224 - 32 * i));
        end loop;

        Cnt_v                                         := OcrVec_v.keyCounter(set, k);
        regWrite(vvct, idx, RegIvFixed_c, OcrVec_v.keyFixed(set, k));
        regWrite(vvct, idx, RegIvCountLo_c, Cnt_v(31 downto 0));
        regWrite(vvct, idx, RegIvCountHi_c, Cnt_v(63 downto 32));
        Ctl_v(KeyLoadStart_c)                         := '1';
        Ctl_v(KeyLoadIvGen_c)                         := tbSl(OcrVec_v.keyIvGen(set, k));
        Ctl_v(KeyLoadSlotHi_c downto KeyLoadSlotLo_c) := std_logic_vector(to_unsigned(OcrVec_v.keySlot(set, k), 8));
        regWrite(vvct, idx, RegKeyLoad_c, Ctl_v);

        loop
            regRead(vvct, idx, RegStatus_c, Sts_v);
            exit when Sts_v(StatusBusy_c) = '0';
            Wait_v := Wait_v + 1;
            if Wait_v > 1000 then
                alert(ERROR, "key load does not end", "regLoadKey");
                exit;
            end if;
        end loop;

    end procedure;

    procedure regLoadAll (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        set         : natural;
        keyBits     : positive) is
    begin

        for k in 0 to OcrVec_v.keyCount(set) - 1 loop
            regLoadKey(vvct, idx, set, k, keyBits);
        end loop;

    end procedure;

    procedure regQuery (
        signal vvct : inout t_vvc_target_record;
        idx         : natural;
        slot        : natural;
        status      : out std_logic_vector(31 downto 0);
        fixed       : out std_logic_vector(31 downto 0);
        counter     : out std_logic_vector(63 downto 0)) is
        variable Sts_v : std_logic_vector(31 downto 0);
        variable Lo_v  : std_logic_vector(31 downto 0);
        variable Hi_v  : std_logic_vector(31 downto 0);
    begin
        regWrite(vvct, idx, RegSlotQuery_c, std_logic_vector(to_unsigned(slot, 32)));

        loop
            regRead(vvct, idx, RegSlotStatus_c, Sts_v);
            exit when Sts_v(SlotStatusPending_c) = '0';
        end loop;

        status  := Sts_v;
        regRead(vvct, idx, RegSlotFixed_c, fixed);
        regRead(vvct, idx, RegSlotCountLo_c, Lo_v);
        regRead(vvct, idx, RegSlotCountHi_c, Hi_v);
        counter := Hi_v & Lo_v;
    end procedure;

end package body;
