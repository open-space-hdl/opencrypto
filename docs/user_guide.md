# OpenCrypto User Guide

This guide describes how to integrate the OpenCrypto core `ocr_core` and its framer `ocr_framer` into an FPGA
design: sources, generics, clock and reset, interfaces, the programming sequence, the protection scope, the
performance, the integration constraints with the obligations that the user of AES-GCM keeps, and the conformance
statement for FIPS 197, NIST SP 800-38D and CCSDS 352.0-B-2. The architecture is described in
[architecture.md](architecture.md), the registers in the generated [register map](../hdl/ocr_mib/docs/register_map.md).

## 1. Sources

| Library | Sources | Order |
| --- | --- | --- |
| `olo` | Open Logic areas `base`, `axi` and `ft` of the submodule `open-logic/` | `open-logic/compile_order.txt` |
| `opencrypto` | `hdl/<module>/src/*.vhd` of every module of `component_list.txt` | `compile_order.txt` |

All sources are VHDL-2008 and contain no vendor primitive. `compile_order.txt` in the repository root lists every
synthesis source of the library `opencrypto` in compile order, one path per line relative to the repository root,
like the file of the same name of Open Logic. `python run.py --compile-order` generates it from the dependency scan of
VUnit, and the CI checks that it is current.

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
| `DenseOutput_g` | false | Dense output: every output message leaves as one gapless byte string (section 4.5) |
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
convention); synchronise its release to `Clk`, for example with `olo_base_reset_gen` with `SyncTmr_g` = true
(triplicated synchroniser). After the reset the key table erases every slot (`NumKeys_g` clock cycles,
`STATUS.BUSY` = '1'); contexts and key loads are accepted afterwards. No key survives a reset.

Every stream transfers one beat per clock cycle while its partner is ready; section 7 gives the clock cycles per
message and per chunk.

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
- With `DenseOutput_g` the output messages have no gaps at the section ends (section 4.5).

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

### 4.5 Dense output

With `DenseOutput_g` = true the output packer closes the gaps that the sections leave at their ends. Every output
message is one byte string IV ‖ AAD ‖ DATA ‖ TAG (the sections it has, in this order) without gaps: all bytes of a
beat are valid except in the last beat of the message, whose valid bytes are contiguous from lane 0.

| Signal | Sectioned output (default) | Dense output |
| --- | --- | --- |
| `M_Out_Keep` | Partial in the last beat of every section | Partial in the last beat of the message only |
| `M_Out_User(1:0)` | Section of the beat | Section of the first byte of the beat |
| `M_Out_User(2)` | Error flag on the last beat of the message | Unchanged |

The bytes, the status and the error flag are the same in both formats; a message without any byte is one beat without
valid byte in both. The section boundaries follow from the lengths: the IV section has 12 bytes, the TAG section 16
bytes, and the status reports the AAD and DATA bytes. The packer adds one clock cycle of latency; after the last beat
of a message whose bytes need one more output beat it takes no input for one cycle. Use the sectioned output when
the output feeds the input of a second core (decryption).

### 4.6 Framer (`ocr_framer`)

The framer sits in front of the core and encrypts packets of any length, for example compressed images, in messages
of bounded size. It cuts every packet into chunks of `ChunkBytes_g` bytes (the last chunk of a packet has the
remaining bytes, without padding) and sends every chunk as one message: an AAD section of 4 bytes with the position
of the chunk in its packet, then the chunk as DATA section. For every chunk it hands one context to the core: an
encryption with a generated IV of the slot `Cfg_Slot`.

| Generic | Default | Description |
| --- | --- | --- |
| `DataWidth_g` | 32 | Width of the streams: the `DataWidth_g` of the core |
| `NumKeys_g` | 4 | The `NumKeys_g` of the core (width of the slot) |
| `ChunkBytes_g` | 4096 | Bytes of a chunk, a multiple of 16 |
| `BufferChunks_g` | 2 | Chunks that the chunk buffer holds (2 to 64) |
| `RamStyle_g` | "auto" | RAM style of the chunk buffer |

