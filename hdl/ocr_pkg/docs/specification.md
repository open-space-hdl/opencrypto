# ocr_pkg: Specification

## 1. Overview

`ocr_pkg` holds the common functions of OpenCrypto (block CM-1 of the architecture): the transformations of the AES
cipher and one step of its key expansion (FIPS 197), the multiplication in GF(2<sup>128</sup>) of GCM (NIST SP
800-38D), the byte order of blocks and stream beats, the section and status codes of the message format and the
defaults of the generics. The AES engine and GHASH are built from these functions; they are combinational and
synthesizable.

## 2. Requirements

### 2.1 AES transformations

| ID | Requirement | Clauses |
| --- | --- | --- |
| PK-AES-01 | `aesXtime` shall multiply a byte by x modulo m(x) = x<sup>8</sup> + x<sup>4</sup> + x<sup>3</sup> + x + 1; byte addition is the XOR. | AES 4.1, 4.2 |
| PK-AES-02 | `aesSbox` and `aesSubBytes` shall implement the S-box of SubBytes for every byte value and for the 16 bytes of a State. | AES 5.1.1 |
| PK-AES-03 | `aesShiftRows` shall rotate row r of the State by r bytes to the left, with byte r + 4c of a block in row r and column c. | AES 3.4, 5.1.2 |
| PK-AES-04 | `aesMixColumns` shall multiply every column by a(x) = {03}x<sup>3</sup> + {01}x<sup>2</sup> + {01}x + {02} modulo x<sup>4</sup> + 1. | AES 4.3, 5.1.3 |
| PK-AES-05 | `aesRound` shall apply SubBytes, ShiftRows, MixColumns and AddRoundKey, and leave out MixColumns in the last round. | AES 5.1 |
| PK-AES-06 | `aesKeyFirst`, `aesKeyStep` and `aesKeyCtlTable` shall produce the words of the key expansion for keys of 128, 192 and 256 bits in steps of four words, with SubWord, RotWord and Rcon where the key expansion applies them. | AES 5.2 |

### 2.2 GF(2<sup>128</sup>)

| ID | Requirement | Clauses |
| --- | --- | --- |
| PK-GF-01 | `gfMul` shall compute the product X · Y of GCM with the reduction polynomial of R = 11100001 ‖ 0<sup>120</sup>, bit 127 of a block being the coefficient of u<sup>0</sup>. | GCM 6.3 |
| PK-GF-02 | `gfMulDigit` shall compute z · u<sup>D</sup> + d · h modulo the polynomial of R for a digit d of D = 32, 64 or 128 bits, so that D-bit digits processed from the highest degree give the product of GCM 6.3. | GCM 6.3 |

### 2.3 Formats and generics

| ID | Requirement | Clauses |
| --- | --- | --- |
| PK-FMT-01 | `blockByte`, `blockToBeat`, `beatToBlock` and `keepOf` shall map byte k · B + j of a block (byte 0 leftmost) to lane j of beat k of a stream of B bytes per beat. | AES 3.1 |
| PK-STS-01 | `stsMerge` shall return the status code of higher precedence in the order ECC, KEY, IV_MODE, IV_EXHAUSTED, FORMAT, LENGTH, AUTH, OVERFLOW, OK. | none (architecture D11) |
| PK-GEN-01 | `aesDefaultUnits` shall return ceil(2 Nr / (R + 1)), `aesMinUnits` ceil(Nr / R) and `ghashDefaultDigit` 128 for 64 and 128 bits and 64 otherwise, with R = 128 / W. | AES 6.3 |

## 3. Interpretation of the standard

- A block is the bit string of the standards with its leftmost byte in bits 127:120, so that the hexadecimal
  examples of FIPS 197 and of the GCM specification are VHDL literals. The bit x<sub>0</sub> of GCM 6.3 is bit 127.
- The key expansion is computed in steps of four words because a round uses four words of round key. Within four
  consecutive words at most one word needs SubWord (for Nk = 4 the first one, for Nk = 6 the word whose index is a
  multiple of 6, for Nk = 8 the word whose index is 0 or 4 modulo 8), so a step needs one SubWord.

## 4. Configuration parameters

The package has no generics. The functions take the key length, the data width or the digit width as parameters.
