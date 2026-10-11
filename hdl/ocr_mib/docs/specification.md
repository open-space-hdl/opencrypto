# ocr_mib: Specification

## 1. Overview

`ocr_mib` is the management information base of OpenCrypto (MG-1, MG-2): the register file behind an AXI4-Lite slave
with the key load through write-only staging registers, zeroize, the slot query, the message counters and event
flags with the interrupt, and the EDAC monitor of all buffers and memories with the error injection. The register map
is generated from `hdl/ocr_mib/regs/ocr_regs.yml` ([register map](register_map.md)).

## 2. Requirements

### 2.1 Interface and product information

| ID | Requirement | Clauses |
| --- | --- | --- |
| MG-IF-01 | The register file shall be an AXI4-Lite slave with 8-bit byte addresses and 32-bit registers as in the register map; addresses without a register shall read as zero and ignore writes. | none (architecture section 7.5) |
| MG-IF-02 | The identification register and the generics registers shall report the register map version, the data width, the key length, the number of key slots, the release buffer and its size, the number of AES units, the GHASH digit and the width of the byte counts. | CCSDS 3.2 |
| MG-IF-03 | After the reset every register shall hold its reset value of the register map. | none (D13) |

### 2.2 Key material

| ID | Requirement | Clauses |
| --- | --- | --- |
| MG-KL-01 | The key staging registers, the fixed field and the first invocation counter shall be write-only (read as zero) and shall be cleared when the key table takes the load and on zeroize. | GCM 5.1 |
| MG-KL-02 | A write of KEY_LOAD with START shall pass the staged key, the IV construction, the fixed field and the counter to the key table for the given slot; a start for a slot out of range or while a load is pending shall be ignored; STATUS.BUSY shall be '1' from the start to the end of the load, and the end of the load shall set the event LOAD_DONE. | GCM 7.1, 8.2.1 |
| MG-KL-03 | A write of CTRL with ZEROIZE shall give one zeroize command to the key table, erase the staging registers and cancel a pending load. | GCM 5.1 |
| MG-QU-01 | A write of SLOT_QUERY shall query the slot in the key table; SLOT_STATUS shall report PENDING until the answer and then the valid flag, the IV construction, the exhausted flag and the double error flag; SLOT_FIXED and SLOT_COUNT shall report the fixed field and the next invocation counter; a slot out of range shall read as erased. No register shall return a key or a hash subkey. | GCM 5.1, 9.1 |

### 2.3 Counters, events and interrupt

| ID | Requirement | Clauses |
| --- | --- | --- |
| MG-CN-01 | Every status of a message shall increment one 32-bit saturating counter: ENCRYPTIONS or DECRYPTIONS for OK, the counter of its code otherwise; a code without meaning (9 to 15) shall change no counter and no event flag; a write to a counter shall clear it, CTRL.CLEAR shall clear all. | none (D11) |
| MG-EV-01 | Every error code, every corrected and every detected ECC error and every completed key load shall set its event flag; a flag shall be cleared by writing one to it. | none (D11) |
| MG-IRQ-01 | `Irq` shall be the OR of the event flags enabled in IRQ_EN. | none (D11) |

### 2.4 EDAC monitor and error injection

| ID | Requirement | Clauses |
| --- | --- | --- |
| MG-ECC-01 | The SEC and DED events of the 18 channels (11 buffers of the data path, the reads and scrubbers of the three key table memories, the job FIFO) shall be counted per channel in 16-bit counters, readable through ECC_SELECT and ECC_COUNT; ECC_STATUS shall hold one sticky DED flag per channel; a write of ECC_COUNT shall clear the counters of the selected channel, a write of ECC_STATUS all counters and flags. | none (P5) |
| MG-INJ-01 | A write of ECC_INJECT with SINGLE or DOUBLE shall inject a single or double error into the next word of the target: targets 0 to 10 the buffers of the data path, 16 to 18 the key, H and IV word of the next key load, 19 the next job; a write without SINGLE and DOUBLE shall inject nothing. | none (P5) |

## 3. Interpretation of the standard

- GCM 5.1 requires the key to be secret. Keys enter the core only through the write-only staging registers, which
  clear themselves with the load, and no register reads a key or a hash subkey back.
- GCM 9.1 requires the IV state to survive a loss of power. SLOT_COUNT returns the next invocation counter of a slot
  for its backup; the user writes a counter beyond every used value into IV_COUNT before the load of the slot after a
  power cycle.

## 4. Configuration parameters

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `DataWidth_g` | 32 | 16, 32, 64, 128 | Width of the message streams (GENERICS) |
| `KeyBits_g` | 256 | 128, 192, 256 | Key length |
| `NumKeys_g` | 4 | 1 to 256 | Number of key slots |
| `AesUnits_g` | 6 | 1 to 14 | Number of AES units (GENERICS) |
| `GhashDigit_g` | 64 | 16 to 128 | GHASH digit (GENERICS2) |
| `LenBits_g` | 32 | 8 to 32 | Width of the byte counts (GENERICS2) |
| `ReleaseBuffer_g` | false | | Release buffer implemented (GENERICS) |
| `ReleaseBytes_g` | 0 | ≥ 0 | Size of the release buffer (RELEASE_BYTES) |
