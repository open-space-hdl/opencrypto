# ocr_core: Verification Plan

## 1. Overview

The core tests cross the seams between the modules: every key is loaded through the AXI4-Lite port, every message
passes the key table, the data path and the register file, and every check observes only the ports of the core.
The harness drives the contexts and messages of a vector file into core A and checks every output byte and every
status against the AES-GCM of pycryptodome. In the series configuration a second core B decrypts the output of core
A, so the far end of the encryption is an independent instance and the result is checked against the plaintext of
the vector file.

## 2. Test configuration

| Testbench | Harness | DUT and environment |
| --- | --- | --- |
| `ocr_core_tb` | `ocr_core_th` | `ocr_core` at 100 MHz with free-running scrubbers; context source, message source, message sink and status sink of vector set 0; UVVM AXI4-Lite VVC; with `Series_g` a second core B with its own VVC, context source, message sink and status sink |

| Configuration | Width | Key | Slots | Other generics | Tests |
| --- | --- | --- | --- | --- | --- |
| `w32_k256_n4` | 32 | 256 | 4 | defaults | TC-CO-01 to TC-CO-12 |
| `w128_k256_n4` | 128 | 256 | 4 | defaults | TC-CO-01 to TC-CO-12, TC-CO-14 |
| `w16_k128_n2` | 16 | 128 | 2 | defaults | TC-CO-01, 03 to 05, 10, 11 |
| `w64_k192_n8` | 64 | 192 | 8 | defaults | TC-CO-01, 03 to 05, 10, 11, 14 |
| `w32_k256_n4_rel` | 32 | 256 | 4 | release buffer of 512 bytes | TC-CO-01, 03, 10, 11, 15 |
| `w64_k256_n4_series` | 64 | 256 | 4 | two cores in series | TC-CO-13 |
| `w32_k256_n4_dense` | 32 | 256 | 4 | dense output | TC-CO-01, 03 to 05, 07, 10 to 12 |
| `w128_k256_n4_dense` | 128 | 256 | 4 | dense output | TC-CO-01, 03 to 05, 10 to 12, 14 |
| `w16_k128_n2_dense` | 16 | 128 | 2 | dense output | TC-CO-01, 03 to 05, 10, 11 |
| `w64_k192_n8_dense_rel` | 64 | 192 | 8 | dense output, release buffer of 512 bytes | TC-CO-01, 03, 10, 11, 15 |
| `w128_k256_n4_dense_rel8k` | 128 | 256 | 4 | dense output, release buffer of 8192 bytes | TC-CO-16 |
| `w128_k256_n4_dense_rel16k` | 128 | 256 | 4 | dense output, release buffer of 16384 bytes | TC-CO-16 |

Vector files per key length and number of slots: 120 messages of both directions on up to three slots with 30 % modified
tags, AAD or ciphertexts; 60 encryptions with generated IVs; the context errors between correct messages; 8 messages
after a zeroize; the error injection messages of the data path and of the key table; 120 encryptions and 120 decryptions
for the throughput; 12 encryptions of 240 and of 400 bytes and 12 decryptions of 256 and of 400 bytes for the release
buffer; 16 encryptions with generated IVs of 4 bytes of AAD and 256, 1024 or 4096 bytes of DATA (the messages of a
framer); 80 encryptions for the series test. With the dense output the message sink concatenates the expected sections
of every message and checks the gapless byte string, the section of the first byte of every beat, `Last` and the error
flag. Simulator: GHDL; QuestaSim for code coverage.

