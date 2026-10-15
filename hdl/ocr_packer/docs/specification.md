# ocr_packer: Specification

## 1. Overview

`ocr_packer` is the output packer (block OU-4 of the architecture) of the dense output of `ocr_core`
(`DenseOutput_g`). The output assembly starts every section of a message with a new beat, so a section that does not
end on a beat boundary leaves a partial beat in the middle of the message. The packer closes these gaps: the message
leaves as one gapless byte stream in which only the last beat is partial. The bytes, their order and the error flag
of the message stay unchanged.

## 2. Requirements

### 2.1 Interfaces

| ID | Requirement | Clauses |
| --- | --- | --- |
| PA-IF-01 | The input and the output shall be AXI4-Stream ports of `DataWidth_g` bits (16, 32, 64 or 128) with `Keep`, `Last` and `User`, in `Clk` with the synchronous high-active reset `Rst`. Input format: the sectioned output messages of the output assembly (section code in `User(1:0)`, error flag on the last beat in `User(2)`, valid bytes contiguous from lane 0, a beat without valid byte only as the only beat of a message). | none (architecture section 6) |
| PA-IF-02 | `DataWidth_g` shall be 16, 32, 64 or 128; any other value shall stop the elaboration. | none (architecture D4, D6) |

### 2.2 Function

| ID | Requirement | Clauses |
| --- | --- | --- |
| PA-FN-01 | The output shall carry the bytes of every message in their input order without gaps: every beat except the last beat of a message carries `DataWidth_g` / 8 bytes, the last beat the remaining bytes, contiguous from lane 0. A message without any byte shall leave as one beat without valid byte. | none (D14) |
| PA-FN-02 | `User(1:0)` of an output beat shall be the section of its first byte; for a beat without valid byte, the section of its input beat. | none (D14) |
| PA-FN-03 | The error flag of the last input beat of a message shall be on the last output beat of the message; `User(2)` of every other output beat shall be '0'. | none (D14) |
| PA-FN-04 | No byte shall be lost or duplicated for any pattern of cycles without valid at the input and without ready at the output. | none (D3) |
| PA-FN-05 | The reset shall clear the bytes of the message in progress and restart the packer from any state. | none (D13) |

### 2.3 Performance

| ID | Requirement | Clauses |
| --- | --- | --- |
| PA-PF-01 | While the output is ready, the input shall accept one beat per clock cycle, except one cycle after the last beat of a message whose bytes do not fit into the output beats before it (the packer sends the rest in an extra output beat). | none (D3) |

## 3. Interpretation of the standard

The packer changes the framing of the output stream only; it does not touch the bytes of the AAD, of the ciphertext
or plaintext and of the tag, and so has no clause of FIPS 197, NIST SP 800-38D or CCSDS 352.0-B-2.

## 4. Configuration parameters

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `DataWidth_g` | 32 | 16, 32, 64, 128 | Width of the message streams |
