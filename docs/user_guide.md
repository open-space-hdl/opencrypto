# OpenCrypto User Guide

This guide describes how to integrate the OpenCrypto core `ocr_core` into an FPGA design: sources, generics, clock
and reset, interfaces, the programming sequence, the integration constraints with the obligations that the user of
AES-GCM keeps, and the conformance statement for FIPS 197, NIST SP 800-38D and CCSDS 352.0-B-2. The architecture is
described in [architecture.md](architecture.md), the registers in the generated
[register map](../hdl/ocr_mib/docs/register_map.md).

## 1. Sources

| Library | Sources | Order |
| --- | --- | --- |
| `olo` | Open Logic areas `base`, `axi` and `ft` of the submodule `open-logic/` | `open-logic/compile_order.txt` |
| `opencrypto` | `hdl/<module>/src/*.vhd` of every module of `component_list.txt` | Modules in the order of `component_list.txt`; within a module packages first (`ocr_pkg.vhd`, `ocr_regs_pkg.vhd`, `ocr_gcm_pkg.vhd`) |

All sources are VHDL-2008 and contain no vendor primitive.

## 2. Generics

| Generic | Default | Description |
| --- | --- | --- |
| `DataWidth_g` | 32 | Width of the message streams in bits: 16, 32, 64 or 128 |
| `KeyBits_g` | 256 | Key length: 128, 192 or 256 bits (one length per core) |
| `NumKeys_g` | 4 | Key slots (1 to 256); `S_Ctx_Slot` and `M_Sts_Slot` have max(1, ceil(log2(`NumKeys_g`))) bits |
| `AesUnits_g` | 0 | Round units of the AES engine; 0 selects the default of the width (table below) |
| `GhashDigit_g` | 0 | Bits per cycle of the GHASH multiplier, `DataWidth_g` to 128; 0 selects 128 for 64 and 128 bits, 64 for 16 and 32 bits |
| `LenBits_g` | 32 | Width of the byte counts: AAD and DATA sections of up to 2<sup>`LenBits_g`</sup> - 1 bytes (8 to 32) |
| `ReleaseBuffer_g` | false | Release buffer at the output: a message leaves the core only when its status is OK |
| `ReleaseBytes_g` | 4096 | Size of the release buffer in bytes: a power of two of at least 16 beats; longer messages are dropped with OVERFLOW |
| `ClkFreqHz_g` | 100.0e6 | Clock frequency, sizes the pacer of the key table scrubbers |
| `ScrubPeriod_g` | 0.0 | Scrub period of the key table in seconds; 0 scrubs in every cycle without access |

Default numbers of AES units (ceil(2 Nr / (R + 1)) with R = 128 / `DataWidth_g` beats per block) and the minimum
(ceil(Nr / R)), which sustains long messages only:

| `DataWidth_g` | AES-128 default (minimum) | AES-192 default (minimum) | AES-256 default (minimum) |
| --- | --- | --- | --- |
| 16 | 3 (2) | 3 (2) | 4 (2) |
| 32 | 4 (3) | 5 (3) | 6 (4) |
| 64 | 7 (5) | 8 (6) | 10 (7) |
| 128 | 10 (10) | 12 (12) | 14 (14) |

Every unit is one iterative AES round with its key expansion; the AES engine is the largest part of the core. The
generics registers report the values that the core uses.

## 3. Clock and reset

All of the core runs in `Clk`; there is no clock domain crossing. `Rst` is synchronous and high-active (Open Logic
convention); synchronise its release to `Clk`, for example with `olo_ft_reset_gen`. After the reset the key table
erases every slot (`NumKeys_g` clock cycles, `STATUS.BUSY` = '1'); contexts and key loads are accepted afterwards.
No key survives a reset.

Every stream transfers one beat per clock cycle while its partner is ready. For back-to-back messages the bottleneck
side (the output of encryptions, the input of decryptions) transfers one beat per clock cycle after the initial
latency, for every message length, with the default numbers of AES units and GHASH digits. Exception: consecutive
encryptions with generated IVs need at least three output beats per message (the IV generation unit updates the
counter of the slot once per message). At 100 MHz and 32 bits the core carries 3.2 Gbit/s.

## 4. Interfaces

### 4.1 Contexts (`S_Ctx_*`)

One context per message, in the order of the messages, with valid / ready. A context can be handed over before its
message.

