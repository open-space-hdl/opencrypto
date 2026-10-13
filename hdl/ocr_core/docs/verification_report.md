# ocr_core: Verification Report

## 1. Test results

Run on 2026-10-13 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13bf), pycryptodome 3.23.0, Open Logic
4.7.0-ft.3: `python run.py -p 2 "*ocr_core_tb*"` (part of the full regression of 348 test runs). The six
configurations without the dense output passed on 2026-10-11 with Open Logic 4.7.0-ft.1 as well.

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_core_tb` | 10 (see the verification plan), 4 of them with the dense output | 64 | 64 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass in the regression with code coverage
(`python run.py --questa --coverage -p 1`); the coverage is in [docs/coverage.md](../../../docs/coverage.md).

## 2. Summary

All test cases pass; every requirement of the specification is covered and every seam between the modules is crossed
(see the verification plan). Two cores in series return the input of the encrypting core at the output of the decrypting
core (TC-CO-13). VSG reports no errors and no warnings; `ghdl --synth` elaborates the core with this module in four
configurations without latches.

Throughput of back-to-back messages without stall cycles (TC-CO-10, TC-CO-11):

| Configuration | Encryption: output beats, cycles without beat | Decryption: input beats, cycles without beat |
| --- | --- | --- |
| `w16_k128_n2` | 4592, 14 | 5533, 4 |
| `w32_k256_n4` | 2605, 14 | 2618, 4 |
| `w64_k192_n8` | 1221, 10 | 1263, 4 |
| `w128_k256_n4` | 705, 10 | 711, 4 |
| `w32_k256_n4_rel` | | 2618, 4 |
| `w16_k128_n2_dense` | 4581, 77 (allowed 171) | 5533, 4 |
| `w32_k256_n4_dense` | 2595, 99 (allowed 170) | 2618, 4 |
| `w128_k256_n4_dense` | 693, 118 (allowed 172) | 711, 4 |
| `w64_k192_n8_dense_rel` | | 1263, 4 |

With the dense output the encryption output has fewer beats (the packing saves the partial beats at the section
ends) and correspondingly more cycles without a beat; the allowed number is 40 plus the saved beats plus one per
message (CO-PF-02). The decryption input is not slowed down.

Findings:

| Finding | Resolution |
| --- | --- |
| QuestaSim, with stall cycles at the outputs: a double error in the output FIFO did not fail its encryption (the tag was not zeroed). The error flag was read only inside a procedure of the combinational process, and QuestaSim does not count such a signal to the sensitivity list of process (all) | The flag is a parameter of the procedure; the rule is part of the conventions; TC-CO-07 runs with stall cycles at the outputs |
| The error injection into the key table through ECC_INJECT and the key table channels of the EDAC monitor were not crossed by a core test | TC-CO-08 injects single and double errors into the key, H and IV word of a load and into a job through the register file |
