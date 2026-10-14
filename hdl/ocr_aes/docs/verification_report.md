# ocr_aes: Verification Report

## 1. Test results

Run on 2026-10-15 in the CI job `simulation-ghdl` (Ubuntu 24.04) with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit
4f1e13bf), pycryptodome 3.23.0, Open Logic 4.7.0-ft.6: `python run.py -p 4` (full regression of 362 test runs; this
module: `python run.py "*ocr_aes_engine_tb*"`).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_aes_engine_tb` | 15 (AES-128 with 1, 3, 5, 7, 8, 9, 10 units; AES-192 with 3, 11, 12; AES-256 with 2, 4, 6, 13, 14) | 60 | 60 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass on 2026-10-14 without and with code coverage with
Open Logic 4.7.0-ft.3, which equals 4.7.0-ft.6 in every file that OpenCrypto uses (`python run.py --questa -p 1`,
`python run.py --questa --coverage -p 1`); the coverage is in [docs/coverage.md](../../../docs/coverage.md).

GHDL runs before 2026-10-14 passed one list of simulator flags to all simulations (VUnit 5.0.0.dev7 appends the
generics of every test to it), so a GHDL test could run with generics of an earlier test. QuestaSim was not
affected. Since then every GHDL simulation has its own flags and `run.py` checks its generics.

## 2. Summary

All test cases pass; every requirement of the specification is covered (see the verification plan). The latency is Nr +
1 cycles and the throughput exactly `AesUnits_g` / Nr blocks per cycle in every configuration. VSG reports no errors and
no warnings; `ghdl --synth` elaborates the core with this module in ten configurations and the engine alone with one
unit, without latches.

Findings:

| Finding | Resolution |
| --- | --- |
| The first version of the vector store limited a run to the number of GCM messages, so a test with only ECB records ran without any block and passed | The store limits a run to the number of records of either kind, and every test checks the number of results |
| The numbers of units 5, 7, 8, 9, 11 and 13 had never run; 7 is the default of AES-128 at 64 bits | Configurations with these numbers: every number of units from 1 to 14 runs |

## 3. Generic values

Simulated: the VUnit configurations of `ocr_aes_engine_tb`; the engine also runs in every configuration of `ocr_gcm_tb`,
`ocr_core_tb` and `ocr_framer_tb` (with the core). Synthesised: the configurations of `lint/synth_check.py`
(`ghdl --synth`, no latch), through `ocr_core` and the engine alone. `ocr_aes_unit` takes its generics from the engine.

| Generic | Declared range | Simulated | Synthesised |
| --- | --- | --- | --- |
| `KeyBits_g` | 128, 192, 256 | 128, 192, 256 | 128, 192, 256 |
| `Units_g` | 1 to Nr | 1 to 14: AES-128 1, 3, 5, 7, 8, 9, 10; AES-192 3, 11, 12; AES-256 2, 4, 6, 13, 14 | 1 (engine alone), 2, 3, 6, 10, 14 |
| `TagWidth_g` | 1 or more | 12; 2 (set by `ocr_gcm_keystream`) | 2 |