| Signal | Width | Meaning |
| --- | --- | --- |
| `S_Ctx_Decrypt` | 1 | '0' GCM-AE (encryption), '1' GCM-AD (decryption) |
| `S_Ctx_Slot` | slot bits | Key slot |
| `S_Ctx_IvGen` | 1 | '1': the IV generation unit of the slot supplies the IV (encryptions of a slot loaded with `IV_GEN`) |
| `S_Ctx_Iv` | 96 | IV of the message when `S_Ctx_IvGen` = '0'; IV byte 0 in bits 95:88 |

### 4.2 Input messages (`S_In_*`) and output messages (`M_Out_*`)

AXI4-Stream with `TKeep`; one message per packet of the stream, `TLast` marks its last beat. `TUser(1:0)` is the
section of the beat:

| Code | Section | Encryption input | Encryption output | Decryption input | Decryption output |
| --- | --- | --- | --- | --- | --- |
| "11" | IV | not allowed | first, 12 bytes, when the IV was generated | not allowed | not used |
| "01" | AAD | optional, first | AAD as received | optional, first | AAD as received |
| "00" | DATA | optional, after the AAD | ciphertext | optional, after the AAD | plaintext |
| "10" | TAG | not allowed | last, 16 bytes | required, last, 16 bytes | not used |

- A section starts with a new beat. Byte lane 0 (`TData(7:0)`) holds the first byte of a beat; the first byte of a
  section is the leftmost byte of its first block.
- All bytes of a beat are valid except in the last beat of a section, whose valid bytes are contiguous from lane 0.
  A section of one beat without a valid byte is an empty section; an empty message is one such beat.
- `M_Out_User(2)` is the error flag on the last beat of a message: '1' when the status of the message is not OK.
- A message without any output byte (the decryption of an empty message, a message rejected by its context) is one
  beat without a valid byte, with `TLast`.
- A message without DATA section is a GMAC message: the encryption outputs the AAD and the tag, the decryption
  verifies the tag of the AAD.
- With `ReleaseBuffer_g` a message whose status is not OK does not leave the core; its status does.

### 4.3 Status (`M_Sts_*`)

One status per message, in the order of the messages, with valid / ready.

| Signal | Width | Meaning |
| --- | --- | --- |
| `M_Sts_Code` | 4 | Status code (table below) |
| `M_Sts_Decrypt` | 1 | Direction of the message |
| `M_Sts_Slot` | slot bits | Key slot of the context |
| `M_Sts_Iv` | 96 | IV that the message used (the generated IV for `S_Ctx_IvGen` = '1') |
| `M_Sts_AadBytes`, `M_Sts_DataBytes` | `LenBits_g` | Numbers of AAD and DATA bytes (saturated); 0 for a message rejected by its context |

| Code | Name | Meaning |
| --- | --- | --- |
| 0 | OK | Message processed; for a decryption the tag was verified |
| 1 | AUTH | Decryption: the computed tag differs from the received tag (FAIL of GCM-AD) |
| 2 | FORMAT | Section order, byte enables, IV or TAG section on the wrong side, TAG missing or not 16 bytes |
| 3 | KEY | Key slot out of range or not loaded |
| 4 | IV_MODE | IV source not allowed by the slot, or a generated IV for a decryption |
| 5 | IV_EXHAUSTED | The invocation counter of the slot has reached its last value |
| 6 | LENGTH | AAD or DATA longer than 2<sup>`LenBits_g`</sup> - 1 bytes |
| 7 | ECC | Uncorrectable double error in a buffer or memory that held data of the message |
| 8 | OVERFLOW | Release buffer: the message was longer than the buffer and was dropped |

When a message has several errors, the code of the highest precedence is reported: ECC, KEY, IV_MODE, IV_EXHAUSTED,
FORMAT, LENGTH, AUTH, OVERFLOW. The TAG section of a failed encryption is all zeros. A message that its context
rejects (KEY, IV_MODE, IV_EXHAUSTED, ECC of the key table) is consumed without processing.

`M_Sts_Ready` may stay '1' if the status is not used; a status FIFO of 16 entries stalls the output when it is full.

### 4.4 Register file and interrupt

AXI4-Lite slave with 8-bit byte addresses and 32-bit registers ([register map](../hdl/ocr_mib/docs/register_map.md),
C header `sw/ocr_regs.h`). `Irq` is the OR of the event flags enabled in `IRQ_EN`.

## 5. Programming sequence

