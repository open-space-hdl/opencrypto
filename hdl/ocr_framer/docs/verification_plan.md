# ocr_framer: Verification Plan

## 1. Overview

The packet source of the harness sends the input packets of a vector file: the chunks of a packet are consecutive
messages of the file, and `Last` is set on the last beat of the last chunk. Without the core, the message sink checks
every output beat of the framer against the expected AAD (chunk position) and DATA section (chunk bytes), and a
context checker checks and counts the contexts. With the core (`Core_g`), the framer feeds `ocr_core` with the dense
output; the dense message sink checks every output message against the encryption of pycryptodome with the expected
generated IV (IV ‖ AAD ‖ ciphertext ‖ tag), and the status sink checks the status, the IV and the byte counts. The
expected positions, IVs, ciphertexts and tags come from `tools/ocr_vectors.py`, not from the RTL.

## 2. Test configuration

| Testbench | Harness | DUT and environment |
| --- | --- | --- |
| `ocr_framer_tb` | `ocr_framer_th` | `ocr_framer` at 100 MHz with packet source and the ECC event counters; without the core: message sink (`User(2)`: the IV section code was seen in the message) and context checker; with `Core_g`: `ocr_core` with the dense output, AXI4-Lite VVC, dense message sink and status sink |

| Configuration | Width | Chunk bytes | Buffer chunks | Core | Tests |
| --- | --- | --- | --- | --- | --- |
| `w32_c64` | 32 | 64 | 2 | no | TC-FR-01 to TC-FR-05 |
| `w16_c32` | 16 | 32 | 2 | no | TC-FR-01 to TC-FR-05 |
| `w64_c128_b3` | 64 | 128 | 3 | no | TC-FR-01 to TC-FR-05 |
| `w128_c256_b4` | 128 | 256 | 4 | no | TC-FR-01 to TC-FR-05 |
| `w32_c4096` | 32 | 4096 | 2 | no | TC-FR-01, TC-FR-03 |
| `w32_c64_core` | 32 | 64 | 2 | AES-256 | TC-FR-06, TC-FR-07 |
| `w16_c32_core` | 16 | 32 | 2 | AES-128 | TC-FR-06, TC-FR-07 |
| `w64_c1024_core` | 64 | 1024 | 2 | AES-256 | TC-FR-06, TC-FR-07 |
| `w128_c256_core` | 128 | 256 | 2 | AES-256 | TC-FR-06, TC-FR-07 |

Vector files per configuration: 30 packets with the boundary lengths first (0, 1, C - 1, C, C + 1, 2 C, 2 C + 3,
3 C, 15, 16, 17 bytes for chunks of C bytes), then random lengths up to 3 C; four long packets (8 C + 5, 5 C, 3 C + 1,
2 C) for the throughput; 12 packets of one chunk for the error injection. Simulator: GHDL; QuestaSim for code
coverage.

## 3. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_chunks` (TC-FR-01) | The 30 packets with 30 % cycles without valid, without ready of the output and without ready of the contexts: AAD with the position and DATA of every chunk, one context per chunk with the configured slot (the last slot of the core) | FR-IF-01, FR-IF-02, FR-FN-01, FR-FN-02, FR-FN-03, FR-FN-04 |
| `test_backpressure` (TC-FR-02) | 80 % cycles without ready of the output and of the contexts, then 80 % cycles without valid at the input, then a context receiver that takes nothing for 3000 cycles (the framer stops at its limit of owed contexts and resumes): every chunk and context as expected | FR-FN-05 |
| `test_throughput` (TC-FR-03) | The four long packets without stall cycles: at most AadBeats + 2 cycles without input beat per chunk | FR-PF-01 |
| `test_ecc` (TC-FR-04) | One chunk at a time, a single and a double error into the chunk buffer and into the position FIFO: a single error leaves the chunk correct, a double error marks the chunk with the IV section code; exactly one SEC or DED event per injection on its buffer | FR-FT-01 |
| `test_reset` (TC-FR-05) | Reset in the middle of a packet: the packets from the next packet start on are correct, with one context per chunk | FR-FN-06 |
| `test_encrypt` (TC-FR-06) | Framer and core: the 30 packets with 20 % stall cycles; every output message is IV ‖ AAD ‖ ciphertext ‖ tag of pycryptodome with the next generated IV, every status OK with the IV and the byte counts; the invocation counter of the slot advanced by the number of chunks | FR-IN-01 |
| `test_ecc_core` (TC-FR-07) | Framer and core: single and double errors as in TC-FR-04; the chunks with a double error fail with FORMAT, error flag and their IV; the others are correct; ERR_FORMAT counts the failed chunks | FR-FT-01, FR-IN-01 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| FR-IF-01, FR-IF-02, FR-FN-01 to FR-FN-04 | TC-FR-01 |
| FR-FN-05 | TC-FR-01, TC-FR-02 |
| FR-FN-06 | TC-FR-05 |
| FR-FT-01 | TC-FR-04, TC-FR-07 |
| FR-PF-01 | TC-FR-03 |
| FR-IN-01 | TC-FR-06, TC-FR-07 |

FR-IF-02 is checked for the legal values by every configuration; an illegal `ChunkBytes_g` or `DataWidth_g` stops the
elaboration with an assertion of severity failure, which a simulation run cannot pass by construction.

## 5. Seams

| Seam | Crossed by |
| --- | --- |
| Framer contexts to the key table of the core: generated IVs, slot | TC-FR-06, TC-FR-07 |
| Framer messages to the input parser of the core: AAD and DATA sections, IV section code of a double error | TC-FR-06, TC-FR-07 |
| Output assembly to the output packer: dense output of encryptions with generated IV | TC-FR-06 |
