# OpenCrypto Architecture

Version 1.0. This file is the reference for the architecture and is versioned with the code.

## 1 Purpose, scope and references

This document defines the architecture of OpenCrypto, an implementation of the authenticated encryption and
decryption functions of the Galois/Counter Mode (GCM) with the Advanced Encryption Standard (AES) for real-time data
streams. Together with FIPS 197, NIST SP 800-38D and CCSDS 352.0-B-2 it is the complete basis for the implementation:
it fixes the building blocks, their interfaces, the clauses each block owns and the Open Logic entities each block is
built from.

### In scope

- The AES forward cipher with 128-, 192- and 256-bit keys (AES 5.1, 5.2), selected by a generic.
- GCM authenticated encryption (GCM-AE, GCM 7.1) and authenticated decryption (GCM-AD, GCM 7.2) of messages that
  consist of additional authenticated data (AAD) and plaintext or ciphertext, including GMAC (messages without
  plaintext, GCM 5.2, CCSDS 4.3.2). The direction is chosen per message.
- 96-bit initialisation vectors (IV), 128-bit authentication tags (CCSDS 3.4.2), AAD and data of up to
  2<sup>32</sup> - 1 bytes each per message.
- A key table with a configurable number of key slots: keys are loaded through the register file and can never be
  read back, the hash subkey is computed when a key is loaded, every message selects its slot.
- An IV generation unit per key slot with the deterministic construction (GCM 8.2.1), the enforcement of one IV
  construction per key (GCM 8.2) and the limit of the number of invocations (GCM 8.3).
- An optional release buffer that delivers a decrypted message only after its tag was verified (GCM 7.2 step 8).
- Streams with back-pressure everywhere, data widths of 16, 32, 64 and 128 bits and one beat per clock cycle;
  management, counters and product information behind an AXI4-Lite port; fault tolerance; the verification
  architecture.

### Out of scope

- The AES inverse cipher (AES 5.3): GCM uses only the forward cipher in both directions (GCM 5.1, 7.2).
- IVs of other lengths than 96 bits (GCM 5.2.1.1 recommends restricting the support to 96 bits) and tag lengths other
  than 128 bits (GCM 5.2.1.2 allows the restriction to one value; CCSDS 3.4.2 requires 128 bits).
- The RBG-based IV construction (GCM 8.2.2): the core contains no random bit generator. A user who builds IVs with an
  RBG supplies them as external IVs.
- Key establishment and key management (GCM 8.1, CCSDS 1.2): keys are delivered to the register file by the user.
- The other algorithms of CCSDS 352.0-B-2: HMAC (CCSDS 4.2), CMAC (CCSDS 4.3.1) and digital signatures (CCSDS 4.4).
- Security protocols that use AES-GCM, for example the Space Data Link Security Protocol (CCSDS 355.0-B-2): the
  framing of security headers and trailers belongs to the protocol layer. The message format of section 6 is chosen so
  that such a layer maps its frames onto it without buffering.

### Target technology

OpenCrypto contains no vendor code. All buffers and tables are Open Logic fault-tolerant entities, all data interfaces
are AXI4-Stream and the management interface is AXI4-Lite. The core runs on any FPGA.

### Project

