# ocr_aes: Verification Plan

## 1. Overview

A request source in the harness sends the blocks of a vector file to the engine, a result checker compares every
result with the expected block, its tag with the index of the request and its latency with Nr + 1 clock cycles.
Expected values are the examples of FIPS 197 (Appendix B and C) and blocks of the AES of pycryptodome; every request
carries a new key.

## 2. Test configuration

| Testbench | Harness | DUT and environment |
| --- | --- | --- |
| `ocr_aes_engine_tb` | `ocr_aes_engine_th` | `ocr_aes_engine` with a 12-bit tag at 100 MHz; request source and result checker; vector file per key length: FIPS 197 examples, keys and blocks of all zeros and all ones, 196 random keys and blocks |

VUnit configurations `aes128_u1`, `aes128_u3`, `aes128_u5`, `aes128_u7`, `aes128_u8`, `aes128_u9`, `aes128_u10`,
`aes192_u3`, `aes192_u11`, `aes192_u12`, `aes256_u2`, `aes256_u4`, `aes256_u6`, `aes256_u13` and `aes256_u14` run
every test with every key length, one unit, the minimum and default numbers of the data widths, the full number of
rounds and every number of units from 1 to 14. Simulator: GHDL; QuestaSim for code coverage.

## 3. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_fips197` (TC-AE-01) | The examples of FIPS 197 of the key length and the all-zeros and all-ones keys and blocks, one request at a time (95 % cycles without request) | AE-IF-01, AE-FN-01, AE-FN-02, AE-FN-03, AE-FN-04 |
| `test_vectors` (TC-AE-02) | All 200 blocks with 30 % cycles without request; a new key with every request | AE-IF-01, AE-FN-01, AE-FN-02, AE-FN-04 |
| `test_throughput` (TC-AE-03) | Requests in every cycle: the span from the first to the last accepted request is exactly floor((N - 1) / U) · Nr + (N - 1) mod U cycles | AE-IF-01, AE-PF-01 |
| `test_reset` (TC-AE-04) | Reset while blocks are in the units: no result of these blocks; all later blocks correct | AE-IF-02 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| AE-IF-01 | TC-AE-01, TC-AE-02, TC-AE-03 |
| AE-IF-02 | TC-AE-04 |
| AE-FN-01, AE-FN-02, AE-FN-04 | TC-AE-01, TC-AE-02 |
| AE-FN-03 | TC-AE-01 |
| AE-PF-01 | TC-AE-03 |
