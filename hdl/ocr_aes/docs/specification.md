# ocr_aes: Specification

## 1. Overview

`ocr_aes` is the AES engine of OpenCrypto (block AE-1 of the architecture): the forward cipher of FIPS 197 on one
block per request, with the key of every request. `Units_g` iterative round units, each performing one round per
clock cycle, share the requests in round robin, so that the engine encrypts `Units_g` blocks in Nr clock cycles.
The GCM data path uses it for the keystream blocks, for CIPH<sub>K</sub>(J0) and for the hash subkey.

## 2. Requirements

### 2.1 Interfaces

| ID | Requirement | Clauses |
| --- | --- | --- |
| AE-IF-01 | The engine shall accept a request (`In_Key`, `In_Block`, `In_Tag`) per clock cycle while `In_Ready` is set, and output the result with the tag of its request after exactly Nr + 1 clock cycles, in the order of the requests, with no back-pressure. | none (architecture D4, D6) |
| AE-IF-02 | The reset shall end all blocks in the units within one clock cycle; no result of a block of before the reset shall be output. | none (D13) |

### 2.2 Cipher

| ID | Requirement | Clauses |
| --- | --- | --- |
| AE-FN-01 | The engine shall compute the cipher of FIPS 197 (AddRoundKey with round key 0, Nr - 1 rounds of SubBytes, ShiftRows, MixColumns and AddRoundKey, and a last round without MixColumns) with Nr = 10, 12 or 14 for the key length `KeyBits_g` of 128, 192 or 256 bits, on the input block and output block in the byte order of the standard. | AES 3.1, 3.2, 3.3, 3.4, 3.5, 5.1, 5.1.4, 6.1; GCM 5.1; CCSDS 3.1, 3.2.1, 3.2.2 |
| AE-FN-02 | The round keys shall be derived from the key of each request by the key expansion of FIPS 197 while the block passes the rounds; any key value shall be accepted and consecutive requests may carry different keys. | AES 5.2, 6.2 |
| AE-FN-03 | The key length and the number of units shall be generics; `Units_g` shall be 1 to Nr. | AES 6.3 |
| AE-FN-04 | The engine shall output the same blocks as the cipher of FIPS 197 for all inputs. | AES 6.4 |

### 2.3 Performance

| ID | Requirement | Clauses |
| --- | --- | --- |
| AE-PF-01 | With requests in every clock cycle the engine shall accept `Units_g` requests in every Nr clock cycles. | none (D4) |

## 3. Interpretation of the standard

- FIPS 197 6.4 allows any implementation that produces the outputs of the standard. The engine computes the round
  keys from the key with every block (key expansion on the fly) instead of storing an expanded key: a round unit
  carries the window of the last Nk words of the expansion together with the State.
- The inverse cipher (FIPS 197 5.3) is not implemented: GCM uses the forward cipher for both directions (GCM 5.1,
  7.2).

## 4. Configuration parameters

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `KeyBits_g` | 256 | 128, 192, 256 | Key length (Nk = 4, 6, 8; Nr = 10, 12, 14) |
| `Units_g` | 14 | 1 to Nr | Number of round units; throughput `Units_g` / Nr blocks per clock cycle |
| `TagWidth_g` | 2 | 1 to any | Width of the tag that travels with every request |