| Port | Direction | Connection |
| --- | --- | --- |
| `Clk`, `Rst` | in | The clock and reset of the core |
| `Cfg_Slot` | in | Key slot of the contexts; static, loaded with `IV_GEN` = '1' |
| `S_In_*` (`Valid`, `Ready`, `Data`, `Keep`, `Last`) | in | Packets: all bytes valid except in the last beat of a packet, contiguous from lane 0; a packet without byte is one beat without valid byte |
| `M_Ctx_*` | out | `S_Ctx_*` of the core, signal by signal |
| `M_Out_*` (`Valid`, `Ready`, `Data`, `Keep`, `Last`, `User(1:0)`) | out | `S_In_*` of the core, signal by signal |
| `Ecc_Sec(1:0)`, `Ecc_Ded(1:0)` | out | Corrected and detected errors (pulses) of the chunk buffer (0) and of the position FIFO (1), for example to an EDAC monitor |
| `ErrInj_Sel`, `ErrInj_BitFlip(1:0)`, `ErrInj_Valid` | in | Error injection into the next word written to the chunk buffer ('0') or the position FIFO ('1'): "01" single, "11" double error; tests only |

The position is in bits 7:6 of the first AAD byte; all other AAD bits are '0':

| Position | Chunk |
| --- | --- |
| "01" | First chunk of a packet with several chunks |
| "00" | Middle chunk |
| "10" | Last chunk of a packet with several chunks |
| "11" | The only chunk of its packet |

The framer buffers every chunk completely before it sends it, because the position "last" is known only at the end
of a chunk. The buffer holds `BufferChunks_g` chunks, so it takes the next chunk while one leaves. With an output
that is always ready the input pauses for at most ceil(4 / (`DataWidth_g` / 8)) + 2 cycles per chunk; in front of
the core it follows the rate of the core (section 7.2). The chunk buffer and the position FIFO are SECDED-protected:
a single error is corrected; a double error marks the affected beat with the IV section code, which the core rejects
(FORMAT, error flag, zero tag), so a corrupted chunk never leaves with a valid tag.

With the dense output every chunk leaves the core as one byte string:

| Bytes | Content |
| --- | --- |
| 0 to 11 | IV: fixed field of the slot ‖ invocation counter (GCM 8.2.1) |
| 12 to 15 | Position (AAD) |
| 16 to 16 + n - 1 | Ciphertext of the n bytes of the chunk |
| 16 + n to 31 + n | Tag |

IV and position fill one 128-bit block, so the ciphertext starts on a beat boundary at every data width. A receiver
decrypts every chunk on its own: IV from bytes 0 to 11, AAD from bytes 12 to 15, tag from the last 16 bytes; it
discards a chunk whose tag fails, orders the chunks by the invocation counter (a gap marks a lost chunk) and finds
the packet boundaries in the positions. Every chunk consumes one invocation of the slot: save the counter regularly
(section 8, GCM 9.1).

### 4.7 Example: encrypted image packets

A compressor such as OpenCompact delivers each compressed image as one packet (first byte in lane 0). The chain
compressor → `ocr_framer` → `ocr_core` (`DenseOutput_g` = true) → send port of a packet service (for example the
Octet String Service of OpenSPP) turns every image into a sequence of space packets of at most `ChunkBytes_g` + 32
bytes of user data, each one authenticated on its own. The send port needs a buffer of at least `ChunkBytes_g` + 32
bytes; every packet is unsegmented, the image boundaries are in the authenticated positions.

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
   4) to non-volatile memory, ahead of the operational value (section 8).
8. To change the key of a slot, stop sending contexts of the slot, wait for the status of its last message and load
   the slot again. `CTRL.ZEROIZE` erases every slot and the staging registers at once.

A context is resolved against the slot when the key table reads it, which can be up to a few messages before the
message reaches the data path. A message whose context was resolved before a load uses the previous key; a context
of a slot that is being loaded fails with KEY.

## 6. Protection scope

The core is designed for radiation environments together with the triple modular redundancy (TMR) of the synthesis
tool, like the Open Logic ft entities it is built on. It protects the parts in the first rows itself and relies on
TMR for all other logic:

| Part | Protection | Indication and test |
| --- | --- | --- |
| Key table: key, hash subkey and IV memories of the slots (`olo_ft_ram_sdp_scrub` with background scrubbing) | SECDED ECC of the Open Logic ft entities: a single error is corrected, a double error is detected and contained: the messages of the slot are rejected with ECC and no key leaves the table; the slot is usable again after a new load | Status ECC, `ERR_ECC`, `ECC_STATUS` and `ECC_COUNT` (channels 11 to 16), events `ECC_SEC`, `ECC_DED` and `ECC` with `Irq`; error injection through the `ECC_INJECT` register |
| Buffers of the core: job FIFO of the contexts, data, keystream, J0, hash, output, hash subkey, descriptor, summary, result and status FIFOs (`olo_ft_fifo_sync`), release buffer (`olo_ft_fifo_packet`) | SECDED ECC of the Open Logic ft entities: a single error is corrected, a double error is detected and contained: the message whose data the entry held fails with ECC; while it is in the core its last beat carries the error flag and the tag of an encryption is zero, and with `ReleaseBuffer_g` it does not leave the core; a double error in the release buffer ends the message with the error flag | Status ECC, `ERR_ECC`, `ECC_STATUS` and `ECC_COUNT` (channels 0 to 10 and 17), events `ECC_SEC`, `ECC_DED` and `ECC` with `Irq`; error injection through the `ECC_INJECT` register |
| `ocr_framer`: chunk buffer (`olo_ft_fifo_packet`) and position FIFO (`olo_ft_fifo_sync`) | SECDED ECC of the Open Logic ft entities: a single error is corrected, a double error is detected and contained: the affected beat leaves with the IV section code, so the core fails the message with FORMAT, the error flag and a zero tag (with `ReleaseBuffer_g` the message does not leave the core); a corrupted chunk never leaves with a valid tag | Ports `Ecc_Sec(1:0)` and `Ecc_Ded(1:0)` of the framer, status FORMAT of the core; error injection through the `ErrInj_*` ports of the framer |
| Clock domain crossings and reset synchronisers | The core has one clock domain and no synchroniser of its own. Synchronise the release of `Rst` with a triplicated synchroniser, for example `olo_base_reset_gen` with `SyncTmr_g` = true: three synchroniser chains and a majority voter. Their registers carry the Synplify attribute `syn_radhardlevel` = `none`, so the TMR of the synthesis tool adds no voters between the stages | none |
| State machines | Recovery state through the `when others` branch and the reset | none |
| All other logic: registers of the control and data paths, counters, pointers, pipeline registers | TMR of the synthesis tool (for example `syn_radhardlevel` = `tmr` with Synplify, or the equivalent setting of the tool chain). The core adds no protection of its own for this logic; without TMR, an upset in it is not covered | synthesis report |

The integrator:

- enables the TMR of the synthesis tool for the core and the logic around it,
- checks in the synthesis report that TMR was applied, that the synchroniser chains of the crossings were not
  triplicated a second time, and that no register-based storage meant to be protected by TMR was inferred as a RAM
  primitive,
- requests safe state machines, so that synthesis keeps the `when others` branches (AMD Vivado: property
  `FSM_SAFE_STATE` = `default_state` on the state registers; Synplify: attribute `syn_encoding` = `safe`),
- protects the configuration memory of SRAM-based FPGAs by scrubbing; this is part of the FPGA design, not of the
  core.

The ECC paths are verified in simulation by error injection. Whether the protection as a whole meets the
requirements of a mission is shown by a radiation test with the core in operation (TRL 5).

## 7. Performance

The figures are clock cycles of `Clk`. They follow from the RTL, and the test cases in the tables measure them in
simulation. B = `DataWidth_g` / 8 is the number of bytes of a beat; a stream with one beat per cycle carries 8 B bits
per cycle, for example 12.8 Gbit/s at 128 bits and 100 MHz. The clock frequency that a device reaches is a result of
synthesis and timing closure ([roadmap](roadmap.md), TRL 4) and not part of these figures.

### 7.1 Core

Every stream transfers one beat per clock cycle while its partner is ready. A message with A bytes of AAD and P
bytes of DATA has these beats (a section that the message does not have has no beat, an empty section has one):

| Interface | Encryption | Decryption |
| --- | --- | --- |
| `S_In` | ceil(A / B) + ceil(P / B) | ceil(A / B) + ceil(P / B) + 16 / B |
| `M_Out`, sectioned | g · ceil(12 / B) + ceil(A / B) + ceil(P / B) + 16 / B | ceil(A / B) + ceil(P / B) |
| `M_Out`, dense (`DenseOutput_g`) | ceil((12 g + A + P + 16) / B) | ceil((A + P) / B) |

