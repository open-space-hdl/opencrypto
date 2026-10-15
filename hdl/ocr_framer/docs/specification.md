# ocr_framer: Specification

## 1. Overview

`ocr_framer` is the framer of OpenCrypto (block FR-1 of the architecture). It sits in front of `ocr_core` and turns a
stream of packets of any length, for example compressed images, into messages of bounded size: it cuts every packet
into chunks of `ChunkBytes_g` bytes and hands every chunk to the core as one message, with a 4-byte AAD section that
tells the position of the chunk in its packet, and with one context per chunk for an encryption with a generated IV.
With the dense output of the core every chunk then leaves as IV ‖ AAD ‖ ciphertext ‖ tag: a self-contained packet
that a receiver decrypts and verifies on its own and puts back together in the order of the IV invocation counter.

## 2. Requirements

### 2.1 Interfaces and configuration

| ID | Requirement | Clauses |
| --- | --- | --- |
| FR-IF-01 | The framer shall have the input `S_In` (AXI4-Stream of `DataWidth_g` bits with `Keep` and `Last`), the context output `M_Ctx` and the message output `M_Out` (`User(1:0)` the section) with the signals of `S_Ctx` and `S_In` of `ocr_core` of the same `DataWidth_g` and `NumKeys_g`, the static input `Cfg_Slot`, the ECC event outputs and the error injection inputs, all in `Clk` with the synchronous high-active reset `Rst`. Input format: all bytes of a beat valid except in the last beat of a packet, contiguous from lane 0; a packet without byte is one beat without valid byte. | none (D15) |
| FR-IF-02 | `DataWidth_g` shall be 16, 32, 64 or 128 and `ChunkBytes_g` a multiple of 16; any other value shall stop the elaboration. | none (D15) |
| FR-IF-03 | `ChunkBytes_g` shall be at most 65536; a larger value shall stop the elaboration. | none (D15) |

### 2.2 Function

| ID | Requirement | Clauses |
| --- | --- | --- |
| FR-FN-01 | Every input packet shall be cut into chunks of `ChunkBytes_g` bytes in the order of its bytes; the last chunk of a packet carries the remaining 1 to `ChunkBytes_g` bytes, without padding. A packet without byte shall be one chunk without byte. | none (D15) |
| FR-FN-02 | Every chunk shall leave as one message: an AAD section of 4 bytes whose first byte carries the position of the chunk in bits 7:6 ("01" first, "00" middle, "10" last, "11" the only chunk of its packet; all other bits '0'), followed by the chunk as DATA section. | none (D15) |
| FR-FN-03 | For every chunk one context shall leave on `M_Ctx`, in the order of the chunks: encryption, IV of the IV generation unit, key slot `Cfg_Slot`. | none (D15) |
| FR-FN-04 | A chunk shall leave only when it is complete (its position is known); the chunk buffer shall hold `BufferChunks_g` chunks, so that the next chunks are taken while one leaves. | none (D15) |
| FR-FN-05 | No byte, chunk or context shall be lost or duplicated for any pattern of cycles without valid at the input and without ready at the outputs. | none (D3) |
| FR-FN-06 | The reset shall clear the chunks in the framer and restart it from any state; the first chunk after the reset is the first chunk of a packet. | none (D13) |

### 2.3 Fault tolerance and performance

| ID | Requirement | Clauses |
| --- | --- | --- |
| FR-FT-01 | The chunk buffer and the position FIFO shall be SECDED-protected. A single error shall be corrected. A double error shall fail the message of its chunk in `ocr_core`: the framer marks the word with the section code IV, which the core rejects (FORMAT, zero tag, error flag). Every error shall be reported once on `Ecc_Sec` or `Ecc_Ded` of its buffer; `ErrInj_*` inject into the next word written to the selected buffer. | none (P5) |
| FR-PF-01 | With an output and a context receiver that are always ready, the input shall pause at most AadBeats + 2 clock cycles per chunk, AadBeats = ceil(4 / (`DataWidth_g` / 8)): the output carries the AAD in addition to the chunk, and the buffer frees a chunk when it has been read completely. | none (D3) |

### 2.4 Integration with the core

| ID | Requirement | Clauses |
| --- | --- | --- |
| FR-IN-01 | The framer in front of `ocr_core` with the dense output shall encrypt every chunk with GCM-AE under the next IV of the IV generation unit of the slot, with the 4-byte position as AAD; every output message shall be the gapless byte string IV ‖ AAD ‖ ciphertext ‖ tag. | GCM 7.1, 8.2.1 |
| FR-IN-02 | With the core (dense output, default numbers of AES units and GHASH digits) and an output and a status receiver that are always ready, every chunk of n bytes after the first one shall take exactly C(n) = ceil(12 / B) + ceil(4 / B) + ceil(n / B) + 16 / B clock cycles at the output of the core, plus one when n is not a multiple of B (B = `DataWidth_g` / 8); the output shall pause exactly C(n) - ceil((n + 32) / B) cycles per chunk, and the input of the framer at most 40 cycles plus C(n) - ceil(n / B) per chunk. | none (D3) |

## 3. Interpretation of the standard

- The framer adds a framing of its own and no cryptographic function. The chunk position is AAD (GCM 5.2.1.1): it
  travels in clear and is authenticated, so a receiver detects a modified position with the tag of the chunk.
- Every chunk is one invocation of the authenticated encryption function with its own IV from the deterministic
  construction (GCM 8.2.1); the invocation counter numbers the chunks, so a receiver detects lost and reordered
  chunks.

## 4. Configuration parameters

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `DataWidth_g` | 32 | 16, 32, 64, 128 | Width of the streams, equal to `DataWidth_g` of the core |
| `NumKeys_g` | 4 | 1 to 256 | Number of key slots of the core (width of `Cfg_Slot` and `M_Ctx_Slot`) |
| `ChunkBytes_g` | 4096 | multiple of 16, 16 to 65536 | Bytes of a chunk; 65536 is the largest value that is elaborated and synthesised, the chunker, the chunk buffer and the counters are sized from the generic |
| `BufferChunks_g` | 2 | 2 to 64 | Chunks that the chunk buffer holds (rounded up to a power of two of words) |
| `RamStyle_g` | "auto" | RAM styles of Open Logic | RAM style of the chunk buffer (Open Logic); a synthesis attribute without effect in simulation |
