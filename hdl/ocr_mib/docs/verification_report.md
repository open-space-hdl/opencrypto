# ocr_mib: Verification Report

## 1. Test results

Run on 2026-10-11 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13bf), pycryptodome 3.23.0, Open Logic
4.7.0-ft.1: `python run.py -p 4 "*ocr_mib_tb*"` (part of the full regression of 278 test runs).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_mib_tb` | 1 | 8 | 8 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass on 2026-10-14 without and with code coverage
(`python run.py --questa -p 1`, `python run.py --questa --coverage -p 1`); the coverage is in
[docs/coverage.md](../../../docs/coverage.md).

GHDL runs before 2026-10-14 passed one list of simulator flags to all simulations (VUnit 5.0.0.dev7 appends the
generics of every test to it), so a GHDL test could run with generics of an earlier test. QuestaSim was not
affected. Since then every GHDL simulation has its own flags and `run.py` checks its generics.

## 2. Summary

All test cases pass; every requirement of the specification is covered (see the verification plan). The register map is
in sync with its description (`python tools/regmap.py --check`). VSG reports no errors and no warnings; `ghdl --synth`
elaborates the core with this module in four configurations without latches.

Findings:

| Finding | Resolution |
| --- | --- |
| The zeroize command and the addresses without register were not observed | TC-MG-03 counts the zeroize commands, TC-MG-01 reads and writes unused addresses |
| Code coverage: only one counter was cleared by a write; status codes 9 to 15, KEY_LOAD without START and a start during a running load were never applied | TC-MG-05 clears every counter and applies the codes 9 to 15, TC-MG-02 writes KEY_LOAD without START and during a load |