g is 1 for a generated IV (IV section at the output) and 0 otherwise; a message without any output byte is one beat.

For back-to-back messages the side with more beats is the bottleneck: the output of encryptions, the input of
decryptions. After the start of a sequence it transfers one beat in every cycle, so a message takes as many clock
cycles as it has beats on that side (the sectioned beats for encryptions), and the other side pauses for the
difference. The parts of a message cost, with the default numbers of AES units and GHASH digits:

| Part | Clock cycles per message on the bottleneck side | Test |
| --- | --- | --- |
| AAD | ceil(A / B), on both sides | TC-CO-10, TC-CO-11 |
| DATA | ceil(P / B), on both sides | TC-CO-10, TC-CO-11 |
| Tag | 16 / B, at the output of encryptions and at the input of decryptions | TC-CO-10, TC-CO-11 |
| Generated IV | ceil(12 / B) output beats. Consecutive encryptions with generated IVs need at least three output beats per message (the IV generation unit updates the counter of the slot once per message) | TC-CO-14 |
| J0 (pre-counter block) | None: E(K, J0) takes one block of the AES engine per message, in a cycle without keystream request | TC-CO-10, TC-CO-14 |
| Dense output | Encryptions take the cycles of the sectioned output and send fewer beats in them, plus one cycle when 12 g + A + P is not a multiple of B (the last beat does not fit into the output beat with the bytes before it). Decryptions lose at most one input cycle per message. Latency: one cycle | TC-CO-10, TC-CO-11, TC-CO-14, TC-PA-03 |
| Release buffer (`ReleaseBuffer_g`) | One to two cycles per message while the buffer holds two consecutive messages (2 M ≤ D for messages of M sectioned output beats in a buffer of D = `ReleaseBytes_g` / B beats). With 2 M > D a message takes up to 3 M - D + 4 cycles, because the next message waits for the space of the one before. A message leaves only when its last beat is in the buffer | TC-CO-10, TC-CO-11, TC-CO-15 |
| Start of a sequence | At most 40 cycles without a beat in total | TC-CO-10, TC-CO-11 |

Size `ReleaseBytes_g` for at least two of the longest messages. With fewer AES units or a smaller GHASH digit than
the defaults, a message takes at least (ceil(P / 16) + 1) · Nr / `AesUnits_g` cycles (keystream blocks and J0, Nr =
10, 12 or 14 rounds, TC-AE-03) and at least 128 / `GhashDigit_g` · (ceil(A / 16) + ceil(P / 16) + 1) cycles (blocks
and length block, TC-GH-03); the largest of these figures and the beats sets the rate.

Contexts: one per message, handed over before or with its message. The key table resolves one context per clock
cycle with an external IV and one per two cycles with a generated IV (TC-KT-09); up to four resolved contexts wait in
its job FIFO. The key slot can change from message to message without a lost cycle: the throughput tests draw the
slot of every message from up to three slots (TC-CO-10, TC-CO-11). The throughput of mixed sequences of encryptions
and decryptions and of key loads during traffic is not characterised.

Every core has its own key table and data path, so N cores carry N times the rate of one core. Cores that use the
same key need distinct fixed fields (section 8).

### 7.2 Framer and core

The framer hands the core one message per chunk of n bytes (n = `ChunkBytes_g`, the last chunk of a packet has the
remaining 1 to `ChunkBytes_g` bytes). With the dense output of the core:

| Point | Beats per chunk | Bytes per chunk |
| --- | --- | --- |
| `S_In` of the framer | ceil(n / B) | n |
| `M_Out` of the framer, `S_In` of the core | ceil(4 / B) + ceil(n / B) | n + 4 (AAD) |
| `M_Out` of the core | ceil((n + 32) / B) | n + 32 (IV 12, AAD 4, tag 16) |

With an output that is always ready the core sets the pace, and every chunk takes exactly

C(n) = ceil(12 / B) + ceil(4 / B) + ceil(n / B) + 16 / B clock cycles,

plus one when n is not a multiple of B (only the last chunk of a packet can be). The framer takes ceil(n / B) input
beats in these cycles and pauses for the rest. TC-FR-08 measures C(n) exactly at all four data widths. For chunks of
4096 bytes:

