# ocr_gcm: Specification

## 1. Overview

`ocr_gcm` is the GCM data path of OpenCrypto: the input parser and the counter blocks (IN-1, IN-2), the keystream with
the AES engine (AE-1), the GCTR combiner (CT-1), GHASH (GH-1), the tag stage (TG-1), the output assembly, the release
buffer and the status (OU-1 to OU-3). It encrypts or decrypts every message of the input stream with the key, the
hash subkey and the IV of the job of the message, and reports one status per message. The key table supplies the jobs
and uses the hash subkey port when it loads a key.

## 2. Requirements

### 2.1 Interfaces

| ID | Requirement | Clauses |
| --- | --- | --- |
| GC-IF-01 | The input stream shall carry messages of `DataWidth_g` bits (16, 32, 64 or 128) with `Keep`, `Last` at the end of a message and the section in `User` ("01" AAD, "00" DATA, "10" TAG, "11" IV); a section starts with a new beat, byte lane 0 holds the first byte of a beat, only the last beat of a section is partial with its byte enables contiguous from lane 0, and a section of one beat without byte enable is empty. | GCM 5.2.1.1 |
| GC-IF-02 | One job per message (direction, key, hash subkey, IV, IV section flag, context error, key slot) shall be taken in the order of the messages. | none (architecture section 6) |
| GC-IF-03 | The output stream shall carry one message per input message in the format of GC-IF-01 with `User(2)` the error flag on the last beat ('1' when the status is not OK); every output beat carries at least one byte, except the one beat of a message without any byte. | none (section 6) |
| GC-IF-04 | One status per message (code, direction, key slot, IV, numbers of AAD and DATA bytes) shall be output in the order of the messages; a status event shall mark every status when it is written. | none (D11) |
| GC-IF-05 | A request on the hash subkey port shall return CIPH<sub>K</sub>(0<sup>128</sup>) for its key and shall be served before the requests of the messages; the result shall be held until it is taken. | GCM 7.1, 7.2 |
| GC-IF-06 | The reset shall return the data path from any state to the reception of a new job and a new message within one clock cycle, with no output, status or hash subkey result pending. | none (D13) |
| GC-IF-07 | Every interface shall support back-pressure: a partner that is not ready shall stall the data path for any time without loss or change of any byte, flag or status. | none (P2) |

### 2.2 Input parser and counter blocks (IN-1, IN-2)

| ID | Requirement | Clauses |
| --- | --- | --- |
| GC-IN-01 | A message of an encryption job shall be processed with GCM-AE and a message of a decryption job with GCM-AD; a message without DATA section is GMAC. | GCM 5.2, 10; CCSDS 4.3.2 |
| GC-IN-02 | A message shall fail with FORMAT when its sections are not in the order AAD, DATA, TAG, when it has an IV section, a TAG section in an encryption, no TAG section in a decryption or a TAG section of other than 16 bytes, or when its byte enables violate GC-IF-01; the data path shall cut the message at the error and process the next message correctly. | GCM 7.2 |
| GC-IN-03 | A message whose job carries a context error shall be consumed without AES and GHASH work for its data and shall produce one output beat without byte, with the error flag, and the status of the context error. | none (D12) |
| GC-IN-04 | The supported lengths shall be 96 bits for the IV and 0 to 2<sup>`LenBits_g`</sup> - 1 bytes for AAD and DATA; a longer section shall fail with LENGTH. | GCM 5.2.1.1, 10 |
| GC-CB-01 | The pre-counter block of a message shall be J0 = IV ‖ 0<sup>31</sup> ‖ 1. | GCM 7.1, 7.2 |
| GC-CB-02 | The counter block of DATA block i (i from 1) shall be inc32<sup>i</sup>(J0). | GCM 6.2, 6.5 |

### 2.3 GCTR combiner, GHASH and tag (CT-1, TG-1)

