# ocr_gcm: Verification Report

## 1. Test results

Run on 2026-10-11 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13bf), pycryptodome 3.23.0, Open Logic
4.7.0-ft.1: `python run.py -p 4 "*ocr_gcm_tb*"` (part of the full regression of 278 test runs).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_gcm_tb` | 11 (see the verification plan) | 102 | 102 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass on 2026-10-14 without and with code coverage
(`python run.py --questa -p 1`, `python run.py --questa --coverage -p 1`); the coverage is in
[docs/coverage.md](../../../docs/coverage.md).

GHDL runs before 2026-10-14 passed one list of simulator flags to all simulations (VUnit 5.0.0.dev7 appends the
generics of every test to it), so a GHDL test could run with generics of an earlier test. QuestaSim was not
affected. Since then every GHDL simulation has its own flags and `run.py` checks its generics.

## 2. Summary

All test cases pass; every requirement of the specification is covered (see the verification plan). Every output byte of
120 random encryptions, 120 random decryptions and 150 mixed messages per configuration equals pycryptodome; every
modified tag, AAD or ciphertext fails with AUTH. VSG reports no errors and no warnings; `ghdl --synth` elaborates the
core with this module in four configurations without latches.

Throughput of back-to-back messages without stall cycles (TC-GC-06, TC-GC-07): cycles without a beat on the bottleneck
side over the whole run, including the initial latency.

| Configuration | Encryption: output beats, cycles without beat | Decryption: input beats, cycles without beat |
| --- | --- | --- |
| `w16_aes256` | 6276, 16 | 6341, 1 |
| `w32_aes128` | 3292, 17 | 3349, 2 |
| `w32_aes192` | 3054, 17 | 3182, 1 |
| `w64_aes256` | 1640, 12 | 1659, 1 |
| `w128_aes128` | 896, 13 | 907, 1 |
| `w128_aes256` | 870, 12 | 877, 1 |
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
