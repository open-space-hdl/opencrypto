# ocr_pkg: Verification Report

## 1. Test results

Run on 2026-10-11 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13bf), pycryptodome 3.23.0, Open Logic
4.7.0-ft.1: `python run.py -p 4 "*ocr_pkg_tb*"` (part of the full regression of 278 test runs).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_pkg_tb` | 1 | 10 | 10 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass in the regression with code coverage
(`python run.py --questa --coverage -p 1`); the coverage is in [docs/coverage.md](../../../docs/coverage.md).

## 2. Summary

All test cases pass; every requirement of the specification is covered (see the verification plan). The cipher functions
reproduce the examples of FIPS 197 (Appendix A, B and C) and 150 random blocks of pycryptodome for every key length; the
GF(2<sup>128</sup>) functions reproduce Algorithm 1 of the GCM specification for every digit size and the GHASH values
of the GCM test cases. VSG reports no errors and no warnings; `ghdl --synth` elaborates the core with this module in
four configurations without latches.

Findings:

| Finding | Resolution |
| --- | --- |
| The beat and block conversion functions used dynamic slices that GHDL cannot synthesize for 128-bit beats | Multiplexer over the beat index with static slices; same behaviour, all tests unchanged |
| Code coverage: the precedence of OVERFLOW was checked only with constant arguments, which the simulator evaluates at compile time | TC-PK-09 merges every pair of codes at run time |
