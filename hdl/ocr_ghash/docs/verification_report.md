# ocr_ghash: Verification Report

## 1. Test results

Run on 2026-10-15 in the CI job `simulation-ghdl` (Ubuntu 24.04) with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit
4f1e13bf), pycryptodome 3.23.0, Open Logic 4.7.0-ft.6: `python run.py -p 4` (full regression of 362 test runs; this
module: `python run.py "*ocr_ghash_tb*"`).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_ghash_tb` | 9 (16 bits with digits 16, 64, 128; 32 bits with 32, 64; 64 bits with 64, 128; 128 bits with 128; 32 bits with 8-bit byte counts) | 33 | 33 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass on 2026-10-14 without and with code coverage with
Open Logic 4.7.0-ft.3, which equals 4.7.0-ft.6 in every file that OpenCrypto uses (`python run.py --questa -p 1`,
`python run.py --questa --coverage -p 1`); the coverage is in [docs/coverage.md](../../../docs/coverage.md).

GHDL runs before 2026-10-14 passed one list of simulator flags to all simulations (VUnit 5.0.0.dev7 appends the
generics of every test to it), so a GHDL test could run with generics of an earlier test. QuestaSim was not
affected. Since then every GHDL simulation has its own flags and `run.py` checks its generics.

## 2. Summary

All test cases pass; every requirement of the specification is covered (see the verification plan). Throughput of 150
random messages without stall cycles (TC-GH-03): the multiplier stays within its budget of max(beats + 1, steps ·
(blocks + 1)) cycles per message in every configuration, for example 1441 of 1442 cycles at 128 bits and 11454 of 11504
cycles at 16 bits with a 16-bit digit. VSG reports no errors and no warnings; `ghdl --synth` elaborates the core with
this module in ten configurations without latches.

Findings:

| Finding | Resolution |
| --- | --- |
| With a multiplier of two steps per block and a one-stage block queue the budget was exceeded by about 1.2 cycles per message | Three-stage block queue for multipliers of more than one step; the queue entry carries no byte counts (they are recovered from the length block) |

## 3. Generic values

Simulated: the VUnit configurations of `ocr_ghash_tb` and of `ocr_gcm_tb` (the digit of the maximum configuration).
Synthesised: the configurations of `lint/synth_check.py` (`ghdl --synth`, no latch) through `ocr_core`.

| Generic | Declared range | Simulated | Synthesised |
| --- | --- | --- | --- |
| `DataWidth_g` | 16, 32, 64, 128 | 16, 32, 64, 128 | 16, 32, 64, 128 |
| `Digit_g` | power of two from `DataWidth_g` to 128 | 16 at 16 bits; 32 at 32 bits; 64 at 16, 32, 64 bits; 128 at 16, 64, 128 bits; `ocr_gcm_tb`: 128 at 32 bits | 16, 64, 128 |
| `LenBits_g` | 8 to 32 | 8, 32 | 8, 16, 32 |
