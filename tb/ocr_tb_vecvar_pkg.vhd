---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- The vector store shared by the models and the test sequencers, and the procedures of the test
-- sequencers that use it. The shared variable is declared in a package of its own, after the body of
-- its protected type.
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

library work;
    use work.ocr_tb_vec_pkg.all;

---------------------------------------------------------------------------------------------------
-- Package Header
---------------------------------------------------------------------------------------------------
package ocr_tb_vecvar_pkg is

    shared variable OcrVec_v : VecStore_t;

    -- Reads a vector file into a set; the models of the set process nothing until tbStart
    procedure tbLoad (
        set      : natural;
        fileName : string);

    -- Lets the models of the given channels process the messages (or AES examples) up to (excluding) index last;
    -- last = natural'high processes all messages of the set
    procedure tbStart (
        set      : natural;
        channels : std_logic_vector(TbChannels_c - 1 downto 0);
        last     : natural := natural'high);

    -- Waits until the model of a channel has processed all messages up to its limit; alert on timeout
    procedure tbWaitDone (
        set     : natural;
        ch      : natural;
        timeout : time;
        msg     : string := "");

    -- Probability of a cycle without valid (sources) or ready (sinks) of a channel
    procedure tbSetStall (
        set  : natural;
        ch   : natural;
        prob : real);

    -- Expected number of beats per message of a section of len bytes on a stream of bytes bytes per beat
    function tbBeats (
        len   : natural;
        bytes : positive) return natural;

end package;

---------------------------------------------------------------------------------------------------
-- Package Body
---------------------------------------------------------------------------------------------------
package body ocr_tb_vecvar_pkg is

    procedure tbLoad (
        set      : natural;
        fileName : string) is
    begin
        OcrVec_v.load(set, fileName);
        log(ID_SEQUENCER, "vector set " & to_string(set) & ": " & to_string(OcrVec_v.msgCount(set)) &
            " messages, " & to_string(OcrVec_v.keyCount(set)) & " keys, " & to_string(OcrVec_v.ecbCount(set)) &
            " blocks from " & fileName, "ocr_tb_vecvar_pkg");
    end procedure;

    procedure tbStart (
        set      : natural;
        channels : std_logic_vector(TbChannels_c - 1 downto 0);
        last     : natural := natural'high) is
        variable Last_v : natural;
    begin
        -- A set holds messages or AES examples
        Last_v := last;
        if Last_v > maximum(OcrVec_v.msgCount(set), OcrVec_v.ecbCount(set)) then
            Last_v := maximum(OcrVec_v.msgCount(set), OcrVec_v.ecbCount(set));
        end if;

        for ch in 0 to TbChannels_c - 1 loop
            if channels(ch) = '1' then
                OcrVec_v.setLimit(set, ch, Last_v);
            end if;
        end loop;

    end procedure;

    procedure tbWaitDone (
        set     : natural;
        ch      : natural;
        timeout : time;
        msg     : string := "") is
        constant Step_c   : time := 100 ns;
        variable Waited_v : time := 0 ns;
    begin

        while OcrVec_v.cursor(set, ch) < OcrVec_v.limit(set, ch) loop
            if Waited_v >= timeout then
                alert(ERROR, "timeout: set " & to_string(set) & " channel " & to_string(ch) & " processed " &
                      to_string(OcrVec_v.cursor(set, ch)) & " of " & to_string(OcrVec_v.limit(set, ch)) &
                      " messages " & msg, "tbWaitDone");
                return;
            end if;
            wait for Step_c;
            Waited_v := Waited_v + Step_c;
        end loop;

    end procedure;

    procedure tbSetStall (
        set  : natural;
        ch   : natural;
        prob : real) is
    begin
        OcrVec_v.setStall(set, ch, prob);
    end procedure;

    function tbBeats (
        len   : natural;
        bytes : positive) return natural is
    begin
        if len = 0 then
            return 1;
        end if;
        return (len + bytes - 1) / bytes;
    end function;

end package body;
