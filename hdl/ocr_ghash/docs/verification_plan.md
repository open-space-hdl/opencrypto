# ocr_ghash: Verification Plan

## 1. Overview

A beat source in the harness sends the AAD and the ciphertext of the messages of a vector file (the ciphertext of an
encryption is its expected output), an H source the hash subkey of the key slot of every message, and a checker
compares S, the byte counts and the length error with the vector file. The expected S of every message is computed
from the tag of pycryptodome: S = T ⊕ CIPH<sub>K</sub>(J0) (GCM 7.1 step 6).

## 2. Test configuration

| Testbench | Harness | DUT and environment |
| --- | --- | --- |
| `ocr_ghash_tb` | `ocr_ghash_th` | `ocr_ghash` at 100 MHz, beat source, H source and result checker; vector files: the test cases of the GCM specification of all key lengths in both directions, 150 random messages in both directions with modified inputs (3 key slots), 40 long messages (sections up to 600 bytes) |

VUnit configurations `w16_d16`, `w16_d64`, `w16_d128`, `w32_d32`, `w32_d64`, `w64_d64`, `w64_d128`, `w128_d128` run
the tests with every data width and its smallest, default and largest digit; `w32_d64_len8` runs the length test
with 8-bit byte counts. Simulator: GHDL; QuestaSim for code coverage.

## 3. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_gcm_spec` (TC-GH-01) | S of the twelve test cases of the GCM specification, encryption and decryption | GH-IF-01, GH-IF-02, GH-FN-01, GH-FN-02, GH-FN-03, GH-FN-04 |
| `test_random` (TC-GH-02) | 150 messages with absent, empty, partial and full sections, 30 % cycles without beat and 50 % cycles without ready of the result | GH-IF-01, GH-IF-02, GH-FN-01, GH-FN-02, GH-FN-03, GH-FN-04 |
| `test_throughput` (TC-GH-03) | The 150 messages back-to-back: the cycles from the first to the last beat are at most the sum of max(b + 1, s · (n + 1)) of the messages | GH-PF-01 |
| `test_length_error` (TC-GH-04) | Sections of up to 600 bytes with 8-bit byte counts: the length error and the saturated counts for every message above 255 bytes, S of the others | GH-FN-04 |
| `test_reset` (TC-GH-05) | Reset during a message: no result of it; all later messages correct | GH-IF-03 |

GH-FN-05 (ECC error flag) is verified with the error injection of the GCM data path (`ocr_gcm`, TC-GC-10), whose FT
buffers drive `In_Err` and `H_Err`.

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| GH-IF-01, GH-IF-02, GH-FN-01, GH-FN-02, GH-FN-03 | TC-GH-01, TC-GH-02 |
| GH-IF-03 | TC-GH-05 |
| GH-FN-04 | TC-GH-01, TC-GH-02, TC-GH-04 |
| GH-FN-05 | TC-GC-10 (`ocr_gcm`) |
| GH-PF-01 | TC-GH-03 |
