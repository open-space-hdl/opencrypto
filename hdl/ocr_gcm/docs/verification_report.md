# ocr_gcm: Verification Report

## 1. Test results

Run on 2026-10-15 in the CI job `simulation-ghdl` (Ubuntu 24.04) with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit
4f1e13bf), pycryptodome 3.23.0, Open Logic 4.7.0-ft.6: `python run.py -p 4` (full regression of 441 test runs; this
module: `python run.py "*ocr_gcm_tb*"`).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_gcm_tb` | 15 (see the verification plan) | 142 | 142 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass on 2026-10-15 without and with code coverage
(`python run.py --questa -p 1`, `python run.py --questa --coverage -p 1`); the coverage is in
[docs/coverage.md](../../../docs/coverage.md).

GHDL runs before 2026-10-14 passed one list of simulator flags to all simulations (VUnit 5.0.0.dev7 appends the
generics of every test to it), so a GHDL test could run with generics of an earlier test. QuestaSim was not
affected. Since then every GHDL simulation has its own flags and `run.py` checks its generics.

## 2. Summary

All test cases pass; every requirement of the specification is covered (see the verification plan). Every output byte of
120 random encryptions, 120 random decryptions and 150 mixed messages per configuration equals pycryptodome; every
modified tag, AAD or ciphertext fails with AUTH. VSG reports no errors and no warnings; `ghdl --synth` elaborates the
core with this module in ten configurations without latches.

Throughput of back-to-back messages without stall cycles (TC-GC-06, TC-GC-07): cycles without a beat on the bottleneck
side over the whole run, including the initial latency.

| Configuration | Encryption: output beats, cycles without beat | Decryption: input beats, cycles without beat |
| --- | --- | --- |
| `w16_aes256` | 6276, 16 | 6341, 1 |
| `w32_aes128` | 3292, 17 | 3349, 2 |
| `w32_aes192` | 3054, 17 | 3182, 1 |
| `w64_aes128` | 1699, 13 | 1727, 1 |
| `w64_aes256` | 1640, 12 | 1659, 1 |
| `w128_aes128` | 896, 13 | 907, 1 |
| `w128_aes192` | 832, 13 | 869, 1 |
| `w128_aes256` | 870, 12 | 877, 1 |
| `w32_aes256_max` | 3184, 12 | 3221, 1 |
| `w32_aes256_rel`, `w128_aes256_rel` | | 3221, 1; 877, 1 |

The cycles without a beat are the initial latency; after it the bottleneck side transfers one beat in every cycle for
all 150 messages.

Findings:

| Finding | Resolution |
| --- | --- |
| The hash subkey and descriptor of the next job were written only when the next job register was already free in the previous cycle, so a job that arrived with the start of a message waited forever | The free state of the next job register is evaluated before the job is taken (TC-GC-02) |
| A release buffer of 256 bytes dropped the longest test messages with OVERFLOW | Correct behaviour; the release configurations use 512 and 1024 bytes and TC-GC-14 checks OVERFLOW with messages longer than the buffer |
| Code coverage: the buffers inside the data path never filled, a hash subkey result was always taken at once, an IV section never followed a rejected message or a decryption directly | New TC-GC-15 (200 short messages, then a sink and a status sink that are rarely ready); TC-GC-11 and TC-GC-09 extended |
| QuestaSim, with stall cycles at the outputs: a double error in the output FIFO did not fail its encryption (the tag was not zeroed). The error flag was read only inside a procedure of the combinational process, and QuestaSim does not count such a signal to the sensitivity list of process (all) | The flag is a parameter of the procedure; the rule is part of the conventions; TC-CO-07 runs with stall cycles at the outputs |
| Code coverage: three conditions could not be false in their context (the J0 request of the next job, the check of an empty beat, the format error register of the combiner, whose error always arrives with the last entry of a message) | Simplified to the equivalent shorter conditions; the format error register was removed |
| The defaults of AES-128 at 64 bits (7 units) and of AES-192 at 128 bits (12 units), the maximum numbers of AES units and GHASH digit and the smallest release buffer had never run, and `ReleaseBytes_g` had no upper bound | `w64_aes128`, `w128_aes192` and `w32_aes256_max` run the default tests, `w32_aes256_rel64` the release buffer of 16 beats with messages of exactly 16 and 17 beats; `ReleaseBytes_g` is at most 65536 (GC-OU-05) |

## 3. Generic values

`ocr_core` sets the generics of `ocr_gcm` from its own (the slot width from `NumKeys_g`); the blocks inside `ocr_gcm`
take theirs from it. Simulated: the VUnit configurations of `ocr_gcm_tb` and, for the slot width, of `ocr_core_tb`.
Synthesised: the configurations of `lint/synth_check.py` (`ghdl --synth`, no latch) through `ocr_core`.

| Generic | Declared range | Simulated | Synthesised |
| --- | --- | --- | --- |
| `DataWidth_g` | 16, 32, 64, 128 | 16, 32, 64, 128 | 16, 32, 64, 128 |
| `KeyBits_g` | 128, 192, 256 | 128, 192, 256 | 128, 192, 256 |
| `AesUnits_g` | 0, ceil(Nr / R) to Nr | 0 (4, 5, 6, 7, 10, 12, 14 units), 4 (minimum at 32 bits, AES-256), 14 (maximum at 32 bits) | 0 (3, 6, 10, 14 units), 2, 6, 14 |
| `GhashDigit_g` | 0, power of two from `DataWidth_g` to 128 | 0 (64, 128), 32 (minimum at 32 bits), 128 (maximum at 32 bits) | 0 (64, 128), 16, 64, 128 |
| `LenBits_g` | 8 to 32 | 8, 32 | 8, 16, 32 |
| `SlotBits_g` | 1 to 8 | 3; `ocr_core_tb`: 1, 2, 3 | 1, 2, 3, 4, 8 |
| `ReleaseBuffer_g` | false, true | false, true | false, true |
| `ReleaseBytes_g` | power of two, 16 beats to 65536 | 64 (16 beats, minimum), 512, 1024 | 32 (16 beats, minimum), 4096, 8192, 65536 (maximum) |