| `DataWidth_g` | C(4096) | Input beats | Output beats | Payload share of the cycles | Payload at 100 MHz |
| --- | --- | --- | --- | --- | --- |
| 16 | 2064 | 2048 | 2064 | 99.2 % | 1.59 Gbit/s |
| 32 | 1032 | 1024 | 1032 | 99.2 % | 3.18 Gbit/s |
| 64 | 517 | 512 | 516 | 99.0 % | 6.34 Gbit/s |
| 128 | 259 | 256 | 258 | 98.8 % | 12.65 Gbit/s |

The payload rate scales with the clock frequency. A slower source sets a lower rate; the core then waits for the
chunks. With the release buffer the core holds the C(n) sectioned beats of a chunk: a chunk takes one cycle more
while the buffer holds two chunks, so choose `ReleaseBytes_g` as the power of two of at least 2 · B · C(n) bytes, for
example 16384 bytes for chunks of 4096 bytes at 128 bits (260 cycles per chunk). A buffer of 8192 bytes holds one
chunk but not two, and a chunk then takes 3 · 259 - 512 + 4 = 269 cycles (section 7.1). A chunk leaves after its last byte has entered the framer (store and forward), so its latency is at least
ceil(n / B) cycles after its first input beat; the IV beats of a chunk can leave before, and the output then pauses
until the rest of the chunk follows. The framer alone, with an output that is always ready, pauses its input for at
most ceil(4 / B) + 2 cycles per chunk (TC-FR-03).

## 8. Integration constraints

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
| `ocr_framer`: the slot `Cfg_Slot` is loaded for generated IVs and stays unchanged while the framer holds chunks; the framer and the core share clock and reset | Every chunk is an encryption with a generated IV; a reset of only one of them leaves contexts or messages without partner |
| Hold the section in `TUser` constant within a section and start every section with a new beat | Message format (section 4.2) |
| The release buffer holds the longest message | Longer messages are dropped with OVERFLOW |
| `ECC_INJECT` is for tests only | An injected double error fails a message |
| Use AES-256 for new CCSDS missions | CCSDS 352.0-B-2 3.2.1; AES-128 is allowed for existing implementations (3.2.2), AES-192 is not part of CCSDS 352.0-B-2 |
| TMR of the synthesis tool enabled for the core | The core protects its key table, buffers and framer buffers itself and relies on TMR for all other logic (section 6) |

## 9. Conformance

### 9.1 AES (FIPS 197)

| Clause | Function | Implementation |
| --- | --- | --- |
| 3, 4 | Notation, bytes, State, finite field arithmetic | Implemented |
| 5.1 | Cipher | Implemented (forward cipher) |
| 5.2 | Key expansion | Implemented, on the fly with every block |
| 5.3 | Inverse cipher | Not implemented: GCM uses only the forward cipher (GCM 5.1) |
| 6.1, 6.3 | Key lengths 128, 192 and 256 bits | Implemented, one key length per core (`KeyBits_g`) |
| 6.2 | Keying restrictions | Every key is accepted (AES has no weak keys) |
| 6.4 | Implementation variations | Iterative round units, any number from the minimum to Nr |

### 9.2 GCM (NIST SP 800-38D)

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
| 5.1 | Block cipher | AES; keys secret (section 8) |
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

### 9.3 CCSDS 352.0-B-2 (AES-GCM)

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

## 10. Verification and tools

```shell
python run.py -p 4                          # regression with GHDL
python run.py --questa --coverage -p 1      # code coverage with QuestaSim
python run.py --compile-order               # compile_order.txt of the synthesis sources
python lint/lint.py                         # VSG
python lint/synth_check.py                  # synthesizability of the core and the framer with GHDL
python tools/compliance.py --check          # traceability of FIPS 197, SP 800-38D and CCSDS 352.0-B-2
python tools/regmap.py --check              # generated register map up to date
python tools/ocr_vectors.py --selftest      # pycryptodome against the examples of the standards
```

The expected values of every test come from the AES and AES-GCM implementation of pycryptodome; the vector
generator checks first that pycryptodome reproduces the examples of FIPS 197 (Appendix C) and the test cases of the
GCM specification with 96-bit IVs.
