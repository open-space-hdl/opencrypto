# ocr_key_table: Verification Report

## 1. Test results

Run on 2026-10-15 in the CI job `simulation-ghdl` (Ubuntu 24.04) with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit
4f1e13bf), pycryptodome 3.23.0, Open Logic 4.7.0-ft.6: `python run.py -p 4` (full regression of 441 test runs; this
module: `python run.py "*ocr_key_table_tb*"`).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_key_table_tb` | 6 (AES-256 with 4 and 16 slots, AES-128 with 1 and 256 slots, AES-192 with 3 slots, AES-256 with 4 slots and paced scrubbers) | 59 | 59 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass on 2026-10-15 without and with code coverage
(`python run.py --questa -p 1`, `python run.py --questa --coverage -p 1`); the coverage is in
[docs/coverage.md](../../../docs/coverage.md).

GHDL runs before 2026-10-14 passed one list of simulator flags to all simulations (VUnit 5.0.0.dev7 appends the
generics of every test to it), so a GHDL test could run with generics of an earlier test. QuestaSim was not
affected. Since then every GHDL simulation has its own flags and `run.py` checks its generics.

## 2. Summary

All test cases pass; every requirement of the specification is covered (see the verification plan). Contexts are
resolved at one per cycle with external IVs and one per two cycles with generated IVs in every configuration (TC-KT-09).
VSG reports no errors and no warnings; `ghdl --synth` elaborates the core with this module in ten configurations without
latches.

Findings:

| Finding | Resolution |
| --- | --- |
| With 3 slots a context of slot 3 read beyond the end of the memories | A slot out of range reads address 0 and discards the result (`k192_n3`) |
| A job with a double error in the job FIFO carried its key and hash subkey | Key and hash subkey of such a job are zeros (TC-KT-07) |
| An error injection into a memory that was held for the next load could be taken by a write-back of the scrubber | The injection is applied with the write of the load (TC-KT-07, `k256_n16`) |
| The load of a slot out of range was not observed at module level | TC-KT-02 loads a slot out of range in the configurations with unused slot numbers |
| Code coverage: a query accepted in the cycle after another query was not answered (the response pulse of the first query cleared the pulse of the second) | The response pulse is cleared before it is set; TC-KT-02 sends queries in consecutive cycles and counts the answers (the old logic answers 6 of 11) |
| Code coverage: a load requested during an erasure, a zeroize during a load and during context reads, an injection requested during a load and a double error in the job of a generated IV were not exercised | TC-KT-05 and TC-KT-07 extended |
| The paced scrubbers (`ScrubPeriod_g` > 0) had never been simulated or synthesised, the documented range allowed periods below the resolution of 1 ms, and `KeyBits_g` was not checked | `k256_n4_paced` runs every test at 1 MHz with a scrub pass every 2 ms (the clock of the bench follows `ClkFreqHz_g`); `lint/synth_check.py` synthesises a period of 1 ms; range corrected; assertion KT-IF-06 |

## 3. Generic values

Simulated: the VUnit configurations of `ocr_key_table_tb`; the clock of the bench runs at `ClkFreqHz_g`. Synthesised:
the configurations of `lint/synth_check.py` (`ghdl --synth`, no latch) through `ocr_core`. The key table does not bring
the pass and overrun outputs of the scrubbers out.

| Generic | Declared range | Simulated | Synthesised |
| --- | --- | --- | --- |
| `KeyBits_g` | 128, 192, 256 | 128, 192, 256 | 128, 192, 256 |
| `NumKeys_g` | 1 to 256 | 1, 3, 4, 16, 256 | 1, 4, 8, 16, 256 |
| `ClkFreqHz_g` | ≥ 1000 when `ScrubPeriod_g` > 0 | 100.0e6, 1.0e6 | 100.0e6 |
| `ScrubPeriod_g` | 0.0 or ≥ 0.001 | 0.0, 0.002 | 0.0, 0.001 |
