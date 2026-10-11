---------------------------------------------------------------------------------------------------
-- Copyright (c) 2026 by Julian Schneider
-- Authors: Julian Schneider
---------------------------------------------------------------------------------------------------

---------------------------------------------------------------------------------------------------
-- Description
---------------------------------------------------------------------------------------------------
-- Testbench of ocr_gcm: GCM-AE and GCM-AD against the test cases of the GCM specification and
-- pycryptodome, failed verifications, generated IVs, throughput on the bottleneck side, format errors,
-- rejected jobs, length errors, error injection into every FT buffer, hash subkey requests, release
-- buffer and reset.
--
-- Documentation: hdl/ocr_gcm/docs/verification_plan.md

---------------------------------------------------------------------------------------------------
-- Libraries
---------------------------------------------------------------------------------------------------
library ieee;
    use ieee.std_logic_1164.all;
    use ieee.numeric_std.all;

library uvvm_util;
    context uvvm_util.uvvm_util_context;

library vunit_lib;
    context vunit_lib.vunit_context;

library work;
    use work.ocr_pkg.all;
    use work.ocr_gcm_pkg.all;
    use work.ocr_tb_pkg.all;
    use work.ocr_tb_vec_pkg.all;
    use work.ocr_tb_vecvar_pkg.all;

---------------------------------------------------------------------------------------------------
-- Entity
---------------------------------------------------------------------------------------------------
entity ocr_gcm_tb is
    generic (
        runner_cfg      : string;
        DataWidth_g     : positive := 32;
        KeyBits_g       : positive := 256;
        AesUnits_g      : natural  := 0;
        GhashDigit_g    : natural  := 0;
        LenBits_g       : positive := 32;
        ReleaseBuffer_g : boolean  := false;
        ReleaseBytes_g  : positive := 4096;
        VecDir_g        : string
    );
end entity;

---------------------------------------------------------------------------------------------------
-- Architecture
---------------------------------------------------------------------------------------------------
architecture sim of ocr_gcm_tb is

    constant ClkPeriod_c : time := 10 ns;
    -- Message source, job source, message sink, status sink
    constant All_c       : std_logic_vector(TbChannels_c - 1 downto 0) := x"0F";
    -- Gaps on the bottleneck side allowed for the initial latency, independent of the number of messages
    constant MaxGaps_c   : natural := 40;

    signal Clk            : std_logic;
    signal Rst            : std_logic                                := '1';
    signal Aux_InValid    : std_logic                                := '0';
    signal Aux_InReady    : std_logic;
    signal Aux_InKey      : std_logic_vector(KeyBits_g - 1 downto 0) := (others => '0');
    signal Aux_OutValid   : std_logic;
    signal Aux_OutReady   : std_logic                                := '1';
    signal Aux_OutBlock   : Block_t;
    signal ErrInj_Sel     : std_logic_vector(3 downto 0)             := (others => '0');
    signal ErrInj_BitFlip : std_logic_vector(1 downto 0)             := (others => '0');
    signal ErrInj_Valid   : std_logic                                := '0';
    signal Ecc_Sec        : std_logic_vector(GcmEccBuffers_c - 1 downto 0);
    signal Ecc_Ded        : std_logic_vector(GcmEccBuffers_c - 1 downto 0);

    type CntArr_t is array (0 to GcmEccBuffers_c - 1) of natural;

    signal SecCnt : CntArr_t := (others => 0);
    signal DedCnt : CntArr_t := (others => 0);

