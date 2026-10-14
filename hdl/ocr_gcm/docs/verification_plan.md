# ocr_gcm: Verification Plan

## 1. Overview

The harness drives the jobs and the messages of a vector file and checks every output beat and every status against
the vector file: a job source gives the key and the hash subkey of the key slot of each message, a message source the
input sections, a message sink compares every output byte, the byte enables, the sections, `Last` and the error
flag, a status sink every status. The expected values come from the AES-GCM of pycryptodome and the test cases of
the GCM specification; the vector files do not depend on the data width.

## 2. Test configuration

| Testbench | Harness | DUT and environment |
| --- | --- | --- |
| `ocr_gcm_tb` | `ocr_gcm_th` | `ocr_gcm` at 100 MHz with a 3-bit key slot, the job source, message source, message sink and status sink of vector set 0; the test sequencer drives the hash subkey port and the error injection and counts the ECC events |

| Configuration | Width | Key | Other generics | Tests |
| --- | --- | --- | --- | --- |
| `w16_aes256`, `w32_aes128`, `w32_aes192`, `w64_aes128`, `w64_aes256`, `w128_aes128`, `w128_aes192`, `w128_aes256` | 16 to 128 | 128 to 256 | defaults | TC-GC-01 to TC-GC-12, TC-GC-15 |
| `w32_aes256_min` | 32 | 256 | 4 AES units, 32-bit GHASH digit (minimum) | TC-GC-01 to 05, 08 to 12, 15 |
| `w32_aes256_max` | 32 | 256 | 14 AES units, 128-bit GHASH digit (maximum) | TC-GC-01 to TC-GC-12, TC-GC-15 |
| `w32_aes256_rel`, `w128_aes256_rel` | 32, 128 | 256 | release buffer of 512 and 1024 bytes | TC-GC-04, 07 to 10, 14 |
| `w32_aes256_rel64` | 32 | 256 | release buffer of 64 bytes (16 beats, the minimum) | TC-GC-14 |
| `w32_aes128_len8` | 32 | 128 | 8-bit byte counts | TC-GC-13 |

Vector files per key length: the test cases of the GCM specification (encryption, decryption), 120 random encryptions,
120 random decryptions, 150 random messages of both directions with 30 % modified tags, AAD or ciphertexts, 80
encryptions with generated IVs, 150 messages each for the throughput, 16 format errors each followed by a correct
message, 7 rejected jobs, the error injection messages, 60 messages with sections up to 500 bytes for the 8-bit byte
counts, 60 messages for the release buffer and 200 one-beat and 200 short messages for the back-pressure. The random
messages start with the boundary cases: absent, empty and one-byte sections, sections of 15, 16, 17 and 31 bytes.
Simulator: GHDL; QuestaSim for code coverage.

