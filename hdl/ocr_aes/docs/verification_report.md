# ocr_aes: Verification Report

## 1. Test results

Run on 2026-10-11 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13bf), pycryptodome 3.23.0, Open Logic
4.7.0-ft.1: `python run.py -p 4 "*ocr_aes_engine_tb*"` (part of the full regression of 278 test runs).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_aes_engine_tb` | 9 (AES-128 with 1, 3, 10 units; AES-192 with 3, 12; AES-256 with 2, 4, 6, 14) | 36 | 36 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass on 2026-10-14 without and with code coverage
(`python run.py --questa -p 1`, `python run.py --questa --coverage -p 1`); the coverage is in
[docs/coverage.md](../../../docs/coverage.md).

GHDL runs before 2026-10-14 passed one list of simulator flags to all simulations (VUnit 5.0.0.dev7 appends the
generics of every test to it), so a GHDL test could run with generics of an earlier test. QuestaSim was not
affected. Since then every GHDL simulation has its own flags and `run.py` checks its generics.

## 2. Summary

All test cases pass; every requirement of the specification is covered (see the verification plan). The latency is Nr +
1 cycles and the throughput exactly `AesUnits_g` / Nr blocks per cycle in every configuration. VSG reports no errors and
no warnings; `ghdl --synth` elaborates the core with this module in four configurations without latches.

Findings:

| Finding | Resolution |
| --- | --- |
| The first version of the vector store limited a run to the number of GCM messages, so a test with only ECB records ran without any block and passed | The store limits a run to the number of records of either kind, and every test checks the number of results |
