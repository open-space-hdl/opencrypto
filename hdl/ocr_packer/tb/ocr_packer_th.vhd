---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Test harness of ocr_packer: clock, the message source of vector set 0 (sectioned messages with the
-- error flag on the last beat), the packer and the message sink in dense mode.
--
-- Documentation: hdl/ocr_packer/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library work;
    use work.ocr_tb_vec_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_packer_th is
    generic (
        DataWidth_g : positive := 32
    );
    port (
        Clk : out   std_logic;
        Rst : in    std_logic
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_packer_th is

    constant ClkPeriod_c : time     := 10 ns;
    constant Bytes_c     : positive := DataWidth_g / 8;

    signal Clk_i    : std_logic := '0';
    signal InValid  : std_logic;
    signal InReady  : std_logic;
    signal InData   : std_logic_vector(DataWidth_g - 1 downto 0);
    signal InKeep   : std_logic_vector(Bytes_c - 1 downto 0);
    signal InLast   : std_logic;
    signal InUser   : std_logic_vector(1 downto 0);
    signal InErr    : std_logic;
    signal OutValid : std_logic;
    signal OutReady : std_logic;
    signal OutData  : std_logic_vector(DataWidth_g - 1 downto 0);
    signal OutKeep  : std_logic_vector(Bytes_c - 1 downto 0);
    signal OutLast  : std_logic;
    signal OutUser  : std_logic_vector(2 downto 0);

begin

    -- The clock is driven on the port, so that testbench and DUT see the same signal (no delta cycle between them)
    Clk_i <= not Clk_i after ClkPeriod_c / 2;
    Clk   <= Clk_i;

    i_source : entity work.ocr_tb_msg_source
        generic map (
            DataWidth_g => DataWidth_g
        )
        port map (
            Clk       => Clk_i,
            Out_Valid => InValid,
            Out_Ready => InReady,
            Out_Data  => InData,
            Out_Keep  => InKeep,
            Out_Last  => InLast,
            Out_User  => InUser,
            Out_Err   => InErr
        );

    i_dut : entity work.ocr_packer
        generic map (
            DataWidth_g => DataWidth_g
        )
        port map (
            Clk         => Clk_i,
            Rst         => Rst,
            S_In_Valid  => InValid,
            S_In_Ready  => InReady,
            S_In_Data   => InData,
            S_In_Keep   => InKeep,
            S_In_Last   => InLast,
            S_In_User   => InErr & InUser,
            M_Out_Valid => OutValid,
            M_Out_Ready => OutReady,
            M_Out_Data  => OutData,
            M_Out_Keep  => OutKeep,
            M_Out_Last  => OutLast,
            M_Out_User  => OutUser
        );

    i_sink : entity work.ocr_tb_msg_sink
        generic map (
            Channel_g   => ChSink_c,
            DataWidth_g => DataWidth_g,
            Dense_g     => true
        )
        port map (
            Clk      => Clk_i,
            In_Valid => OutValid,
            In_Ready => OutReady,
            In_Data  => OutData,
            In_Keep  => OutKeep,
            In_Last  => OutLast,
            In_User  => OutUser
        );

end architecture;