begin

    test_runner_watchdog(runner, 50 ms);

    -- ECC events per buffer
    p_ecc : process (Clk) is
    begin
        if rising_edge(Clk) then

            for b in 0 to GcmEccBuffers_c - 1 loop
                if Ecc_Sec(b) = '1' then
                    SecCnt(b) <= SecCnt(b) + 1;
                end if;
                if Ecc_Ded(b) = '1' then
                    DedCnt(b) <= DedCnt(b) + 1;
                end if;
            end loop;

        end if;
    end process;

    p_main : process is
        variable N_v    : natural;
        variable M_v    : natural;
        variable K_v    : std_logic_vector(255 downto 0);
        variable Sec0_v : natural;
        variable Ded0_v : natural;
        variable Bufs_v : natural;

        -- Runs all messages of a vector file with the given stall probability on every model
        procedure runSet (
            name  : string;
            stall : real;
            time  : time := 10 ms) is
        begin
            tbLoad(0, VecDir_g & "/" & name);

            for ch in 0 to 3 loop
                tbSetStall(0, ch, stall);
                OcrVec_v.clearStats(0, ch);
            end loop;

            OcrVec_v.setSkipFailed(0, ChSink_c, ReleaseBuffer_g);
            tbStart(0, All_c);
            tbWaitDone(0, ChSink_c, time, name);
            tbWaitDone(0, ChSts_c, time, name);
            N_v := OcrVec_v.msgCount(0);
            check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "messages checked at the output of " & name);
            check_value(OcrVec_v.cursor(0, ChSts_c), N_v, ERROR, "status checked of " & name);
        end procedure;

        -- The sequencer acts 1 ns after the clock edge, after the models
        procedure syncClk is
        begin
            wait until rising_edge(Clk);
            wait for 1 ns;
        end procedure;

    -- Test sequence
    begin
        test_runner_setup(runner, runner_cfg);
        disable_log_msg(ID_POS_ACK);
        wait for 5 * ClkPeriod_c;
        syncClk;
        Rst <= '0';
        syncClk;

        while test_suite loop

            if run("test_gcm_spec") then
                -- Test cases of the GCM specification of the key length (GCM 7.1, 7.2)
                runSet("spec_enc.txt", 0.0);
                runSet("spec_dec.txt", 0.0);

            elsif run("test_encrypt") then
                -- GCM-AE of random messages: absent, empty, partial and full sections, random stalls
                runSet("enc.txt", 0.3);

            elsif run("test_decrypt") then
                -- GCM-AD of random messages with correct tags
                runSet("dec.txt", 0.3);

            elsif run("test_mixed") then
                -- Both directions per message; modified tags, AAD and ciphertexts fail with AUTH
                runSet("mixed.txt", 0.2);

            elsif run("test_iv_section") then
                -- Generated IVs: the IV section precedes the AAD of the output
                runSet("ivgen.txt", 0.2);

            elsif run("test_throughput_encrypt") then
                -- Back-to-back encryptions: the output (bottleneck side) transfers a beat in every cycle
                runSet("tp_enc.txt", 0.0);
                log(ID_SEQUENCER, "output beats " & to_string(OcrVec_v.beats(0, ChSink_c)) & ", gaps " &
                    to_string(OcrVec_v.gaps(0, ChSink_c)));
                check_value(OcrVec_v.gaps(0, ChSink_c) <= MaxGaps_c, ERROR, "cycles without output beat");

            elsif run("test_throughput_decrypt") then
                -- Back-to-back decryptions: the input (bottleneck side) accepts a beat in every cycle
                runSet("tp_dec.txt", 0.0);
                log(ID_SEQUENCER, "input beats " & to_string(OcrVec_v.beats(0, ChSource_c)) & ", gaps " &
                    to_string(OcrVec_v.gaps(0, ChSource_c)));
                check_value(OcrVec_v.gaps(0, ChSource_c) <= MaxGaps_c, ERROR, "cycles without input beat");

            elsif run("test_format") then
                -- Format errors: FORMAT, error flag; the next message is processed correctly
                runSet("format.txt", 0.1);

            elsif run("test_reject") then
                -- Jobs with a context error: the message is consumed, one empty beat with the error flag
                runSet("reject.txt", 0.1);

            elsif run("test_length") then
                -- Sections longer than 2^LenBits_g - 1 bytes: LENGTH, tag of an encryption zeros
                runSet("length.txt", 0.1);

            elsif run("test_release") then
                -- Release buffer: only messages with status OK leave the core; too long ones are OVERFLOW
                runSet("release_" & to_string(ReleaseBytes_g) & ".txt", 0.2);

            elsif run("test_ecc") then
                -- Single and double errors injected into the next entry of every FT buffer, one message at a time
                if ReleaseBuffer_g then
                    tbLoad(0, VecDir_g & "/ecc_rel.txt");
                else
                    tbLoad(0, VecDir_g & "/ecc.txt");
                end if;
                OcrVec_v.setSkipFailed(0, ChSink_c, ReleaseBuffer_g);
                N_v    := OcrVec_v.msgCount(0);
                Bufs_v := N_v / 4;

                for m in 0 to N_v - 1 loop
                    ErrInj_Sel     <= std_logic_vector(to_unsigned(m / 4, 4));
                    ErrInj_BitFlip <= "01" when m mod 2 = 0 else "11";
                    ErrInj_Valid   <= '1';
                    syncClk;
                    ErrInj_Valid   <= '0';
                    Sec0_v         := SecCnt(m / 4);
                    Ded0_v         := DedCnt(m / 4);
                    tbStart(0, All_c, m + 1);
                    tbWaitDone(0, ChSink_c, 1 ms, "message " & to_string(m));
                    tbWaitDone(0, ChSts_c, 1 ms, "status " & to_string(m));

                    for i in 0 to 50 loop
                        syncClk;
                    end loop;

                    if m mod 2 = 0 then
                        check_value(SecCnt(m / 4), Sec0_v + 1, ERROR, "SEC event of buffer " & to_string(m / 4));
                    else
                        check_value(DedCnt(m / 4), Ded0_v + 1, ERROR, "DED event of buffer " & to_string(m / 4));
                    end if;
                end loop;

                if ReleaseBuffer_g then
                    check_value(Bufs_v, 11, ERROR, "buffers tested");
                else
                    check_value(Bufs_v, 10, ERROR, "buffers tested");
                end if;

            elsif run("test_hash_subkey") then
                -- Hash subkey requests (key load of the key table) while random messages pass
                tbLoad(0, VecDir_g & "/mixed.txt");
                tbStart(0, All_c);

                for k in 0 to 39 loop
                    M_v         := k mod OcrVec_v.keyCount(0);
                    K_v         := OcrVec_v.keyValue(0, M_v);
                    Aux_InKey   <= K_v(255 downto 256 - KeyBits_g);
                    Aux_InValid <= '1';

                    loop
                        wait until rising_edge(Clk);
                        exit when Aux_InReady = '1';
                    end loop;

                    wait for 1 ns;
                    Aux_InValid <= '0';

                    -- Every second result is taken only some cycles after it is valid
                    if k mod 2 = 1 then
                        Aux_OutReady <= '0';
                    end if;

                    loop
                        wait until rising_edge(Clk);
                        exit when Aux_OutValid = '1';
                    end loop;

                    -- GCM 7.1 step 1
                    check_value(Aux_OutBlock, OcrVec_v.keyHash(0, M_v), ERROR, "hash subkey of key " & to_string(M_v));
                    if k mod 2 = 1 then

                        for i in 0 to 4 loop
                            syncClk;
                        end loop;

                        check_value(Aux_OutValid, '1', ERROR, "hash subkey result held");
                        check_value(Aux_OutBlock, OcrVec_v.keyHash(0, M_v), ERROR, "held hash subkey");
                        Aux_OutReady <= '1';
                        wait until rising_edge(Clk);
                        wait for 1 ns;
                        check_value(Aux_OutValid, '0', ERROR, "hash subkey result taken once");
                    end if;

                    for i in 0 to 7 * k mod 23 loop
                        syncClk;
                    end loop;

                end loop;

                tbWaitDone(0, ChSink_c, 10 ms, "mixed messages");
                tbWaitDone(0, ChSts_c, 10 ms, "mixed messages");

            elsif run("test_backlog") then
                -- 200 one-beat encryptions and 200 short messages of every kind without stall cycles, then the short
                -- messages with a sink and a status sink that are rarely ready and with a status sink that is almost
                -- never ready: the buffers inside the data path fill and every message is still correct
                runSet("tiny.txt", 0.0);
                runSet("backlog.txt", 0.0);
                tbLoad(0, VecDir_g & "/backlog.txt");

                for ch in 0 to 3 loop
                    tbSetStall(0, ch, 0.0);
                    OcrVec_v.clearStats(0, ch);
                end loop;

                tbSetStall(0, ChSink_c, 0.95);
                tbSetStall(0, ChSts_c, 0.97);
                tbStart(0, All_c);
                tbWaitDone(0, ChSink_c, 20 ms, "backlog");
                tbWaitDone(0, ChSts_c, 20 ms, "backlog");
                check_value(OcrVec_v.cursor(0, ChSink_c), OcrVec_v.msgCount(0), ERROR, "messages of the backlog");
                check_value(OcrVec_v.cursor(0, ChSts_c), OcrVec_v.msgCount(0), ERROR, "status of the backlog");
                tbLoad(0, VecDir_g & "/backlog.txt");

                for ch in 0 to 3 loop
                    tbSetStall(0, ch, 0.0);
                    OcrVec_v.clearStats(0, ch);
                end loop;

                tbSetStall(0, ChSts_c, 0.99);
                tbStart(0, All_c);
                tbWaitDone(0, ChSink_c, 20 ms, "backlog of the status");
                tbWaitDone(0, ChSts_c, 20 ms, "backlog of the status");
                check_value(OcrVec_v.cursor(0, ChSts_c), OcrVec_v.msgCount(0), ERROR, "status of the status backlog");

            elsif run("test_reset") then
                -- A reset while messages are in the core; afterwards all messages from the next one on are correct
                tbLoad(0, VecDir_g & "/mixed.txt");
                N_v := OcrVec_v.msgCount(0);
                tbStart(0, All_c);

                for i in 0 to 400 loop
                    syncClk;
                end loop;

                for ch in 0 to 3 loop
                    OcrVec_v.setLimit(0, ch, OcrVec_v.cursor(0, ch) + 1);
                    OcrVec_v.setAbort(0, ch);
                end loop;

                Rst <= '1';
                syncClk;
                syncClk;
                Rst <= '0';

                for i in 0 to 100 loop
                    syncClk;
                end loop;

                M_v := OcrVec_v.cursor(0, ChSource_c);

                for ch in 0 to 3 loop
                    OcrVec_v.setCursor(0, ch, M_v);
                    OcrVec_v.clearAbort(0, ch);
                end loop;

                tbStart(0, All_c);
                tbWaitDone(0, ChSink_c, 10 ms, "messages after the reset");
                tbWaitDone(0, ChSts_c, 10 ms, "messages after the reset");
                check_value(OcrVec_v.cursor(0, ChSink_c), N_v, ERROR, "messages after the reset");
            end if;

        end loop;

        ocrTestEnd(runner);
        wait;
    end process;

    i_th : entity work.ocr_gcm_th
        generic map (
            DataWidth_g     => DataWidth_g,
            KeyBits_g       => KeyBits_g,
            AesUnits_g      => AesUnits_g,
            GhashDigit_g    => GhashDigit_g,
            LenBits_g       => LenBits_g,
            ReleaseBuffer_g => ReleaseBuffer_g,
            ReleaseBytes_g  => ReleaseBytes_g
        )
        port map (
            Clk            => Clk,
            Rst            => Rst,
            Aux_InValid    => Aux_InValid,
            Aux_InReady    => Aux_InReady,
            Aux_InKey      => Aux_InKey,
            Aux_OutValid   => Aux_OutValid,
            Aux_OutReady   => Aux_OutReady,
            Aux_OutBlock   => Aux_OutBlock,
            ErrInj_Sel     => ErrInj_Sel,
            ErrInj_BitFlip => ErrInj_BitFlip,
            ErrInj_Valid   => ErrInj_Valid,
            Ecc_Sec        => Ecc_Sec,
            Ecc_Ded        => Ecc_Ded
        );

end architecture;
