# ocr_mib: Verification Report

## 1. Test results

Run on 2026-10-15 in the CI job `simulation-ghdl` (Ubuntu 24.04) with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit
4f1e13bf), pycryptodome 3.23.0, Open Logic 4.7.0-ft.6: `python run.py -p 4` (full regression of 362 test runs; this
module: `python run.py "*ocr_mib_tb*"`).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_mib_tb` | 1 | 8 | 8 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass on 2026-10-14 without and with code coverage with
Open Logic 4.7.0-ft.3, which equals 4.7.0-ft.6 in every file that OpenCrypto uses (`python run.py --questa -p 1`,
`python run.py --questa --coverage -p 1`); the coverage is in [docs/coverage.md](../../../docs/coverage.md).

GHDL runs before 2026-10-14 passed one list of simulator flags to all simulations (VUnit 5.0.0.dev7 appends the
generics of every test to it), so a GHDL test could run with generics of an earlier test. QuestaSim was not
affected. Since then every GHDL simulation has its own flags and `run.py` checks its generics.

## 2. Summary

All test cases pass; every requirement of the specification is covered (see the verification plan). The register map is
in sync with its description (`python tools/regmap.py --check`). VSG reports no errors and no warnings; `ghdl --synth`
elaborates the core with this module in ten configurations without latches.

Findings:

| Finding | Resolution |
| --- | --- |
| The zeroize command and the addresses without register were not observed | TC-MG-03 counts the zeroize commands, TC-MG-01 reads and writes unused addresses |
| Code coverage: only one counter was cleared by a write; status codes 9 to 15, KEY_LOAD without START and a start during a running load were never applied | TC-MG-05 clears every counter and applies the codes 9 to 15, TC-MG-02 writes KEY_LOAD without START and during a load |

## 3. Generic values

The generics of `ocr_mib` are the configuration of `ocr_core` (with the numbers of AES units and GHASH digits that the
core uses) for the generics registers. `ocr_mib_tb` runs one configuration; TC-CO-01 reads the generics registers in
every configuration of `ocr_core_tb`, whose values are listed in the [ocr_core
report](../../ocr_core/docs/verification_report.md). Synthesised: the configurations of `lint/synth_check.py`
(`ghdl --synth`, no latch) through `ocr_core`.

| Generic | Declared range | Simulated | Synthesised |
| --- | --- | --- | --- |
| `DataWidth_g` | 16, 32, 64, 128 | 64; `ocr_core_tb`: 16, 32, 64, 128 | 16, 32, 64, 128 |
| `KeyBits_g` | 128, 192, 256 | 256; `ocr_core_tb`: 128, 192, 256 | 128, 192, 256 |
| `NumKeys_g` | 1 to 256 | 4; `ocr_core_tb`: 2, 4, 8 | 1, 4, 8, 16, 256 |
| `AesUnits_g` | 1 to 14 | 10; `ocr_core_tb`: 3, 6, 8, 10, 14 | 2, 3, 6, 10, 14 |
| `GhashDigit_g` | 16 to 128 | 128; `ocr_core_tb`: 64, 128 | 16, 64, 128 |
| `LenBits_g` | 8 to 32 | 20; `ocr_core_tb`: 32 | 8, 16, 32 |
| `ReleaseBuffer_g` | false, true | true; `ocr_core_tb`: false, true | false, true |
| `ReleaseBytes_g` | ≥ 0 | 2048; `ocr_core_tb`: 512, 4096, 8192, 16384 | 32, 4096, 8192, 65536 |
| `DenseOutput_g` | false, true | true; `ocr_core_tb`: false, true | false, true |