OpenCrypto is an open AES-GCM implementation that is based on the Open Logic VHDL Library. The code lives in
[open-space-hdl/opencrypto](https://github.com/open-space-hdl/opencrypto) under the PSI HDL Library License, Version
1.0, the licence of Open Logic. Open Logic is pinned to the tag `4.7.0-ft.2` of the branch `fault-tolerant` of
open-space-hdl/open-logic-ft, the fault-tolerant fork of Open Logic.

### References

| ID | Document | Version used |
| --- | --- | --- |
| \[AES\] | FIPS 197, Advanced Encryption Standard (AES) | November 26, 2001 (the update FIPS 197-upd1 of May 9, 2023 makes no technical change) |
| \[GCM\] | NIST SP 800-38D, Recommendation for Block Cipher Modes of Operation: Galois/Counter Mode (GCM) and GMAC | November 2007 |
| \[CCSDS\] | CCSDS 352.0-B-2, CCSDS Cryptographic Algorithms, Recommended Standard, Issue 2 | August 2019 |
| \[SDLS\] | CCSDS 355.0-B-2, Space Data Link Security Protocol (informative: use of AES-GCM on space links) | July 2022 |
| \[OLO\] | [Open Logic, fault-tolerant fork, branch fault-tolerant](https://github.com/open-space-hdl/open-logic-ft/tree/fault-tolerant) | 4.7.0-ft.2 |

### Conventions

- Clause references name the standard: AES for FIPS 197, GCM for NIST SP 800-38D and CCSDS for CCSDS 352.0-B-2, for
  example AES 5.2, GCM 7.1 or CCSDS 3.4.2. A range such as AES 5.1.1 to 5.1.4 means all clauses in between.
- Coding conventions: those of Open Logic (naming, two-process style, synchronous high-active resets, VSG rules),
  entity prefix `ocr_`, VHDL library `opencrypto`; see [conventions.md](conventions.md).
- "FT" (fault-tolerant) means the Open Logic `olo_ft_*` entities: SECDED ECC on every buffer and table.

| Term | Meaning |
| --- | --- |
| Block | 128-bit string, the block size of AES (AES 3.1); its first byte is the leftmost byte of the string |
| Beat | One transfer of a stream of `DataWidth_g` = W bits; `R` = 128 / W beats form one block |
| Message | The input of one invocation of GCM-AE or GCM-AD and its output: AAD, data (plaintext or ciphertext), IV and tag |
| Section | The beats of one part of a message: IV, AAD, DATA or TAG (section 6) |
| Key slot | Entry of the key table: key, hash subkey, IV construction and IV generator state |
| J0 | Pre-counter block IV ‖ 0<sup>31</sup> ‖ 1 of a 96-bit IV (GCM 7.1 step 2) |
| H | Hash subkey CIPH<sub>K</sub>(0<sup>128</sup>) (GCM 7.1 step 1) |
| Keystream block | CIPH<sub>K</sub>(CB<sub>i</sub>) of a counter block of GCTR (GCM 6.5) |
| Bottleneck side | The side of the core with more beats per message: the output for encryption (the tag is appended), the input for decryption (the tag is consumed) |

## 2 Functional overview of the standards

AES is a block cipher with a block size of 128 bits and key lengths of 128, 192 or 256 bits (AES 5). The cipher
transforms a 16-byte State in Nr = 10, 12 or 14 rounds of SubBytes, ShiftRows, MixColumns and AddRoundKey; the last
round has no MixColumns (AES 5.1). The round keys come from the key expansion (AES 5.2), which derives 4 (Nr + 1)
words from the Nk = 4, 6 or 8 words of the key.

GCM combines the counter mode for confidentiality with the universal hash GHASH for authenticity (GCM 5.3). For a
96-bit IV the counter blocks are J0 = IV ‖ 0<sup>31</sup> ‖ 1 and its successors under inc32, the increment of the
rightmost 32 bits (GCM 6.2). The plaintext is XORed with the keystream of the counter blocks inc32(J0), inc32²(J0), ...
(GCTR, GCM 6.5); a partial last block uses the leftmost bytes of its keystream block. GHASH multiplies the blocks of
A ‖ 0<sup>v</sup> ‖ C ‖ 0<sup>u</sup> ‖ [len(A)]<sub>64</sub> ‖ [len(C)]<sub>64</sub> in GF(2<sup>128</sup>) with
the hash subkey H = CIPH<sub>K</sub>(0<sup>128</sup>) (GCM 6.3, 6.4), and the tag is the result XORed with
CIPH<sub>K</sub>(J0) (GCM 7.1 step 6). The decryption runs the same counter mode over the ciphertext, computes the tag
over the received ciphertext and returns the plaintext only when the computed tag equals the received one; otherwise
it returns FAIL (GCM 7.2).

CCSDS 352.0-B-2 selects AES as the encryption algorithm of all CCSDS missions (CCSDS 3.1), with 256-bit keys for new
missions and 128-bit keys allowed for existing ones (CCSDS 3.2), in counter mode (CCSDS 3.3), and GCM with a 128-bit
MAC when integrity and origin authentication are required (CCSDS 3.4). GMAC may replace CMAC when an authenticated
encryption implementation is used for authentication only (CCSDS 4.3.2).

| Function | Clauses |
| --- | --- |
| Notation, bytes, State | AES 3 |
| Arithmetic in GF(2<sup>8</sup>) | AES 4 |
| Cipher and key expansion | AES 5.1, 5.2 |
| Key lengths and implementation freedom | AES 6 |
| Block cipher requirements | GCM 5.1 |
| GCM functions, input and output data | GCM 5.2 |
| Counter mode and GHASH | GCM 5.3, 6 |
| GCM-AE and GCM-AD | GCM 7 |
| Uniqueness of IVs and keys | GCM 8, 9 |
| Conformance | GCM 10 |
| CCSDS algorithm selection | CCSDS 3, 4.3.2 |

Five properties of the standards shape the architecture more than any single feature:

- **The keystream does not depend on the data.** Every counter block is known once the IV is known, so the AES works
  on requests that the input side issues ahead of the data, and the data only waits for its keystream block.
- **GHASH is a sequential chain.** Every block of GHASH depends on the previous result (GCM 6.4). The multiplier
  finishes one block before the next starts; its digit size sets its throughput.
- **The tag follows the data.** The tag is known only after the last block and the length block, and the decryption
  verdict only after the received tag. Results that depend on the tag are therefore produced at the end of a message,
  and the release of a plaintext after verification needs a buffer of the whole message.
- **The IV must never repeat for a key** (GCM 8). A repeated IV reveals the XOR of two plaintexts and allows forgeries
  (GCM Appendix A). The IV generator keeps its counter in protected memory and refuses to continue when it is
  exhausted.
- **The key and H are secret** (GCM 5.1, 5.3). No interface of the core can read a key, a round key or H.

## 3 Design drivers

| Driver | Consequence |
| --- | --- |
| Encryption of instrument data and telemetry at line rate | One beat per clock cycle at every width on every path, including message boundaries (P6) |
| Data widths of 16 to 128 bits for links of different speed | Resources scale with the width: the number of AES round units and the digit of the GHASH multiplier follow from the width (D4, D5) |
| Use in space: single event upsets in tables, buffers and registers | SECDED ECC on every table and buffer, scrubbing of the key table, round keys computed with every block instead of stored, state machines with a recovery state (P5) |
| Several security associations per link | A key table with a key slot per message and without a pause on a key change (D7) |
| IV uniqueness as a property of the core | IV generation unit inside the core with protected state and the enforcement of one construction per key (D8) |
| Integration with space link security protocols | Message format with sections that a protocol layer maps onto its frames, IV of generated messages delivered in front of the message (D2) |
| Technology independence | AXI4-Stream and AXI4-Lite interfaces, no vendor primitive (P11) |
| Verifiability | Every block verified through its ports against the AES-GCM implementation of pycryptodome (P9, section 9) |

## 4 Design goals

| Goal | Implementation |
| --- | --- |
| Defined handshakes between blocks | Every internal data path is a valid / ready stream or a stream with credits (P2) |
| One function per block | A block implements one function of the standards; no clause is owned by two blocks (P1) |
| No plaintext of a failed message with the release buffer | The release buffer drops every message whose status is not OK (D10) |
| Deterministic error reporting | One status per message with one code, a fixed priority of the codes and one counter per code (D11) |
| Fault tolerance | FT buffers and tables, scrubbing, safe state machines, contained double errors (P5) |
| Key confidentiality | Keys enter through write-only registers that clear themselves; no read path to keys, round keys or H (D7) |
| Tests independent of the design hierarchy | Tests observe only ports and the register file (section 9) |

## 5 Design principles

| ID | Principle | Rule for the implementation |
| --- | --- | --- |
| P1 | One function per block | A block implements one function of the standards. Its specification names the clauses it owns; no clause is owned by two blocks. |
| P2 | Streams everywhere | Every data path between blocks is a valid / ready stream (Open Logic AXI4-Stream conventions). A path into a pipeline that cannot stall uses credits: a request is issued only when the buffer behind the pipeline has room for its result. |
| P3 | One clock domain | All blocks run in `Clk`. |
| P4 | One management interface | Key loading, configuration, status and counters live in one register file behind one AXI4-Lite port, generated from a single register description (VHDL package, documentation, C header). |
| P5 | Fault tolerance by construction | All buffers and tables are `olo_ft_*` entities (SECDED ECC); the key table is scrubbed. Round keys are computed from the key with every block. State machines have a defined recovery state. ECC events are counted; a double error is contained and reported in the status of the message. |
| P6 | Line rate | Every path accepts one beat per clock cycle while its output is ready, and the bottleneck side of back-to-back messages transfers one beat per clock cycle (D3). |
| P7 | Messages are self-describing | The section of every beat travels in `TUser`; lengths are not announced in advance. |
| P8 | The direction is a property of the message | Encryption and decryption share the data path; the context of each message selects the direction, the key slot and the IV. |
| P9 | Verifiable in isolation | Each module has a specification and a testbench that drives only its ports. Expected values come from pycryptodome, an implementation of AES-GCM that is independent of the RTL, and from the examples of the standards. |
| P10 | Reuse before design | A function available in Open Logic (FIFO, packet FIFO, RAM, AXI4-Lite slave, ECC monitor) is instantiated, not rewritten. |
| P11 | No vendor code | The core has no vendor primitive. |

## 6 Architecture overview

![Architecture overview of ocr_core: the GCM data path (IN-1, IN-2, CT-1, GH-1, TG-1, AE-1, OU-1 to OU-3), the key table
(KT-1 to KT-4) and the register file (MG-1, MG-2)](img/ocr_core_overview.drawio.svg)

The user hands over one context per message on `S_Ctx` (direction, key slot, IV or the request for a generated IV)
and the message itself on `S_In`. The key table resolves the context: it reads the key, the hash subkey and the IV
generator state of the slot, checks the slot and the IV construction, and passes a job to the GCM data path. The data
path parses the sections, requests the counter blocks of the message from the AES engine, XORs the data with its
keystream, hashes AAD and ciphertext, computes the tag and assembles the output message. Every message ends with one
status on `M_Sts`.

### Message format

`S_In` and `M_Out` carry one message per packet of the stream: `TLast` marks the last beat of a message. A message is
a sequence of sections; the section of a beat is in `TUser(1:0)`:

| Code | Section | Input of the encryption | Output of the encryption | Input of the decryption | Output of the decryption |
| --- | --- | --- | --- | --- | --- |
| "11" | IV | not allowed | first, when the IV was generated | not allowed | not used |
| "01" | AAD | optional, first | AAD as received | optional, first | AAD as received |
| "00" | DATA | optional, after the AAD | ciphertext | optional, after the AAD | plaintext |
| "10" | TAG | not allowed | last, 16 bytes | required, last, 16 bytes | not used |

- A section starts with a new beat. Byte lane 0 (`TData(7:0)`) holds the first byte of a beat, and the first byte of a
  section is the leftmost byte of its first block (AES 3.1, GCM 6.1).
- All bytes of a beat are valid except in the last beat of a section, whose valid bytes are contiguous from byte lane
  0 (`TKeep`). A section of one beat without a valid byte is an empty section; an empty message is one such beat.
- The IV section has 12 bytes, the TAG section 16 bytes.
- `M_Out_User(2)` is the error flag on the last beat of a message: '1' when the status of the message is not OK. A
  failed decryption therefore ends with the flag, and a consumer that does not use the status discards the message.
- An output message with no byte at all (decryption of an empty message, rejected message) is one beat without a
  valid byte, with `TLast` and the error flag.

The format maps a space link frame without buffering: the protocol layer passes the header fields to be authenticated
as AAD (with the IV field masked, as SDLS 4.2.2.6 does), the frame data as DATA, and appends or checks the TAG. When
the core generates the IV, the IV section arrives in front of the AAD of the output, so the layer can insert it into
the frame header before it sends the header.

### Context and status

`S_Ctx` (valid / ready, one transfer per message, in the order of the messages):

| Signal | Width | Meaning | Clause |
| --- | --- | --- | --- |
| `S_Ctx_Decrypt` | 1 | '0' GCM-AE, '1' GCM-AD | GCM 5.2 |
| `S_Ctx_Slot` | log2(`NumKeys_g`) | Key slot | GCM 5.1 |
| `S_Ctx_IvGen` | 1 | '1' the IV generation unit of the slot supplies the IV (encryption only) | GCM 8.2.1 |
| `S_Ctx_Iv` | 96 | IV of the message when `S_Ctx_IvGen` = '0' | GCM 5.2.1.1 |

`M_Sts` (valid / ready, one transfer per message, in the order of the messages): status code, direction, key slot,
the IV that was used, and the numbers of AAD and DATA bytes. Codes in order of precedence:

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | OK | Message processed; for a decryption the tag was verified |
| 7 | ECC | Uncorrectable double error in a memory that holds data of the message |
| 3 | KEY | Key slot out of range or not loaded |
| 4 | IV_MODE | The IV source of the context is not the construction of the key slot, or a generated IV was requested for a decryption |
| 5 | IV_EXHAUSTED | The invocation counter of the slot has reached its last value (GCM 8.3) |
| 2 | FORMAT | Section order, byte enables, IV or TAG section on the wrong side, TAG section missing or not 16 bytes |
| 6 | LENGTH | AAD or DATA longer than 2<sup>`LenBits_g`</sup> - 1 bytes |
| 1 | AUTH | Decryption: computed tag differs from the received tag (FAIL of GCM 7.2) |
| 8 | OVERFLOW | Release buffer: message longer than the buffer, dropped |

### Architecture decisions

| ID | Decision | Reason |
| --- | --- | --- |
| D1 | One clock domain `Clk` for all functions, including the register file | Clock domain crossings of the links stay in the link cores; a second domain adds latency and FT crossings without benefit |
| D2 | One input and one output stream with sections in `TUser`, a context stream and a status stream per message; no lengths in advance (P7) | A link layer streams frames without buffering them; encryption output and decryption input have the same format, so two cores connect directly; the status reports every message, also dropped ones |
| D3 | Throughput: within a message every interface transfers one beat per clock cycle while its partner is ready. For back-to-back messages the bottleneck side transfers one beat per clock cycle after the initial latency, with one exception: consecutive encryptions with generated IVs need at least three output beats per message | The core keeps up with any stream at its clock rate; the IV generator updates its counter in the key table memory once per message (D8) |
| D4 | AES engine of `AesUnits_g` iterative round units (one round per clock cycle each), dispatched in round robin; every request carries its key, the units expand the round keys on the fly. Default: ceil(2 Nr / (R + 1)) units, at least ceil(Nr / R) | A unit is busy Nr cycles per block; the default sustains D3 for the shortest messages (one counter block plus J0 per message), the minimum for long messages; the area follows the width; round keys never stored (P5), any key per block (D7) |
| D5 | GHASH multiplier with a digit of `GhashDigit_g` bits (W to 128) of the first operand per clock cycle; default 128 for W of 64 and 128 bits, 64 for 16 and 32 bits. The length block of a message is processed like a data block | The multiplier finishes a block in 128 / `GhashDigit_g` cycles; the default leaves room for the partial blocks and the length block of the shortest messages (D3) |
| D6 | The input side issues the requests for J0 and for every counter block when the first beat of the block arrives; the keystream waits in an FT FIFO, J0 results in a second FIFO for the tag, results of hash subkey requests go to the key table. Credits per FIFO guard the requests | The AES engine has a fixed latency and no back-pressure; separate FIFOs per destination exclude head-of-line blocking between the data path and the tag |
| D7 | Key table of `NumKeys_g` slots in three `olo_ft_ram_sdp_scrub` (key, hash subkey, IV state); the valid flags are part of the protected words. The register file writes a key through write-only registers that clear themselves after the load; the load computes H with the AES engine. After the reset and on the zeroize command every slot is erased. A context selects any slot per message | Key confidentiality (GCM 5.1, 5.3); several security associations without a pause; SEUs never activate an erased slot; no key survives a reset |
| D8 | IV generation unit per slot: IV = fixed field (32 bits) ‖ invocation counter (64 bits) (GCM 8.2.1, suggested layout); the counter increments with every encryption of the slot with a generated IV, the all-ones value means exhausted. Every slot is loaded either for generated or for external IVs; an encryption with the other source fails. The current counter of a slot can be read for its backup in non-volatile memory | Uniqueness of the IV (GCM 8), exactly one construction per key (GCM 8.2), limited invocations (GCM 8.3), recovery after a loss of power (GCM 9.1) |
| D9 | The output assembly emits the IV section of a generated IV, the AAD and the data, then the tag of an encryption; for a decryption it holds the last output beat until the verdict and sets the error flag on a failure | The tag and the verdict are known only at the end (section 2); the consumer receives the verdict with the message |
| D10 | Optional release buffer (`ReleaseBuffer_g`): an `olo_ft_fifo_packet` behind the output assembly that drops every message whose status is not OK and every message longer than the buffer | A decrypted message leaves the core only after its tag was verified (GCM 7.2 step 8) |
| D11 | One status per message with one code; the code of the highest precedence wins; every code is counted in the register file | Deterministic and testable error reporting |
| D12 | A failed encryption emits the TAG section as zeros; a message that its context rejects is consumed and replaced by one empty output beat | A failed encryption can never carry a valid tag; message boundaries are kept for the consumer |
| D13 | The protocol state machines have a defined recovery state, without TMR: the `when others` branch leads to it from an illegal state, and the reset restarts the core from any state | Same as the other Open Space HDL cores; registers of the control paths are protected by the TMR of the synthesis tool where the mission requires it |

### Clock and reset

All blocks run in `Clk`. The reset input `Rst` is synchronous and high-active (Open Logic convention); the integrator
synchronises it to `Clk`, for example with `olo_ft_reset_gen`. After the reset the key table erases all slots
(`NumKeys_g` clock cycles); contexts are resolved after the erasure, so a message that arrives meanwhile waits.

### Single event effects

| Location | Upset | Effect | Detection |
| --- | --- | --- | --- |
| Key, hash subkey and IV memories (KT-1) | Single error | Corrected at the read and by the scrubber | ECC event |
| | Double error | The jobs of the slot fail with ECC and carry no key; the slot is usable again after a new load | ECC event, status ECC |
| FIFOs and release buffer of the data path, job FIFO | Single error | Corrected | ECC event |
| | Double error | The message whose data the entry held fails with ECC (status FIFO: the status reports ECC; release buffer: the message ends with the error flag) | ECC event, status ECC |
| Registers of the AES units, the GHASH multiplier, the combiner and the tag stage | Any | Encryption: a wrong ciphertext block or tag, which the receiver detects with its tag verification. Decryption: a wrong keystream block corrupts the plaintext of one block without changing the verdict; an upset in GHASH or in the tag stage fails the message with AUTH | Encryption: at the receiver; decryption: not detected for the keystream |
| Control registers (state machines, counters, credits) | Any | The `when others` branch returns an illegal state to its recovery state; a corrupted counter or credit can corrupt or stall a message; the reset recovers from any state | Not detected by the core |

The memories and buffers hold most of the state and are fully protected. The residual risk lies in the registers of
the data path and the control: where the mission requires it, the integrator applies the TMR of the synthesis tool to
the core (D13), and a receiver always verifies the tag.

### Internal interfaces

| Interface | Between | Payload | Protocol |
| --- | --- | --- | --- |
| Job | KT-3 to IN-1 | Direction, key, H, IV, IV section flag, context error, slot | Valid / ready |
| AES request | IN-2 and KT-2 to AE-1 | Key, input block, destination | Valid / ready, credits per destination |
| AES result | AE-1 to the keystream FIFO, the J0 FIFO and KT-2 | Output block, destination | Valid only, fixed latency |
| Beat stream | IN-1, CT-1, OU-1 | Data, byte enables, section, block and message flags, error flags | AXI4-Stream |
| Hash stream | CT-1 to GH-1 | AAD and ciphertext beats with section and message ends | AXI4-Stream |
| Message results | GH-1, CT-1 and TG-1 to OU-1 | S, lengths, received tag, tag or verdict, status code | Valid / ready |
| Key load | MG-1 to KT-2 | Slot, key, IV construction, fixed field, counter | Valid / ready |
| Register bus | MG-1 and the user | Key load, configuration, status, counters | AXI4-Lite (`olo_axi_lite_slave`) |

## 7 Building block specifications

The core has 16 building blocks in six groups. Each block lists its responsibility, the Open Logic entities it is
built from and the clauses it owns (P1: no clause is owned twice).

### 7.1 AES engine

| ID | Block | Responsibility | Open Logic | Clauses |
| --- | --- | --- | --- | --- |
| AE-1 | AES engine | Forward cipher of one block per request: `AesUnits_g` round units with round-robin dispatch, AddRoundKey of round 0 at the dispatch, one round per clock cycle with SubBytes, ShiftRows, MixColumns (not in the last round) and AddRoundKey, key expansion on the fly with every block; fixed latency, results in the order of the requests | none | AES 3, 5.1, 5.1.4, 5.2, 6.1, 6.3, 6.4; GCM 5.1; CCSDS 3.1, 3.2 |

### 7.2 GCM data path

| ID | Block | Responsibility | Open Logic | Clauses |
| --- | --- | --- | --- | --- |
| IN-1 | Input parser | Takes the job of the message, holds one beat back to find the end of every section, checks the section order, the byte enables and the TAG length, consumes rejected messages, forwards beats with their flags | `olo_ft_fifo_sync` (data FIFO) | GCM 5.2, 5.2.1.1, 10; CCSDS 4.3.2 |
| IN-2 | Counter blocks | J0 and the counter blocks IV ‖ [i + 1]<sub>32</sub> of the DATA blocks, requests to AE-1 with credits, priority of hash subkey requests | none | GCM 6.2 |
| CT-1 | GCTR combiner | XORs every DATA beat with its part of the keystream block (partial last block: leftmost bytes), passes AAD, routes AAD and ciphertext to GH-1, collects the received tag, reports ECC errors of the message | `olo_ft_fifo_sync` (keystream, J0) | GCM 5.3, 6.5, 7.1; CCSDS 3.3, 3.4.1 |
| TG-1 | Tag | T = S ⊕ CIPH<sub>K</sub>(J0); encryption: the tag; decryption: comparison with the received tag, verdict; status code of the message | `olo_ft_fifo_sync` | GCM 5.2.1.2, 5.2.2, 7.2; CCSDS 3.4.2 |
| OU-1 | Output assembly | IV section of a generated IV, AAD and data beats, TAG section of an encryption (zeros on failure), held last beat and error flag of a decryption, empty beat of a rejected message | `olo_ft_fifo_sync` (output FIFO) | none (format of section 6) |
| OU-2 | Release buffer | Optional store-and-forward of the output messages, drops messages whose status is not OK and messages longer than the buffer | `olo_ft_fifo_packet` | none (GCM 7.2 step 8 through TG-1) |
| OU-3 | Status | One status per message: code, direction, slot, IV, AAD and DATA bytes | `olo_ft_fifo_sync` | none |

### 7.3 GHASH

| ID | Block | Responsibility | Open Logic | Clauses |
| --- | --- | --- | --- | --- |
| GH-1 | GHASH | Assembles blocks from the hash stream with zero padding at the end of every section, counts the AAD and ciphertext bytes, appends the length block, multiplies Y<sub>i</sub> = (Y<sub>i-1</sub> ⊕ X<sub>i</sub>) · H in GF(2<sup>128</sup>) with a digit-serial multiplier, delivers S per message | `olo_ft_fifo_sync` (H per message) | GCM 6.3, 6.4 |

### 7.4 Key table

| ID | Block | Responsibility | Open Logic | Clauses |
| --- | --- | --- | --- | --- |
| KT-1 | Key memories | Key, hash subkey and IV state of every slot with valid flags in protected words, scrubbing, erasure after the reset and on zeroize | `olo_ft_ram_sdp_scrub` | GCM 5.3 (no read path to the key and H) |
| KT-2 | Key load | Writes key and IV state of a slot, computes H = CIPH<sub>K</sub>(0<sup>128</sup>) with AE-1, validates the slot | none | GCM 7.1 step 1, 7.2 step 2; AES 6.2 |
| KT-3 | Context resolution | Reads the slot of each context, checks range, validity and IV construction, builds the job (key, H, IV) | none | GCM 8.2 |
| KT-4 | IV generation unit | IV = fixed field ‖ invocation counter, increment per invocation, exhaustion, counter readable for its backup | none | GCM 8, 8.2.1, 8.3, 9.1 |

### 7.5 Management

| ID | Block | Responsibility | Open Logic | Clauses |
| --- | --- | --- | --- | --- |
| MG-1 | Register file | Key load through self-clearing write-only registers, zeroize, slot query (valid, construction, exhausted, counter), counters per status code and direction, interrupt, product information, generated from one register description (`hdl/ocr_mib/regs/ocr_regs.yml`, `tools/regmap.py`) | `olo_axi_lite_slave` | GCM 5.1 (key secrecy) |
| MG-2 | EDAC monitor | Counts the SEC and DED events of every FT table and buffer, raises an interrupt | `olo_ft_ecc_monitor` | none (fault tolerance, P5) |

### 7.6 Common functions

| ID | Block | Responsibility | Open Logic | Clauses |
| --- | --- | --- | --- | --- |
| CM-1 | Package | AES transformations (S-box, ShiftRows, MixColumns, key expansion step), GF(2<sup>8</sup>) and GF(2<sup>128</sup>) arithmetic, byte order of blocks and beats, section and status codes | none | AES 4, 5.1.1 to 5.1.3; GCM 6.3 |

### Modules

A module is one group of blocks with its own specification, verification plan, testbench and verification report.

| Module | Blocks | Entities |
| --- | --- | --- |
| `ocr_pkg` | CM-1 | `ocr_pkg`, `ocr_regs_pkg` (generated) |
| `ocr_aes` | AE-1 | `ocr_aes_engine`, `ocr_aes_unit` |
| `ocr_ghash` | GH-1 | `ocr_ghash` |
| `ocr_gcm` | IN-1, IN-2, CT-1, TG-1, OU-1 to OU-3 | `ocr_gcm`, `ocr_gcm_pkg`, `ocr_gcm_input`, `ocr_gcm_keystream`, `ocr_gcm_combine`, `ocr_gcm_tag`, `ocr_gcm_output` |
| `ocr_key_table` | KT-1 to KT-4 | `ocr_key_table` |
| `ocr_mib` | MG-1, MG-2 | `ocr_mib` |
| `ocr_core` | Top level | `ocr_core` |

## 8 Open Logic usage

| Open Logic entity | Used in | Purpose |
| --- | --- | --- |
| `olo_ft_fifo_sync` | IN-1, CT-1, TG-1, OU-1, OU-3, GH-1, KT-3 | Data, keystream, J0, hash, output, hash subkey, descriptor, summary, result, status and job FIFOs with ECC |
| `olo_ft_fifo_packet` | OU-2 | Release buffer: store-and-forward of complete output messages, drop of failed messages |
| `olo_ft_ram_sdp_scrub` | KT-1 | Key, hash subkey and IV memories with ECC and background scrubbing |
| `olo_axi_lite_slave` | MG-1 | AXI4-Lite access to the register file |
| `olo_ft_ecc_monitor` | MG-2 | SEC and DED counters per table and buffer, DED sticky flags |

### Gaps in Open Logic

| Gap | Resolution in this architecture |
| --- | --- |
| No fault-tolerant flow-control handler (`olo_base_flowctrl_handler` uses a FIFO without ECC) | Credit counters in front of the AES engine with `olo_ft_fifo_sync` behind it (IN-2, D6) |
| No cryptographic primitives | AE-1, GH-1 and CM-1 in OpenCrypto |
| No TMR register helper | Recovery state of every state machine (D13) |

## 9 Verification architecture

The core is verified with VUnit and UVVM in a seven-phase module workflow (requirements, architecture, verification
plan, RTL, testbenches, verification, integration; see [conventions.md](conventions.md)). Every module of section 7
has its own specification, verification plan, testbench and verification report; core tests cross the seams between
the modules. Every test case names the requirements it verifies, and every requirement names its clauses, so the
traceability matrix of section 10 is checked by `tools/compliance.py`.

| Level | Scope | Bench | Checks |
| --- | --- | --- | --- |
| Unit | `ocr_pkg`, AES engine, GHASH, GCM data path, key table, register file | `<entity>_th.vhd` (clock, DUT, models) and `<entity>_tb.vhd` (VUnit runner, one `run("test_...")` per test of the verification plan) | UVVM checks; every output byte compared with the expected values of pycryptodome or of the examples of the standards |
| Core | One core with keys loaded through the AXI4-Lite port, and two cores in series (encryption, then decryption) | Message source and sink models, context and status models, an AXI4-Lite VVC | Encryption and decryption against pycryptodome, key changes per message, generated IVs, every status code, throughput, reset |

### Framework

- VUnit (`run.py`) discovers and runs every test and is the CI regression. UVVM supplies the verification building
  blocks: the AXI4-Lite VVC, alert and log handling, `check_value` / `await_value`, randomisation.
- Expected values: `tools/ocr_vectors.py` generates the test messages of every test configuration with pycryptodome
  (AES in ECB mode for the AES engine, AES in GCM mode for everything else) when `run.py` starts. The vectors do not
  depend on the data width, so every configuration of a testbench runs the same messages. The examples of FIPS 197
  (Appendix A and C) and the test cases of the GCM specification with 96-bit IVs are part of the vector sets; the
  generator checks that pycryptodome reproduces them.
- Message source and sink models (`tb/ocr_tb_*.vhd`) send and check messages of any length with random stall cycles;
  the sink compares every byte, the byte enables, the section and the error flag of every beat. Throughput tests
  measure the gaps on the bottleneck side.
- Simulator: GHDL for every test; QuestaSim for code coverage.

### Rules

- Tests observe ports and the register file only (P9).
- A failed check fails the test; a test cannot pass with a failed step.
- Negative tests inject the fault from the bench (modified tag, AAD or ciphertext, wrong section order, wrong byte
  enables, unloaded slot, wrong IV source, exhausted counter, oversized section, message longer than the release
  buffer, double error through the error injection of the FT buffers and tables) and expect the status code, the
  counter or the flag; never from an RTL mutation.
- Every commit passes the full regression.

## 10 Requirement traceability matrix

Every clause in the scope of section 1 has exactly one owner block. "User" marks a clause that the user of the core
fulfils; the user guide states it. "First verified at" names the lowest verification level at which the clause can be
fully checked. The [compliance matrix](compliance.md), generated from this table, the module specifications and the
verification plans, lists the requirements and test cases of every clause.

| Clause | Title | Owner | Also involved | First verified at |
| --- | --- | --- | --- | --- |
| AES 3.1 to 3.5 | Inputs and outputs, bytes, arrays of bytes, the State | AE-1 | CM-1, CT-1 | Unit |
| AES 4.1, 4.2 | Addition and multiplication in GF(2<sup>8</sup>) | CM-1 | AE-1 | Unit |
| AES 4.3 | Polynomials with coefficients in GF(2<sup>8</sup>) | CM-1 | AE-1 | Unit |
| AES 5.1 | Cipher | AE-1 | CM-1 | Unit |
| AES 5.1.1 | SubBytes | CM-1 | AE-1 | Unit |
| AES 5.1.2 | ShiftRows | CM-1 | AE-1 | Unit |
| AES 5.1.3 | MixColumns | CM-1 | AE-1 | Unit |
| AES 5.1.4 | AddRoundKey | AE-1 |  | Unit |
| AES 5.2 | Key Expansion | AE-1 | CM-1 | Unit |
| AES 5.3 | Inverse Cipher | Not implemented (GCM uses only the forward cipher, GCM 5.1, 7.2) |  | - |
| AES 6.1 | Key length requirements | AE-1 |  | Unit |
| AES 6.2 | Keying restrictions | KT-2 | AE-1 | Unit |
| AES 6.3 | Parameterization of key length, block size and round number | AE-1 |  | Unit |
| AES 6.4 | Implementation variations | AE-1 |  | Unit |
| GCM 5.1 | Block cipher: approved, 128-bit block, key of at least 128 bits, secret | AE-1 | KT-1, MG-1 | Unit |
| GCM 5.2 | Authenticated encryption and decryption functions, GMAC | IN-1 | TG-1 | Unit |
| GCM 5.2.1.1 | Input data: lengths, byte strings, supported lengths, 96-bit IVs | IN-1 | GH-1, KT-3 | Unit |
| GCM 5.2.1.2 | Output data: ciphertext and tag, one tag length per key | TG-1 | OU-1 | Unit |
| GCM 5.2.2 | Authenticated decryption function: plaintext or FAIL | TG-1 | OU-1, OU-2 | Unit |
| GCM 5.3 | Primitives: counter mode with inc32, GHASH, secret intermediate values | CT-1 | GH-1, KT-1 | Unit |
| GCM 6.2 | Incrementing function | IN-2 |  | Unit |
| GCM 6.3 | Multiplication operation on blocks | GH-1 | CM-1 | Unit |
| GCM 6.4 | GHASH function | GH-1 |  | Unit |
| GCM 6.5 | GCTR function | CT-1 | IN-2 | Unit |
| GCM 7.1 | Algorithm for the authenticated encryption function | CT-1 | IN-2, GH-1, TG-1, KT-2 | Unit |
| GCM 7.2 | Algorithm for the authenticated decryption function | TG-1 | IN-1, CT-1, GH-1, OU-2 | Unit |
| GCM 8 | Uniqueness requirement on IVs and keys | KT-4 | User (external IVs) | Unit |
| GCM 8.1 | Key establishment | User (fresh keys) |  | - |
| GCM 8.2 | IV constructions: one construction per key | KT-3 | KT-4 | Unit |
| GCM 8.2.1 | Deterministic construction | KT-4 |  | Unit |
| GCM 8.2.2 | RBG-based construction | User (external IVs) |  | - |
| GCM 8.3 | Constraints on the number of invocations | KT-4 | User (external IVs) | Unit |
| GCM 9.1 | Design considerations: generation unit, IV protection, loss of power | KT-4 | User (counter backup) | Unit |
| GCM 9.2 | Operational considerations | User (user guide) |  | - |
| GCM 10 | Conformance: GCM and GMAC, supported lengths | IN-1 |  | Unit |
| CCSDS 3.1 | AES for encryption | AE-1 |  | Unit |
| CCSDS 3.2.1, 3.2.2 | Cryptographic key size 256 bits, 128 bits for existing implementations | AE-1 | KT-1 | Unit |
| CCSDS 3.3 | Counter mode | CT-1 | IN-2 | Unit |
| CCSDS 3.4.1 | GCM for authenticated encryption | CT-1 | GH-1, TG-1 | Unit |
| CCSDS 3.4.2 | MAC size of 128 bits | TG-1 |  | Unit |
| CCSDS 4.3.2 | GMAC for authentication only | IN-1 | TG-1 | Unit |

## 11 Development plan

1. Foundations: repository, `ocr_pkg`, the vector generator with pycryptodome, verification components (message
   source and sink, context and status models, test end check), regression and CI.
2. AES engine (AE-1) with unit tests against the examples of FIPS 197 and pycryptodome for every key length and
   several numbers of units.
3. GHASH (GH-1) with unit tests of every width and digit against pycryptodome.
4. GCM data path (IN, CT, TG, OU) with unit tests of encryption, decryption, GMAC, errors, release buffer and
   throughput against pycryptodome.
5. Key table (KT-1 to KT-4) with unit tests of erasure, key load, context resolution, IV generation, scrubbing and
   error injection.
6. Register file (MG-1, MG-2) with the generated register map.
7. Core top level (`ocr_core`) with core tests of one core and of two cores in series, the compliance matrix, the
   synthesizability check and the user guide.
