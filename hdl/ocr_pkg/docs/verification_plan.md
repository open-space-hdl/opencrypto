# ocr_pkg: Verification Plan

## 1. Overview

The testbench calls the functions of the package directly. Expected values are the examples of FIPS 197 (Appendix A,
B and C, the multiplication examples of section 4.2), blocks of the AES of pycryptodome, the results S of GHASH of the
test cases of the GCM specification (computed with pycryptodome) and a bit-serial implementation of Algorithm 1 of
GCM 6.3 in the testbench.

## 2. Test configuration

| Testbench | Harness | DUT and environment |
| --- | --- | --- |
| `ocr_pkg_tb` | none | The functions of `ocr_pkg`; vector files `ecb.txt` (FIPS 197 examples, zero and all-ones keys, 46 random blocks per key length) and `gcm_spec.txt` (test cases of the GCM specification with 96-bit IVs of all key lengths) |

Simulator: GHDL; QuestaSim for code coverage.

## 3. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_sbox` (TC-PK-01) | S({53}) = {ed}, S({00}) = {63}, S({ff}) = {16}; the 256 outputs are a permutation | PK-AES-02 |
| `test_gf8` (TC-PK-02) | {57} · {02}, {04}, {08}, {10} and {57} · {13} = {fe} of FIPS 197 4.2.1; Rcon[1], [8], [9], [10] | PK-AES-01, PK-AES-06 |
| `test_round` (TC-PK-03) | Round 1 of FIPS 197 Appendix B: SubBytes, ShiftRows, MixColumns, AddRoundKey, and the last round without MixColumns | PK-AES-02, PK-AES-03, PK-AES-04, PK-AES-05 |
| `test_key_expansion` (TC-PK-04) | All words of the key expansion examples of FIPS 197 Appendix A.1 to A.3 that the text of the standard lists (128, 192 and 256 bits), produced with `aesKeyFirst` and `aesKeyStep` as the round units use them | PK-AES-06 |
| `test_cipher` (TC-PK-05) | The cipher composed of `aesRound` and the key expansion against FIPS 197 Appendix B and C and 150 blocks of pycryptodome for all key lengths | PK-AES-01, PK-AES-02, PK-AES-03, PK-AES-04, PK-AES-05, PK-AES-06 |
| `test_gf_mul` (TC-PK-06) | 32 products: `gfMul` and the Horner scheme of `gfMulDigit` with digits of 32, 64 and 128 bits against Algorithm 1; multiplication by the unit element | PK-GF-01, PK-GF-02 |
| `test_ghash` (TC-PK-07) | GHASH of A ‖ 0 ‖ C ‖ 0 ‖ [len(A)]<sub>64</sub> ‖ [len(C)]<sub>64</sub> with `gfMul` against S of the twelve test cases of the GCM specification | PK-GF-01, PK-FMT-01 |
| `test_byte_order` (TC-PK-08) | Bytes of a block, beats of 2, 4, 8 and 16 bytes and back, byte enables | PK-FMT-01 |
| `test_status` (TC-PK-09) | Precedence of every pair of neighbouring status codes; every pair of codes at run time: the merge is symmetric and keeps the higher precedence | PK-STS-01 |
| `test_defaults` (TC-PK-10) | Nr of the key lengths, default and minimum numbers of AES units and default GHASH digits of the architecture (D4, D5) | PK-GEN-01 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| PK-AES-01 | TC-PK-02, TC-PK-05 |
| PK-AES-02 | TC-PK-01, TC-PK-03, TC-PK-05 |
| PK-AES-03, PK-AES-04, PK-AES-05 | TC-PK-03, TC-PK-05 |
| PK-AES-06 | TC-PK-02, TC-PK-04, TC-PK-05 |
| PK-GF-01 | TC-PK-06, TC-PK-07 |
| PK-GF-02 | TC-PK-06 |
| PK-FMT-01 | TC-PK-07, TC-PK-08 |
| PK-STS-01 | TC-PK-09 |
| PK-GEN-01 | TC-PK-10 |