1. After the reset wait until `STATUS.BUSY` is '0'.
2. Read `ID` (0x4F435201), `GENERICS`, `GENERICS2` and `RELEASE_BYTES` to identify the core and its configuration.
3. Load every key slot in use:
    1. Write the key to `KEY0` to `KEY3`, `KEY5` or `KEY7` (4, 6 or 8 words; key byte 4 n in bits 31:24 of `KEYn`).
    2. For a slot with generated IVs write the fixed field to `IV_FIXED` and the first invocation counter to
       `IV_COUNT_LO` and `IV_COUNT_HI`.
    3. Write `KEY_LOAD` with `START`, the slot and `IV_GEN` ('1' generated IVs, '0' IVs of the context).
    4. Wait until `STATUS.BUSY` is '0' (or for the event `LOAD_DONE`). The staging registers are cleared.
4. Optionally check a slot: write the slot to `SLOT_QUERY`, wait until `SLOT_STATUS.PENDING` is '0', read
   `SLOT_STATUS`, `SLOT_FIXED` and `SLOT_COUNT_LO`/`HI`.
5. Write `IRQ_EN` for the events of interest and clear `EVENTS` by writing ones.
6. Send contexts and messages; take the output messages and the status of every message.
7. In operation read the counters (cleared by a write, all cleared by `CTRL.CLEAR`), `ECC_STATUS` and `ECC_COUNT`
   (channel selected by `ECC_SELECT`). Save the invocation counter of every slot with generated IVs regularly (step
   4) to non-volatile memory, ahead of the operational value (section 6).
8. To change the key of a slot, stop sending contexts of the slot, wait for the status of its last message and load
   the slot again. `CTRL.ZEROIZE` erases every slot and the staging registers at once.

A context is resolved against the slot when the key table reads it, which can be up to a few messages before the
message reaches the data path. A message whose context was resolved before a load uses the previous key; a context
of a slot that is being loaded fails with KEY.

## 6. Integration constraints

The core implements the cryptographic functions of GCM. NIST SP 800-38D places further requirements on the system
that uses it; the table lists them with the support of the core and what the user keeps.

| Requirement | Clauses | Core | User |
| --- | --- | --- | --- |
| Keys are secret | GCM 5.1, 5.3 | Write-only staging registers that clear with the load; no read path to keys and hash subkeys; keys erased on reset and zeroize; jobs with an error carry no key | Restrict the access to the AXI4-Lite port to trusted software; deliver keys over a protected path |
| Keys are fresh | GCM 8.1 | | Establish keys with an approved key management that excludes the replay of an old key |
| IVs are unique per key | GCM 8 | IV generation unit with the deterministic construction (8.2.1) per slot | For slots with external IVs: generate IVs with the deterministic construction (8.2.1) or the RBG-based construction (8.2.2) outside the core |
| One IV construction per key | GCM 8.2 | Each slot is loaded for generated or for external IVs; a context with the other source fails with IV_MODE | Use one construction per key also across devices |
| Fixed field identifies the device | GCM 8.2.1 | 32-bit fixed field per slot, from `IV_FIXED` | Assign a distinct fixed field to every device and context that uses the same key |
| Number of invocations | GCM 8.3 | 64-bit invocation counter; the slot is exhausted at 2<sup>64</sup> - 1 (IV_EXHAUSTED) | For external IVs from an RBG: at most 2<sup>32</sup> encryptions per key |
| No IV repetition after a loss of power | GCM 9.1 | The counter of a slot is readable (`SLOT_COUNT`) and loadable (`IV_COUNT`); after a reset no slot is valid, so the core cannot encrypt before a new load | Save the counter ahead of the operational value and load the slot after a power cycle with a counter beyond every used value, or establish a fresh key |
| Plaintext only after verification | GCM 5.2.2, 7.2 | With `ReleaseBuffer_g` a decrypted message leaves only when its tag is verified; without it the plaintext streams and the last beat carries the verdict | Without release buffer: discard every message whose last beat carries the error flag or whose status is not OK |
| Operational considerations | GCM 9.2 | | Document the key management, the fixed field assignment, the counter backup and the access control of the system |

Further constraints:

| Constraint | Reason |
| --- | --- |
| One context per message, in the order of the messages | The core pairs the n-th context with the n-th message |
| Hold the section in `TUser` constant within a section and start every section with a new beat | Message format (section 4.2) |
| The release buffer holds the longest message | Longer messages are dropped with OVERFLOW |
| `ECC_INJECT` is for tests only | An injected double error fails a message |
| Use AES-256 for new CCSDS missions | CCSDS 352.0-B-2 3.2.1; AES-128 is allowed for existing implementations (3.2.2), AES-192 is not part of CCSDS 352.0-B-2 |
| Protect the control registers of the core by the TMR of the synthesis tool when the mission requires it | Memories and buffers are SECDED-protected; the state machines recover from an illegal state, but an upset in a control register can corrupt a message in flight (it is then detected by the tag of the receiver) |