## 3. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_gcm_spec` (TC-GC-01) | The test cases of the GCM specification of the key length, encryption and decryption | GC-IF-01 to 04, GC-IN-01, GC-CB-01, GC-CB-02, GC-CT-01, GC-CT-02, GC-TG-01, GC-OU-01, GC-OU-02 |
| `test_encrypt` (TC-GC-02) | 120 random encryptions with 30 % stall cycles on every model | GC-IF-01 to 04, GC-IN-01, GC-IN-04, GC-CB-01, GC-CB-02, GC-CT-01, GC-CT-02, GC-TG-01, GC-OU-01 |
| `test_decrypt` (TC-GC-03) | 120 random decryptions with correct tags, 30 % stall cycles | GC-IF-01 to 04, GC-IN-01, GC-CT-01, GC-CT-02, GC-TG-01, GC-TG-02, GC-OU-02 |
| `test_mixed` (TC-GC-04) | 150 messages of both directions on 3 keys; modified tags, AAD and ciphertexts fail with AUTH and the error flag; GMAC messages | GC-IN-01, GC-TG-02, GC-TG-03, GC-OU-02 |
| `test_iv_section` (TC-GC-05) | 80 encryptions whose jobs ask for the IV section: IV section in front of the AAD | GC-OU-01 |
| `test_throughput_encrypt` (TC-GC-06) | 150 back-to-back encryptions without stall cycles: at most 40 cycles without output beat | GC-PF-01 |
| `test_throughput_decrypt` (TC-GC-07) | 150 back-to-back decryptions without stall cycles: at most 40 cycles without input beat | GC-PF-01 |
| `test_format` (TC-GC-08) | AAD after DATA, IV section, TAG in an encryption, decryption without TAG, tags of 15, 17 and 20 bytes, partial and empty beats inside a section, byte enables not contiguous, DATA after TAG; each followed by a correct message | GC-IN-02, GC-TG-03, GC-OU-03 |
| `test_reject` (TC-GC-09) | Jobs with the context errors KEY, IV_MODE, IV_EXHAUSTED and ECC, both directions, each followed by a correct message; a rejected job with the IV section flag (no IV section), then encryptions with generated IVs directly after a rejected message and after a decryption | GC-IN-03 |
| `test_ecc` (TC-GC-10) | For every FT buffer a single and a double error injected into the next entry, encryption and decryption, one message at a time: single errors corrected with an ECC event, double errors fail with ECC (status FIFO: status only; release buffer: error flag) | GC-FT-01, GC-OU-03, GH-FN-05 |
| `test_hash_subkey` (TC-GC-11) | 40 hash subkey requests while 150 messages pass: the results are CIPH<sub>K</sub>(0<sup>128</sup>), every second one is taken only five cycles after it is valid and held until then | GC-IF-05 |
| `test_reset` (TC-GC-12) | Reset while messages are in the data path; all messages from the next one on are correct | GC-IF-06 |
| `test_length` (TC-GC-13) | Sections up to 500 bytes with 8-bit byte counts: LENGTH for every section above 255 bytes, tag of an encryption zeros, saturated byte counts | GC-IN-04, GC-TG-03, GC-OU-03 |
| `test_release` (TC-GC-14) | Release buffer: small and large messages, 30 % of the decryptions with a modified tag: only OK messages leave, too long ones report OVERFLOW; with the buffer of 16 beats the messages of exactly 16 sectioned output beats leave and those of 17 beats report OVERFLOW, in both directions | GC-OU-04, GC-OU-05 |
| `test_backlog` (TC-GC-15) | 200 one-beat encryptions without stall cycles; 200 short messages of every kind (external and generated IVs, decryptions with 20 % modified tags, absent and empty sections) without stall cycles, then with a sink and a status sink that are ready in 5 % and 3 % of the cycles, then with a status sink that is ready in 1 % of the cycles: the buffers inside the data path fill, every byte and status is correct | GC-IF-07, GC-IN-01, GC-OU-01, GC-OU-02 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| GC-IF-01 to GC-IF-04 | TC-GC-01, TC-GC-02, TC-GC-03 |
| GC-IF-05 | TC-GC-11 |
| GC-IF-06 | TC-GC-12 |
| GC-IF-07 | TC-GC-02 to TC-GC-05, TC-GC-15 |
| GC-IN-01 | TC-GC-01 to TC-GC-04 |
| GC-IN-02 | TC-GC-08 |
| GC-IN-03 | TC-GC-09 |
| GC-IN-04 | TC-GC-02, TC-GC-13 |
| GC-CB-01, GC-CB-02 | TC-GC-01, TC-GC-02 |
| GC-CT-01, GC-CT-02 | TC-GC-01, TC-GC-02, TC-GC-03 |
| GC-TG-01 | TC-GC-01, TC-GC-02, TC-GC-03 |
| GC-TG-02 | TC-GC-03, TC-GC-04 |
| GC-TG-03 | TC-GC-04, TC-GC-08, TC-GC-13 |
| GC-OU-01 | TC-GC-01, TC-GC-02, TC-GC-05 |
| GC-OU-02 | TC-GC-01, TC-GC-03, TC-GC-04 |
| GC-OU-03 | TC-GC-08, TC-GC-10, TC-GC-13 |
| GC-OU-04 | TC-GC-14 |
| GC-OU-05 | TC-GC-14 |
| GC-PF-01 | TC-GC-06, TC-GC-07 |
| GC-FT-01 | TC-GC-10 |

GC-OU-05 is checked for its minimum by `w32_aes256_rel64` and for further legal values by the other configurations
with release buffer; the maximum of 65536 bytes is elaborated and synthesised by `lint/synth_check.py`. An illegal
`ReleaseBytes_g` stops the elaboration with an assertion of severity failure, which a simulation run cannot pass by
construction.
