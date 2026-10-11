# ocr_ghash: Specification

## 1. Overview

`ocr_ghash` computes GHASH (block GH-1 of the architecture) over the AAD and the ciphertext of every message: it
forms the blocks of A ‖ 0<sup>v</sup> ‖ C ‖ 0<sup>u</sup> ‖ [len(A)]<sub>64</sub> ‖ [len(C)]<sub>64</sub> from the
beats of the hash stream, multiplies them in GF(2<sup>128</sup>) with the hash subkey of the message and delivers S
(GCM 7.1 step 5) with the byte counts of both sections.

## 2. Requirements

### 2.1 Interfaces

| ID | Requirement | Clauses |
| --- | --- | --- |
| GH-IF-01 | The hash stream shall carry beats of `DataWidth_g` bits (16, 32, 64 or 128) with `Keep`, the section flag `Aad` (AAD or ciphertext), `SecLast` and `MsgLast`; a message has at least one beat, an empty section is one beat without byte enable; valid bytes are contiguous from lane 0 and only the last beat of a section is partial. | none (architecture section 6) |
| GH-IF-02 | The hash subkey of every message shall come on its own stream, in the order of the messages; S and the byte counts shall leave on a valid / ready output, one per message, in the order of the messages. | none |
| GH-IF-03 | The reset shall clear the GHASH of all messages in progress within one clock cycle. | none (D13) |

### 2.2 Function

| ID | Requirement | Clauses |
| --- | --- | --- |
| GH-FN-01 | The AAD and the ciphertext shall each be padded with zero bits to a multiple of 128 bits, the bytes of lanes without byte enable being zero, and followed by the length block [8 len(A)]<sub>64</sub> ‖ [8 len(C)]<sub>64</sub>. | GCM 7.1, 7.2 |
| GH-FN-02 | The blocks shall be multiplied with the product of GCM 6.3. | GCM 6.3 |
| GH-FN-03 | S shall be Y<sub>m</sub> of Y<sub>i</sub> = (Y<sub>i-1</sub> ⊕ X<sub>i</sub>) · H with Y<sub>0</sub> = 0<sup>128</sup> over the blocks of the message. | GCM 6.4 |
| GH-FN-04 | The byte counts of the AAD and of the ciphertext shall be delivered with S; a section of more than 2<sup>`LenBits_g`</sup> - 1 bytes shall set the length error, with the byte count saturated. | GCM 5.2.1.1 |
| GH-FN-05 | An input beat with `In_Err` or a hash subkey with `H_Err` shall set the ECC error flag of its message. | none (P5) |

### 2.3 Performance

| ID | Requirement | Clauses |
| --- | --- | --- |
| GH-PF-01 | Without back-pressure on its output the GHASH shall take the beats of back-to-back messages within max(b + 1, s · (n + 1)) clock cycles per message, b being the beats, n the blocks of AAD and ciphertext and s = 128 / `Digit_g` the cycles of the multiplier per block. | none (D5) |

## 3. Interpretation of the standard

- The digit-serial multiplication is an equivalent set of steps of the product of GCM 6.3 (GCM 6, introduction):
  every block is multiplied in s cycles with digits of `Digit_g` bits of Y<sub>i-1</sub> ⊕ X<sub>i</sub>, from the
  highest degree.
- The supported lengths of AAD and ciphertext are 0 to 2<sup>`LenBits_g`</sup> - 1 bytes (GCM 5.2.1.1 allows the
  restriction); the length block holds the bit lengths.

## 4. Configuration parameters

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `DataWidth_g` | 32 | 16, 32, 64, 128 | Width of the hash stream |
| `Digit_g` | 64 | `DataWidth_g` to 128, power of two | Bits of the first operand per multiplier cycle |
| `LenBits_g` | 32 | 8 to 32 | Width of the byte counts |