| ID | Requirement | Clauses |
| --- | --- | --- |
| GC-CT-01 | Every DATA byte shall be XORed with the byte of the keystream block of its block at the same position; the last, partial block uses the leftmost bytes of its keystream block; AAD bytes pass unchanged. | GCM 5.3, 6.5, 7.1, 7.2; CCSDS 3.3 |
| GC-CT-02 | GHASH shall run over the AAD and the ciphertext: the output of an encryption, the input of a decryption. | GCM 7.1, 7.2; CCSDS 3.4.1 |
| GC-TG-01 | The tag shall be T = S ⊕ CIPH<sub>K</sub>(J0) with t = 128 bits. | GCM 5.2.1.2, 7.1; CCSDS 3.4.2 |
| GC-TG-02 | A decryption shall fail with AUTH when T differs from its TAG section. | GCM 5.2.2, 7.2 |
| GC-TG-03 | The status code of a message shall be the code of the highest precedence of its errors (ECC, context error, FORMAT, LENGTH, AUTH, OVERFLOW). | none (D11) |

### 2.4 Output assembly, release buffer and status (OU-1 to OU-3)

| ID | Requirement | Clauses |
| --- | --- | --- |
| GC-OU-01 | The output of an encryption shall be the IV section (when the job asks for it), the non-empty AAD section, the non-empty ciphertext and the TAG section of 16 bytes. | GCM 7.1 |
| GC-OU-02 | The output of a decryption shall be the non-empty AAD section and the non-empty plaintext; its last beat shall carry the verdict as the error flag. | GCM 7.2 |
| GC-OU-03 | The TAG section of an encryption that failed shall be all zeros. | none (D12) |
| GC-OU-04 | With `ReleaseBuffer_g` a message shall leave the data path only when its status is OK; a message longer than the buffer shall be dropped with OVERFLOW. | GCM 5.2.2, 7.2 |

### 2.5 Performance and fault tolerance

| ID | Requirement | Clauses |
| --- | --- | --- |
| GC-PF-01 | Within a message every interface shall transfer one beat per clock cycle while its partner is ready; for back-to-back messages the bottleneck side (output of encryptions, input of decryptions) shall transfer one beat per clock cycle after the initial latency, with at most 40 cycles without a beat for any number of messages, for every message length, with the default numbers of AES units and GHASH digits and without release buffer. | none (D3) |
| GC-FT-01 | Every buffer shall be an FT FIFO: a single error is corrected, a double error fails the messages whose data it held with ECC (in the status FIFO: the status reports ECC; in the release buffer: the message ends with the error flag); every corrected or detected error shall produce an ECC event of its buffer, and every buffer shall take an error injection. | none (P5) |

## 3. Interpretation of the standard

- GCM-AD returns the plaintext or FAIL (GCM 7.2 step 8). Without release buffer the data path streams the plaintext
  and marks a failure on the last beat and in the status, so the consumer discards the message; with the release
  buffer the plaintext of a failed message never leaves the core.
- The bit lengths of AAD, data and IV are multiples of 8 (GCM 5.2.1.1); the stream carries bytes.
- The TAG section has exactly 16 bytes: a received tag of another length fails before the verification (GCM 7.2 step
  1).

## 4. Configuration parameters

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `DataWidth_g` | 32 | 16, 32, 64, 128 | Width of the message streams |
| `KeyBits_g` | 256 | 128, 192, 256 | Key length |
| `AesUnits_g` | 0 | 0, ceil(Nr / R) to Nr | Round units of the AES engine; 0 selects ceil(2 Nr / (R + 1)) |
| `GhashDigit_g` | 0 | 0, `DataWidth_g` to 128 | GHASH digit; 0 selects 128 for 64 and 128 bits, 64 otherwise |
| `LenBits_g` | 32 | 8 to 32 | Width of the byte counts |
| `SlotBits_g` | 2 | 1 to 8 | Width of the key slot number |
| `ReleaseBuffer_g` | false | | Release buffer at the output |
| `ReleaseBytes_g` | 4096 | power of two, at least 16 beats | Size of the release buffer in bytes |
