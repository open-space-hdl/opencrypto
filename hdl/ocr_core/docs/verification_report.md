# ocr_core: Verification Report

## 1. Test results

Run on 2026-10-15 in the CI job `simulation-ghdl` (Ubuntu 24.04) with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit
4f1e13bf), pycryptodome 3.23.0, Open Logic 4.7.0-ft.6: `python run.py -p 4` (full regression of 362 test runs; this
module: `python run.py "*ocr_core_tb*"`).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_core_tb` | 12 (see the verification plan), 6 of them with the dense output | 73 | 73 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass on 2026-10-14 without and with code coverage with
Open Logic 4.7.0-ft.3, which equals 4.7.0-ft.6 in every file that OpenCrypto uses (`python run.py --questa -p 1`,
`python run.py --questa --coverage -p 1`); the coverage is in [docs/coverage.md](../../../docs/coverage.md).

GHDL runs before 2026-10-14 passed one list of simulator flags to all simulations (VUnit 5.0.0.dev7 appends the
generics of every test to it), so a GHDL test could run with generics of an earlier test. QuestaSim was not
affected. Since then every GHDL simulation has its own flags and `run.py` checks its generics.

## 2. Summary

All test cases pass; every requirement of the specification is covered and every seam between the modules is crossed
(see the verification plan). Two cores in series return the input of the encrypting core at the output of the decrypting
core (TC-CO-13). VSG reports no errors and no warnings; `ghdl --synth` elaborates the core with this module in ten
configurations without latches.

Throughput of back-to-back messages without stall cycles (TC-CO-10, TC-CO-11):

| Configuration | Encryption: output beats, cycles without beat | Decryption: input beats, cycles without beat |
| --- | --- | --- |
| `w16_k128_n2` | 4592, 14 | 5533, 4 |
| `w32_k256_n4` | 2605, 14 | 2618, 4 |
| `w64_k192_n8` | 1221, 10 | 1263, 4 |
| `w128_k256_n4` | 705, 10 | 711, 4 |
| `w32_k256_n4_rel` | 2605, 154 (allowed 160) | 2618, 4 |
| `w16_k128_n2_dense` | 4581, 77 (allowed 171) | 5533, 4 |
| `w32_k256_n4_dense` | 2595, 99 (allowed 170) | 2618, 4 |
| `w128_k256_n4_dense` | 693, 118 (allowed 172) | 711, 4 |
| `w64_k192_n8_dense_rel` | 1206, 142 (allowed 295) | 1263, 4 |

With the dense output the encryption output has fewer beats (the packing saves the partial beats at the section
ends) and correspondingly more cycles without a beat; the allowed number is 40 plus the saved beats plus one per
message (CO-PF-02). The decryption input is not slowed down. The release buffer stalls its read side one cycle per
message, so its configurations allow one more cycle per message (CO-PF-04); of the 120 encryptions at 32 bits, 114
took exactly one cycle more than their beats, the others waited until they were complete after a shorter message.

Back-to-back encryptions with generated IVs in the shape of framer chunks (TC-CO-14, 16 messages with 4 bytes of AAD;
cycles from the last beat of the first message to the last beat of the last one):

| Configuration | DATA bytes | Sectioned output beats per message | Cycles | Expected |
| --- | --- | --- | --- | --- |
| `w128_k256_n4` | 256 | 19 | 285 | 285 |
| `w128_k256_n4` | 1024 | 67 | 1005 | 1005 |
| `w128_k256_n4_dense` | 256 | 19 (18 dense beats) | 285 | 285 |
| `w128_k256_n4_dense` | 1024 | 67 (66 dense beats) | 1005 | 1005 |
| `w64_k192_n8` | 256 | 37 | 555 | 555 |
| `w64_k192_n8` | 1024 | 133 | 1995 | 1995 |

Every message takes exactly its sectioned output beats: neither the IV generation nor J0 costs a cycle (CO-PF-03).

Release buffer with messages of half the buffer and longer (TC-CO-15, 12 messages per set; cycles of the 11 messages
after the first one on the bottleneck side; M sectioned output beats of a message, B its beats on the bottleneck
side, D beats of the buffer):

| Configuration | Set | M | B | D | Cycles | Bound | Per message |
| --- | --- | --- | --- | --- | --- | --- | --- |
| `w32_k256_n4_rel` | Encryptions of 240 bytes | 64 | 64 | 128 | 725 | 748 | 65.9 |
| `w32_k256_n4_rel` | Encryptions of 400 bytes | 104 | 104 | 128 | 2068 | 2068 | 188 |
| `w32_k256_n4_rel` | Decryptions of 256 bytes | 64 | 68 | 128 | 748 | 770 | 68 |
| `w32_k256_n4_rel` | Decryptions of 400 bytes | 100 | 104 | 128 | 1904 | 1936 | 173.1 |
| `w64_k192_n8_dense_rel` | Encryptions of 240 bytes | 32 | 32 | 64 | 373 | 396 | 33.9 |
| `w64_k192_n8_dense_rel` | Encryptions of 400 bytes | 52 | 52 | 64 | 1056 | 1056 | 96 |
| `w64_k192_n8_dense_rel` | Decryptions of 256 bytes | 32 | 34 | 64 | 374 | 396 | 34 |
| `w64_k192_n8_dense_rel` | Decryptions of 400 bytes | 50 | 52 | 64 | 914 | 990 | 83.1 |

While two messages fit into the buffer (2 M ≤ D), an encryption takes one to two cycles more than its beats and a
decryption keeps the rate of its input. With 2 M > D the next message waits for the space of the one before: the
encryptions of 400 bytes take exactly 3 M - D + 4 cycles each.

Release buffer with framer chunks at 128 bits (TC-CO-16, 16 encryptions with generated IVs of 4 bytes of AAD and 4096
bytes of DATA, M = 259 sectioned beats; cycles of the 15 messages after the first one):

| Configuration | D | Cycles | Expected | Per chunk |
| --- | --- | --- | --- | --- |
| `w128_k256_n4_dense_rel8k` | 512 | 4035 | 15 · (3 M - D + 4) = 4035 | 269 |
| `w128_k256_n4_dense_rel16k` | 1024 | 3900 | 15 · (M + 1) = 3900 | 260 |

Without the release buffer the same chunks take 259 cycles (TC-CO-14 at 1024 bytes, TC-FR-08 at 4096 bytes). A buffer
that holds one chunk but not two costs 10 cycles per chunk, a buffer of two chunks one cycle.

Findings:

| Finding | Resolution |
| --- | --- |
| QuestaSim, with stall cycles at the outputs: a double error in the output FIFO did not fail its encryption (the tag was not zeroed). The error flag was read only inside a procedure of the combinational process, and QuestaSim does not count such a signal to the sensitivity list of process (all) | The flag is a parameter of the procedure; the rule is part of the conventions; TC-CO-07 runs with stall cycles at the outputs |
| The error injection into the key table through ECC_INJECT and the key table channels of the EDAC monitor were not crossed by a core test | TC-CO-08 injects single and double errors into the key, H and IV word of a load and into a job through the register file |
| The throughput with the release buffer was measured for decryptions only, and back-to-back encryptions with generated IVs not at all | TC-CO-10 runs in the configurations with release buffer (one cycle more per message, CO-PF-04), TC-CO-15 measures messages of half the buffer and longer, TC-CO-14 encryptions with generated IVs (CO-PF-03) |
| The core had never been synthesised with 256 key slots, 8-bit byte counts, paced scrubbers, the maximum numbers of AES units and GHASH digit or the bounds of the release buffer | `lint/synth_check.py` synthesises these bounds (section 3) |

## 3. Generic values

Declared ranges as in the user guide; a value outside them stops the elaboration. Simulated: the values of the VUnit
configurations of `ocr_core_tb` and, where a module testbench covers further values, of that testbench. Synthesised: the
configurations of `lint/synth_check.py` (`ghdl --synth`, no latch). `AesUnits_g` and `GhashDigit_g` set `Units_g` of the
AES engine and `Digit_g` of the GHASH multiplier (the defaults of the width when they are 0); their full lists are in
the reports of [ocr_aes](../../ocr_aes/docs/verification_report.md) and
[ocr_ghash](../../ocr_ghash/docs/verification_report.md).

| Generic | Declared range | Simulated | Synthesised |
| --- | --- | --- | --- |
| `DataWidth_g` | 16, 32, 64, 128 | 16, 32, 64, 128 | 16, 32, 64, 128 |
| `KeyBits_g` | 128, 192, 256 | 128, 192, 256 | 128, 192, 256 |
| `NumKeys_g` | 1 to 256 | 2, 4, 8; `ocr_key_table_tb`: 1, 3, 4, 16, 256 | 1, 4, 8, 16, 256 |
| `AesUnits_g` | 0, ceil(Nr / R) to Nr | 0 (3, 6, 8, 10, 14 units); `ocr_gcm_tb`: 0 (4, 5, 6, 7, 10, 12, 14 units), 4 (minimum at 32 bits, AES-256), 14 (maximum at 32 bits); `ocr_aes_engine_tb`: 1 to 14 units | 0 (3, 6, 10, 14 units), 2 (minimum at 16 bits, AES-128), 6 (minimum at 64 bits, AES-192), 14 (maximum at 32 bits) |
| `GhashDigit_g` | 0, power of two from `DataWidth_g` to 128 | 0 (64 at 16 and 32 bits, 128 at 64 and 128 bits); `ocr_gcm_tb`: 32 (minimum at 32 bits), 128 (maximum at 32 bits); `ocr_ghash_tb`: 16, 32, 64, 128 | 0, 16 (minimum at 16 bits), 64 (minimum at 64 bits), 128 (maximum at 32 bits) |
| `LenBits_g` | 8 to 32 | 32; `ocr_gcm_tb`, `ocr_ghash_tb`: 8 | 8, 16, 32 |
| `ReleaseBuffer_g` | false, true | false, true | false, true |
| `ReleaseBytes_g` | power of two, 16 beats to 65536 | 512, 8192, 16384; `ocr_gcm_tb`: 64 (16 beats, minimum), 512, 1024 | 32 (16 beats, minimum), 4096, 8192, 65536 (maximum) |
| `DenseOutput_g` | false, true | false, true | false, true |
| `ClkFreqHz_g` | ≥ 1000 when `ScrubPeriod_g` > 0 | 100.0e6; `ocr_key_table_tb`: 1.0e6 | 100.0e6 |
| `ScrubPeriod_g` | 0.0 or ≥ 0.001 | 0.0; `ocr_key_table_tb`: 0.002 | 0.0, 0.001 |

65536 bytes is the largest release buffer that is elaborated and synthesised; the buffer sizes its counters from
`ReleaseBytes_g`, so the bound is the verified maximum, not a limit of the design.
