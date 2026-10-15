# ocr_packer: Verification Report

## 1. Test results

Run on 2026-10-15 in the CI job `simulation-ghdl` (Ubuntu 24.04) with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit
4f1e13bf), pycryptodome 3.23.0, Open Logic 4.7.0-ft.6: `python run.py -p 4` (full regression of 362 test runs; this
module: `python run.py "*ocr_packer_tb*"`).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_packer_tb` | 4 (16, 32, 64 and 128 bits) | 16 | 16 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass on 2026-10-14 without and with code coverage
(`python run.py --questa -p 1`, `python run.py --questa --coverage -p 1`); the coverage is in
[docs/coverage.md](../../../docs/coverage.md).

GHDL runs before 2026-10-14 passed one list of simulator flags to all simulations (VUnit 5.0.0.dev7 appends the
generics of every test to it), so a GHDL test could run with generics of an earlier test. QuestaSim was not
affected. Since then every GHDL simulation has its own flags and `run.py` checks its generics.

## 2. Summary

All test cases pass; every requirement of the specification is covered (see the verification plan). The packer
behind the GCM data path is verified in the dense configurations of the core testbench (CO-FN-07, CO-PF-02). VSG
reports no errors and no warnings; `ghdl --synth` elaborates the core with the dense output at 64 and 128 bits
without latches.

Throughput of the 80 long messages without stall cycles (TC-PA-03): the input pauses exactly once for every message
that needs an extra output beat for its last bytes, and never otherwise.

| Configuration | Input beats | Cycles without input beat | Messages with an extra output beat |
| --- | --- | --- | --- |
| `w16` | 9849 | 23 | 23 |
| `w32` | 4965 | 37 | 37 |
| `w64` | 2531 | 49 | 49 |
| `w128` | 1301 | 54 | 54 |

Findings:

| Finding | Resolution |
| --- | --- |
| A message whose last beat is an empty beat after bytes that filled whole beats ends with an extra beat without byte; the first vector set contained such messages | The output assembly of the core never sends them (an empty beat is the only beat of a message); the input format of PA-IF-01 states it and the architecture documents the behaviour. The vector generator no longer ends a message with bytes by an empty section |
