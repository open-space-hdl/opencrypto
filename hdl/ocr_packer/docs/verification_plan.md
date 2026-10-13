# ocr_packer: Verification Plan

## 1. Overview

The message source of the harness sends the sections of the messages of a vector file in the sectioned format of
the output assembly (every section starts with a new beat, the error flag on the last beat of a message whose
expected status is not OK). The message sink in dense mode concatenates the expected sections of every message and
checks every output beat: valid bytes, byte enables, the section of the first byte, `Last` and the error flag.

## 2. Test configuration

| Testbench | Harness | DUT and environment |
| --- | --- | --- |
| `ocr_packer_tb` | `ocr_packer_th` | `ocr_packer` at 100 MHz, message source and dense message sink of vector set 0 |

VUnit configurations `w16`, `w32`, `w64` and `w128` run every test at every data width. Vector files (independent of
the width): 200 messages with sections of up to 70 bytes and 80 messages with sections of up to 300 bytes. Every
message has the sections of an output message of the core (IV, AAD, DATA and TAG, each optional, in this order),
with the boundary cases first: one byte, a message without byte, the section layouts of encryptions with and without
generated IV and of GMAC, empty sections between sections with bytes; 20 % of the messages carry the error flag.
Simulator: GHDL; QuestaSim for code coverage.

## 3. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_pack` (TC-PA-01) | Both vector files with 30 % cycles without valid and without ready, and with 50 % cycles without ready: every output beat as expected | PA-IF-01, PA-FN-01, PA-FN-02, PA-FN-03 |
| `test_backpressure` (TC-PA-02) | 90 % cycles without ready at the output, 80 % cycles without valid at the input, and 50 % on both sides: every output beat as expected | PA-FN-04 |
| `test_throughput` (TC-PA-03) | The 80 long messages without stall cycles: the cycles without input beat are at most the number of messages that need an extra output beat for their last bytes (computed from the section lengths) | PA-PF-01 |
| `test_reset` (TC-PA-04) | Reset in the middle of the messages: no output of the message in progress; every message from the next one on is correct | PA-FN-05 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| PA-IF-01, PA-FN-01, PA-FN-02, PA-FN-03 | TC-PA-01 |
| PA-FN-04 | TC-PA-01, TC-PA-02 |
| PA-FN-05 | TC-PA-04 |
| PA-PF-01 | TC-PA-03 |

The packer behind the GCM data path is verified in `ocr_core` with the dense output (configurations `*_dense` of
the core testbench, CO-FN-07): encryptions, decryptions, generated IVs, context errors, error injection, release
buffer and reset.
