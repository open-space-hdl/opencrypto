---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Output packer of the dense output (OU-4): closes the gaps that the sections of a message leave
-- at their ends, so that the message leaves as a gapless byte stream with only its last beat partial.
--
-- Documentation: hdl/ocr_packer/docs/architecture.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_packer is
    generic (
        DataWidth_g : positive range 16 to 128 := 32 -- 16, 32, 64 or 128
    );
    port (
        -- Control
        Clk         : in    std_logic;
        Rst         : in    std_logic;
        -- Sectioned messages; TUser: section (1:0), error flag on the last beat (2)
        S_In_Valid  : in    std_logic;
        S_In_Ready  : out   std_logic;
        S_In_Data   : in    std_logic_vector(DataWidth_g - 1 downto 0);
        S_In_Keep   : in    std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        S_In_Last   : in    std_logic;
        S_In_User   : in    std_logic_vector(2 downto 0);
        -- Dense messages; TUser: section of the first byte of the beat (1:0), error flag on the last beat (2)
        M_Out_Valid : out   std_logic;
        M_Out_Ready : in    std_logic := '1';
        M_Out_Data  : out   std_logic_vector(DataWidth_g - 1 downto 0);
        M_Out_Keep  : out   std_logic_vector(DataWidth_g / 8 - 1 downto 0);
        M_Out_Last  : out   std_logic;
        M_Out_User  : out   std_logic_vector(2 downto 0)
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture rtl of ocr_packer is

    constant Bytes_c : positive := DataWidth_g / 8;

    type Bytes_t is array (0 to Bytes_c - 1) of std_logic_vector(7 downto 0);

    type TwoProcess_r is record
        -- Residual bytes of the message that do not fill a beat yet, in lanes 0 to ResCnt - 1
        Res      : Bytes_t;
        ResCnt   : natural range 0 to Bytes_c - 1;
        ResSec   : std_logic_vector(1 downto 0);
        -- The last input beat of a message left residual bytes: one more output beat with TLast
        Flush    : std_logic;
        FlushErr : std_logic;
        -- Output register
        OValid   : std_logic;
        OData    : Bytes_t;
        OKeep    : std_logic_vector(Bytes_c - 1 downto 0);
        OLast    : std_logic;
        OUser    : std_logic_vector(2 downto 0);
    end record;

    signal r, r_next : TwoProcess_r;

    -- Byte enables of the first n lanes
    function keepOf (n : natural) return std_logic_vector is
        variable K_v : std_logic_vector(Bytes_c - 1 downto 0) := (others => '0');
    begin

        for i in 0 to Bytes_c - 1 loop
            if i < n then
                K_v(i) := '1';
            end if;
        end loop;

        return K_v;
    end function;

begin

    -----------------------------------------------------------------------------------------------
    -- Combinatorial Process
    -----------------------------------------------------------------------------------------------
    p_comb : process (all) is
        variable v      : TwoProcess_r;
        variable Load_v : boolean;
        variable InB_v  : Bytes_t;
        variable Rot_v  : Bytes_t;
        variable Comb_v : Bytes_t;
        variable Cnt_v  : natural range 0 to Bytes_c;
        variable Tot_v  : natural range 0 to 2 * Bytes_c - 1;
        variable Sec_v  : std_logic_vector(1 downto 0);
    begin
        -- hold variables stable
        v := r;

        -- Output register
        if r.OValid = '1' and M_Out_Ready = '1' then
            v.OValid := '0';
        end if;
        Load_v := r.OValid = '0' or M_Out_Ready = '1';

        -- Bytes of the input beat; the valid bytes are contiguous from lane 0
        Cnt_v := 0;

        for i in 0 to Bytes_c - 1 loop
            InB_v(i) := S_In_Data(8 * i + 7 downto 8 * i);
            if S_In_Keep(i) = '1' then
                Cnt_v := Cnt_v + 1;
            end if;
        end loop;

        -- The input bytes behind the residual bytes: input byte i in lane (i + ResCnt) mod Bytes_c. The bytes that
        -- do not fit into the beat wrap around to the lanes below ResCnt and become the next residual bytes.
        for j in 0 to Bytes_c - 1 loop
            Rot_v(j) := InB_v((j - r.ResCnt + Bytes_c) mod Bytes_c);
            if j < r.ResCnt then
                Comb_v(j) := r.Res(j);
            else
                Comb_v(j) := Rot_v(j);
            end if;
        end loop;

        Tot_v := r.ResCnt + Cnt_v;
        -- Section of the first byte of the next output beat
        if r.ResCnt /= 0 then
            Sec_v := r.ResSec;
        else
            Sec_v := S_In_User(1 downto 0);
        end if;

        S_In_Ready <= '0';
        if r.Flush = '1' then
            -- Last beat of a message from the residual bytes
            if Load_v then
                v.OValid := '1';
                v.OData  := r.Res;
                v.OKeep  := keepOf(r.ResCnt);
                v.OLast  := '1';
                v.OUser  := r.FlushErr & r.ResSec;
                v.ResCnt := 0;
                v.Flush  := '0';
            end if;
        elsif Load_v then
            S_In_Ready <= '1';
            if S_In_Valid = '1' then
                if Tot_v >= Bytes_c then
                    -- A full beat; the bytes beyond it stay as residual bytes of the input section
                    v.OValid := '1';
                    v.OData  := Comb_v;
                    v.OKeep  := (others => '1');
                    v.OLast  := '0';
                    v.OUser  := '0' & Sec_v;
                    v.Res    := Rot_v;
                    v.ResCnt := Tot_v - Bytes_c;
                    v.ResSec := S_In_User(1 downto 0);
                    if S_In_Last = '1' then
                        if Tot_v = Bytes_c then
                            v.OLast    := '1';
                            v.OUser(2) := S_In_User(2);
                        else
                            v.Flush    := '1';
                            v.FlushErr := S_In_User(2);
                        end if;
                    end if;
                elsif S_In_Last = '1' then
                    -- Last beat of the message, partial (no byte for an empty message)
                    v.OValid := '1';
                    v.OData  := Comb_v;
                    v.OKeep  := keepOf(Tot_v);
                    v.OLast  := '1';
                    v.OUser  := S_In_User(2) & Sec_v;
                    v.ResCnt := 0;
                else
                    -- The bytes are kept until the beat is full
                    v.Res    := Comb_v;
                    v.ResCnt := Tot_v;
                    v.ResSec := Sec_v;
                end if;
            end if;
        end if;

        -- Outputs
        M_Out_Valid <= r.OValid;

        for i in 0 to Bytes_c - 1 loop
            M_Out_Data(8 * i + 7 downto 8 * i) <= r.OData(i);
        end loop;

        M_Out_Keep <= r.OKeep;
        M_Out_Last <= r.OLast;
        M_Out_User <= r.OUser;

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
                r.ResCnt <= 0;
                r.Flush  <= '0';
                r.OValid <= '0';
            end if;
        end if;
    end process;

end architecture;