## 7. Conformance

### 7.1 AES (FIPS 197)

| Clause | Function | Implementation |
| --- | --- | --- |
| 3, 4 | Notation, bytes, State, finite field arithmetic | Implemented |
| 5.1 | Cipher | Implemented (forward cipher) |
| 5.2 | Key expansion | Implemented, on the fly with every block |
| 5.3 | Inverse cipher | Not implemented: GCM uses only the forward cipher (GCM 5.1) |
| 6.1, 6.3 | Key lengths 128, 192 and 256 bits | Implemented, one key length per core (`KeyBits_g`) |
| 6.2 | Keying restrictions | Every key is accepted (AES has no weak keys) |
| 6.4 | Implementation variations | Iterative round units, any number from the minimum to Nr |

### 7.2 GCM (NIST SP 800-38D)

OpenCrypto conforms to both categories of GCM 10: GCM (messages with DATA) and GMAC (messages without DATA). The
supported lengths (GCM 5.2.1.1, 5.2.1.2):

| Parameter | Supported |
| --- | --- |
| Block cipher | AES-128, AES-192, AES-256 |
| IV | 96 bits |
| Tag | 128 bits |
| Plaintext and AAD | 0 to 2<sup>`LenBits_g`</sup> - 1 bytes each (multiples of 8 bits) |

| Clause | Function | Implementation |
| --- | --- | --- |
| 5.1 | Block cipher | AES; keys secret (section 6) |
| 5.2, 5.2.1, 5.2.2 | GCM-AE, GCM-AD, GMAC, input and output data | Implemented |
| 5.3, 6.2 to 6.5 | Primitives: inc32, multiplication, GHASH, GCTR | Implemented |
| 7.1, 7.2 | Authenticated encryption and decryption | Implemented; FAIL is the status AUTH with the error flag, and the release buffer withholds the plaintext |
| 8 | Uniqueness of IVs | Generated IVs: implemented; external IVs: user |
| 8.1 | Key establishment | User |
| 8.2 | One construction per key | Implemented per slot |
| 8.2.1 | Deterministic construction | Implemented: 32-bit fixed field, 64-bit invocation counter |
| 8.2.2 | RBG-based construction | User (external IVs) |
| 8.3 | Number of invocations | Implemented for generated IVs; user for external IVs |
| 9.1 | Generation unit, IV protection, loss of power | Generation unit in the core, counter backup by the user |
| 9.2 | Operational considerations | User |
| 10 | Conformance | GCM and GMAC with the lengths above |

### 7.3 CCSDS 352.0-B-2 (AES-GCM)

| Clause | Requirement | Implementation |
| --- | --- | --- |
| 3.1 | AES for encryption | Implemented |
| 3.2.1 | 256-bit key for future missions | `KeyBits_g` = 256 (default) |
| 3.2.2 | 128-bit key for existing implementations | `KeyBits_g` = 128 |
| 3.3 | Counter mode | Implemented as the GCTR function of GCM |
| 3.4.1 | GCM for authenticated encryption | Implemented |
| 3.4.2 | MAC size of 128 bits | Implemented (the only tag length) |
| 4.3.2 | GMAC for authentication only | Implemented (messages without DATA) |

The [compliance matrix](compliance.md) lists the requirements and the test cases of every clause. The
interpretations of the standards are listed in the sections "Interpretation of the standard" of the module
specifications.

## 8. Verification and tools

```shell
python run.py -p 4                          # regression with GHDL
python run.py --questa --coverage -p 1      # code coverage with QuestaSim
python lint/lint.py                         # VSG
python lint/synth_check.py                  # synthesizability of four core configurations with GHDL
python tools/compliance.py --check          # traceability of FIPS 197, SP 800-38D and CCSDS 352.0-B-2
python tools/regmap.py --check              # generated register map up to date
python tools/ocr_vectors.py --selftest      # pycryptodome against the examples of the standards
```

The expected values of every test come from the AES and AES-GCM implementation of pycryptodome; the vector
generator checks first that pycryptodome reproduces the examples of FIPS 197 (Appendix C) and the test cases of the
GCM specification with 96-bit IVs.
