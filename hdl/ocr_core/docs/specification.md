# ocr_core: Specification

## 1. Overview

`ocr_core` is the top level of OpenCrypto: the GCM data path (`ocr_gcm`), the key table (`ocr_key_table`), the
register file (`ocr_mib`) and, with `DenseOutput_g`, the output packer (`ocr_packer`) connected to one core with a
context stream, an input and an output message stream, a status stream, an AXI4-Lite register port and an
interrupt. The requirements of this specification cover the seams
between the modules: keys loaded through the register file encrypt and decrypt the messages, the key table state is
visible in the registers, every status is counted, every buffer and memory is monitored through one EDAC monitor.
The requirements of the functions themselves are in the specifications of the modules.

## 2. Requirements

### 2.1 Interfaces and registers

| ID | Requirement | Clauses |
| --- | --- | --- |
| CO-IF-01 | The core shall have the interfaces of the architecture section 6: `S_Ctx`, `S_In`, `M_Out` and `M_Sts` with valid / ready, the AXI4-Lite register port and `Irq`, all in `Clk` with the synchronous high-active reset `Rst`. | GCM 5.2 |
| CO-IF-02 | The generics registers shall report the configuration of the core, with the numbers of AES units and GHASH digits that the core uses (the defaults of the width when the generics are 0) and the dense output (`GENERICS.DENSE`). | CCSDS 3.2 |

### 2.2 Functions across the modules

| ID | Requirement | Clauses |
| --- | --- | --- |
| CO-FN-01 | Messages of both directions with keys of several slots, loaded through the register file, shall be encrypted with GCM-AE and decrypted with GCM-AD; every status shall increment its counter and set its event flag. | GCM 7.1, 7.2; CCSDS 3.4.1 |
| CO-FN-02 | Encryptions with generated IVs shall carry the IV of the key table in their IV section, and the invocation counter of the slot in SLOT_COUNT shall advance by one per encryption. | GCM 8.2.1, 9.1 |
| CO-FN-03 | Contexts of an unloaded slot, of a slot out of range, with the wrong IV source or of an exhausted slot shall be rejected with their status, counted and flagged; SLOT_STATUS shall report the exhausted slot. | GCM 8.2, 8.3 |
| CO-FN-04 | ZEROIZE shall erase every key slot: the slots read as invalid, messages fail with KEY, and new loads restore the operation. | GCM 5.1 |
| CO-FN-05 | Two cores in series, the first encrypting and the second decrypting with the same keys, shall return the input of the first core at the output of the second. | GCM 7.1, 7.2 |
| CO-FN-06 | The reset shall erase every key slot and restart the core from any state; after a new load the messages shall be processed correctly. | none (D13) |
| CO-FN-07 | With `DenseOutput_g` every output message (encryptions with external and generated IVs, decryptions, failed and rejected messages, with and without the release buffer) shall leave as the gapless byte string of its sections (format of the output packer), with the same bytes, error flag and status as without the dense output. | none (D14) |

### 2.3 Performance, fault tolerance and interrupt

| ID | Requirement | Clauses |
| --- | --- | --- |
| CO-PF-01 | For back-to-back messages without stall cycles the bottleneck side shall have at most 40 cycles without a beat (GC-PF-01) with the defaults of the width. | none (D3) |
| CO-PF-02 | With `DenseOutput_g` and back-to-back messages without stall cycles, the output of encryptions shall have at most 40 cycles without a beat plus the beats saved by the packing plus one per message, and the input of decryptions at most 40 cycles without a beat plus one per message. | none (D3, D14) |
| CO-PF-03 | Back-to-back encryptions with generated IVs and at least three output beats each, without stall cycles, shall take after the first message exactly their sectioned output beats in clock cycles, with `DenseOutput_g` plus one for a message whose last beat does not fit into the output beat with the bytes before it. | none (D3, D8) |
| CO-PF-04 | With `ReleaseBuffer_g` and back-to-back messages without stall cycles, the bottleneck side shall have at most 40 cycles without a beat plus one per message while the buffer holds two consecutive messages, and a message of M sectioned output beats in a buffer of D = `ReleaseBytes_g` / (`DataWidth_g` / 8) beats shall take at most max(B + 2, 3 M - D + 4) clock cycles after the first message, B being its beats on the bottleneck side. | none (D3, D10) |
| CO-FT-01 | ECC_INJECT shall reach every buffer of the data path and every memory and the job FIFO of the key table; single errors shall be corrected, double errors shall fail the message with ECC; every error shall be counted in its channel of the EDAC monitor and set its DED flag and event. | none (P5) |
| CO-IRQ-01 | An enabled event shall drive `Irq` until its flag is cleared. | none (D11) |

## 3. Configuration parameters

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `DataWidth_g` | 32 | 16, 32, 64, 128 | Width of the message streams |
| `KeyBits_g` | 256 | 128, 192, 256 | Key length |
| `NumKeys_g` | 4 | 1 to 256 | Number of key slots |
| `AesUnits_g` | 0 | 0, ceil(Nr / R) to Nr | Round units of the AES engine; 0 selects ceil(2 Nr / (R + 1)) |
| `GhashDigit_g` | 0 | 0, `DataWidth_g` to 128 | GHASH digit; 0 selects 128 for 64 and 128 bits, 64 otherwise |
| `LenBits_g` | 32 | 8 to 32 | Width of the byte counts |
| `ReleaseBuffer_g` | false | | Release buffer at the output |
| `ReleaseBytes_g` | 4096 | power of two, 16 beats to 65536 | Size of the release buffer in bytes |
| `DenseOutput_g` | false | | Dense output: the output messages leave as gapless byte strings |
| `ClkFreqHz_g` | 100.0e6 | ≥ 1000 when `ScrubPeriod_g` > 0 | Clock frequency, sizes the pacer of the key table scrubbers |
| `ScrubPeriod_g` | 0.0 | 0.0 or ≥ 0.001 | Scrub period of the key table in seconds; 0.0 free-running |
