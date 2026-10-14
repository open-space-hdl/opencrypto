# ocr_key_table: Verification Plan

## 1. Overview

The harness loads the key slots of a vector file through the load port, drives the contexts of the vector file and
checks every job: direction, key, hash subkey, IV, IV section flag, context error and slot. The hash subkey port is
served by an AES model that returns the hash subkey of the key from the vector files, computed with pycryptodome; it
also counts the requests. The expected job of every context (error code, IV, generated IVs following the invocation
counter of the slot) comes from the vector generator. The test sequencer queries slots, drives zeroize, reset and
the error injection and counts the ECC events.

## 2. Test configuration

| Testbench | Harness | DUT and environment |
| --- | --- | --- |
| `ocr_key_table_tb` | `ocr_key_table_th` | `ocr_key_table` at 100 MHz with free-running scrubbers (`k256_n4_paced`: at 1 MHz, the clock follows `ClkFreqHz_g`, with one scrub pass every 2 ms, so every 2000 cycles), the context source and the job checker of vector set 0, the AES model of the hash subkey port; random stall cycles on contexts and jobs |

| Configuration | Key | Slots | Tests |
| --- | --- | --- | --- |
| `k256_n4` | 256 | 4 | TC-KT-01 to TC-KT-10 |
| `k128_n1` | 128 | 1 | TC-KT-01 to 05, 07 to 10 |
| `k192_n3` | 192 | 3 (slot number of 2 bits with one slot out of range) | TC-KT-01 to TC-KT-10 |
| `k256_n16` | 256 | 16 | TC-KT-01 to TC-KT-10 |
| `k128_n256` | 128 | 256 | TC-KT-01 to TC-KT-10 |
| `k256_n4_paced` | 256 | 4, paced scrubbers (`ClkFreqHz_g` 1.0e6, `ScrubPeriod_g` 0.002) | TC-KT-01 to TC-KT-10 |

Vector files per configuration: 300 contexts of loaded, unloaded and out-of-range slots in both directions with both
IV sources (even slots generated IVs, odd slots external IVs); 40 contexts of an empty table; 12 contexts with
generated IVs on a slot loaded with the counter 2<sup>64</sup> - 3; 300 contexts of all slots but the last for the
loads during traffic; the error injection contexts; 100 contexts each with external and with generated IVs for the
throughput. Simulator: GHDL; QuestaSim for code coverage.

## 3. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_erase_after_reset` (TC-KT-01) | After the reset: erasure within `NumKeys_g` + 3 cycles, every slot invalid with zero counter and fixed field, 40 contexts fail with KEY with zero key and hash subkey | KT-MEM-02, KT-RS-01, KT-IF-03 |
| `test_load_query` (TC-KT-02) | Load of every slot of the vector file: one hash subkey request per load, the query returns valid, construction, fixed field and counter; a load of a slot out of range (`k128_n1`, `k192_n3`) is accepted without request and leaves every slot unchanged; queries in consecutive cycles are all answered | KT-IF-06, KT-IF-02 to 04, KT-LD-01, KT-IV-03 |
| `test_resolve` (TC-KT-03) | 300 contexts with 30 % stall cycles: every job checked (KEY, IV_MODE, OK, generated IVs); afterwards the counter of every generator slot equals its loaded value plus its generated IVs | KT-IF-01, KT-RS-01, KT-RS-02, KT-IV-01, KT-IV-03 |
| `test_exhaustion` (TC-KT-04) | Slot loaded with the counter 2<sup>64</sup> - 3: two generated IVs, then IV_EXHAUSTED; the query reports the slot exhausted with the counter 2<sup>64</sup> - 1 | KT-IV-02 |
| `test_zeroize` (TC-KT-05) | Zeroize of a loaded table: every slot invalid, 40 contexts fail with KEY; reload and 300 contexts pass; a load requested right after a zeroize waits for the erasure, a zeroize during a load erases the slot after the load, a zeroize while contexts are resolved starts after the read in flight | KT-MEM-02, KT-RS-01 |
| `test_load_during_traffic` (TC-KT-06) | 20 loads of the last slot while 300 contexts of the other slots are resolved: every job and every counter correct | KT-LD-02 |
| `test_ecc` (TC-KT-07) | Single and double errors injected into the key, H and IV word of a load and into a job: single errors give an OK job with an SEC event, double errors a job with ECC and zero key and H with a DED event, also for a job with a generated IV (no IV section flag); an injection requested during a load goes into the next load | KT-FT-01, KT-MEM-01 |
| `test_scrub` (TC-KT-08) | Single error injected into the key word of a slot that no context reads: the scrubber corrects it with an SEC event; the next read has no error; with paced scrubbers within one scrub period | KT-FT-01, KT-MEM-01 |
| `test_throughput` (TC-KT-09) | 100 contexts without stall cycles: N - 1 cycles from the first to the last context with external IVs, 2 (N - 1) cycles with generated IVs | KT-PF-01 |
| `test_reset` (TC-KT-10) | Reset during a load, right after its acceptance and while it waits for the hash subkey: every slot is erased | KT-IF-05, KT-MEM-02 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| KT-IF-01 | TC-KT-03 |
| KT-IF-02 | TC-KT-02 |
| KT-IF-03 | TC-KT-01, TC-KT-02 |
| KT-IF-04 | TC-KT-02 |
| KT-IF-05 | TC-KT-10 |
| KT-IF-06 | TC-KT-02 |
| KT-MEM-01 | TC-KT-07, TC-KT-08 |
| KT-MEM-02 | TC-KT-01, TC-KT-05, TC-KT-10 |
| KT-LD-01 | TC-KT-02 |
| KT-LD-02 | TC-KT-06 |
| KT-RS-01 | TC-KT-01, TC-KT-03, TC-KT-05 |
| KT-RS-02 | TC-KT-03 |
| KT-IV-01 | TC-KT-03 |
| KT-IV-02 | TC-KT-04 |
| KT-IV-03 | TC-KT-02, TC-KT-03 |
| KT-PF-01 | TC-KT-09 |
| KT-FT-01 | TC-KT-07, TC-KT-08 |

Contexts, queries and loads of slots out of range run in the configurations whose slot number has unused values
(`k128_n1`, `k192_n3`); contexts of unloaded slots run in every configuration.

KT-IF-06 is checked for the legal key lengths by every configuration; an illegal `KeyBits_g` stops the elaboration
with an assertion of severity failure, which a simulation run cannot pass by construction.