## 3. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_registers` (TC-CO-01) | ID, generics with the resolved numbers of AES units and GHASH digits, release buffer size, dense output, reset values; key and IV staging registers read as zero; counters zero after the reset | CO-IF-01, CO-IF-02 |
| `test_key_load` (TC-CO-02) | Load of every key of the vector file through the registers: LOAD_DONE, SLOT_STATUS, SLOT_FIXED and SLOT_COUNT of every slot; unloaded slot and slot 255 invalid | CO-FN-01, CO-FN-03 |
| `test_messages` (TC-CO-03) | 120 messages of both directions with 20 % stall cycles: every output byte and status; ENCRYPTIONS, DECRYPTIONS and ERR_AUTH counters, AUTH event; with the dense output also with the release buffer | CO-IF-01, CO-FN-01, CO-FN-07 |
| `test_iv_generation` (TC-CO-04) | 60 encryptions with generated IVs: IV section in front of the AAD, invocation counters in SLOT_COUNT | CO-FN-02, CO-FN-07 |
| `test_context_errors` (TC-CO-05) | Unloaded slot, slot out of range, external IV on a generator slot, generated IV on an external slot or for a decryption, exhausted counter: status, counters, events, exhausted flag in SLOT_STATUS | CO-FN-03, CO-FN-07 |
| `test_zeroize` (TC-CO-06) | ZEROIZE after the loads: every slot invalid with zero counter, 8 messages fail with KEY, reload and 120 messages pass | CO-FN-04 |
| `test_ecc` (TC-CO-07) | Through ECC_INJECT a single and a double error into every buffer of the data path, both directions, with 50 % stall cycles at the outputs: status and output of every message, exactly one SEC and one DED count per channel and direction, DED flags, ECC events, clear of the monitor | CO-FT-01, CO-FN-07 |
| `test_ecc_key_table` (TC-CO-08) | Through ECC_INJECT a single and a double error into the key, H and IV word of a load and into a job: OK after a single error, rejection with ECC after a double error; counts of the channels 11 to 17, DED flag of the job FIFO, ERR_ECC | CO-FT-01 |
| `test_irq` (TC-CO-09) | LOAD_DONE interrupt only when enabled, cleared with its flag | CO-IRQ-01 |
| `test_throughput_encrypt` (TC-CO-10) | 120 back-to-back encryptions without stall cycles: at most 40 cycles without output beat; with the dense output at most 40 plus the beats saved by the packing plus one per message; with the release buffer one more per message | CO-PF-01, CO-PF-02, CO-PF-04 |
| `test_throughput_decrypt` (TC-CO-11) | 120 back-to-back decryptions without stall cycles: at most 40 cycles without input beat; with the dense output at most 40 plus one per message | CO-PF-01, CO-PF-02 |
| `test_reset` (TC-CO-12) | Reset while messages are in the core: keys erased; after a reload all remaining messages are correct | CO-FN-06, CO-FN-07 |
| `test_throughput_ivgen` (TC-CO-14) | 16 back-to-back encryptions with generated IVs, 4 bytes of AAD and 256 bytes of DATA, then 16 with 1024 bytes, without stall cycles: from the last beat of the first message to the last beat of the last one exactly the sum of the sectioned output beats of the other messages (plus one per message whose last dense beat needs the extra beat of the packer) | CO-PF-03 |
| `test_throughput_release` (TC-CO-15) | Release buffer of 128 or 64 beats: 12 back-to-back encryptions of half the buffer and of more than half, 12 decryptions of half the buffer and of more than half, without stall cycles: after the first message every set within the sum of max(B + 2, 3 M - D + 4) | CO-PF-04 |
| `test_throughput_release_chunks` (TC-CO-16) | Release buffer of 8192 and of 16384 bytes at 128 bits: 16 back-to-back encryptions with generated IVs, 4 bytes of AAD and 4096 bytes of DATA (framer chunks, M = 259 sectioned beats), without stall cycles: after the first message exactly 3 M - D + 4 cycles per message with a buffer of one chunk (2 M > D) and exactly M + 1 with a buffer of two chunks | CO-PF-04 |
| `test_series` (TC-CO-13) | Core B decrypts the 80 encryptions of core A with 10 % and 20 % stall cycles: the output of core B is the input of core A, DECRYPTIONS of core B | CO-FN-05 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| CO-IF-01 | TC-CO-01, TC-CO-03 |
| CO-IF-02 | TC-CO-01 |
| CO-FN-01 | TC-CO-02, TC-CO-03 |
| CO-FN-02 | TC-CO-04 |
| CO-FN-03 | TC-CO-02, TC-CO-05 |
| CO-FN-04 | TC-CO-06 |
| CO-FN-05 | TC-CO-13 |
| CO-FN-06 | TC-CO-12 |
| CO-FN-07 | TC-CO-03 to TC-CO-05, TC-CO-07, TC-CO-12 (dense configurations) |
| CO-PF-01 | TC-CO-10, TC-CO-11 |
| CO-PF-02 | TC-CO-10, TC-CO-11 (dense configurations) |
| CO-PF-03 | TC-CO-14 |
| CO-PF-04 | TC-CO-10, TC-CO-15, TC-CO-16 (configurations with release buffer) |
| CO-FT-01 | TC-CO-07, TC-CO-08 |
| CO-IRQ-01 | TC-CO-09 |

## 5. Seams

| Seam | Crossed by |
| --- | --- |
| Register file to key table: load, zeroize, busy, query | TC-CO-02, TC-CO-04 to TC-CO-06, TC-CO-12 |
| Key table to data path: jobs, context errors, generated IVs | TC-CO-03 to TC-CO-05 |
| Key table to AES engine of the data path: hash subkey | TC-CO-02 to TC-CO-04 (every load) |
| Data path to register file: status events, counters | TC-CO-03, TC-CO-05, TC-CO-06 |
| ECC events and error injection of both modules | TC-CO-07, TC-CO-08 |
| Encryption output to decryption input | TC-CO-13 |
| Output of the data path (and of the release buffer) to the output packer | TC-CO-03 to TC-CO-05, TC-CO-07, TC-CO-10 to TC-CO-12 (dense configurations) |
