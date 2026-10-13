# ocr_framer: Architecture

## 1. Structure

![Block diagram of ocr_framer: olo_base_chunker at the input, the write logic with the context counter, the chunk
buffer (olo_ft_fifo_packet) and the position FIFO (olo_ft_fifo_sync), the output state machine with the AAD and the
output register (olo_base_pl_stage)](img/ocr_framer_arch.drawio.svg)

| Part | Function | Open Logic |
| --- | --- | --- |
| Chunker | Cuts the input packets into chunks of `ChunkBytes_g` / B beats (B = `DataWidth_g` / 8): `Last` at the end of every chunk, `InLast` at the end of the packet; pass-through without latency | `olo_base_chunker` |
| Write logic | Writes the beats with their byte enables into the chunk buffer and, with the last beat of a chunk, its position into the position FIFO; counts the contexts owed to the core | none |
| Chunk buffer | Store and forward of complete chunks: data and byte enables per word, `BufferChunks_g` chunks (power of two of words), up to 4 · `BufferChunks_g` chunks | `olo_ft_fifo_packet` (SECDED) |
| Position FIFO | One position per complete chunk | `olo_ft_fifo_sync` (SECDED) |
| Output state machine | AAD beats with the position, then the beats of the chunk as DATA section | none |
| Output register | Cuts the path from the RAM and the ECC decoder of the buffer to the core | `olo_base_pl_stage` |

## 2. Chunk position

The position is known when the last beat of a chunk is written: the chunk is the first one of its packet when the
previous chunk ended a packet (or after the reset), and the last one when its last beat carries `InLast`. The
position is written into the position FIFO in the same cycle as the last beat into the chunk buffer, so a chunk is
complete in the buffer when its position is in the FIFO. Encoding (CCSDS sequence flags), bits 7:6 of AAD byte 0:

| First | Last | Position |
| --- | --- | --- |
| yes | no | "01" |
| no | no | "00" |
| no | yes | "10" |
| yes | yes | "11" |

Because the AAD precedes the DATA section (GCM 7.1, input format of the core) and the last chunk of a packet is only
known at its end, the framer cannot stream a chunk through: it buffers every chunk completely (FR-FN-04).

## 3. Output state machine

| State | Output | Next |
| --- | --- | --- |
| `Idle_s` | none | `Aad_s` when the position FIFO holds a position (taken in this cycle) |
| `Aad_s` | AadBeats beats of the AAD section: position in bits 7:6 of byte 0, bytes 1 to 3 zero, byte enables of the 4 bytes | `Data_s` after the last AAD beat |
| `Data_s` | The beats of the chunk from the buffer as DATA section, `Last` with the last beat of the chunk | `Aad_s` of the next chunk in the same cycle when its position is there, else `Idle_s` |

The `when others` branch returns an illegal state to `Idle_s` (D13).

## 4. Contexts

A context is owed to the core when the first beat of a chunk is written. `M_Ctx_Valid` is '1' while contexts are
owed; the core takes them ahead of the messages (it pairs the n-th context with the n-th message). The counter of
owed contexts is bounded: a chunk starts only when the counter has room (it never limits in operation, since the
core takes a context before it processes the message). The context is an encryption (`M_Ctx_Decrypt` = '0') with a
generated IV (`M_Ctx_IvGen` = '1', `M_Ctx_Iv` zero) of the slot `Cfg_Slot`.

## 5. Fault tolerance

| Location | Upset | Effect |
| --- | --- | --- |
| Chunk buffer word | Single error | Corrected, `Ecc_Sec(0)` |
| | Double error | The word leaves with the section code IV; the core fails the message (FORMAT), its tag is zero and its last beat carries the error flag; `Ecc_Ded(0)` |
| Position FIFO entry | Single error | Corrected, `Ecc_Sec(1)` |
| | Double error | The AAD leaves with the section code IV; the core fails the message (FORMAT); `Ecc_Ded(1)` |
| Packet boundaries of the chunk buffer, state machine, counters | Any | Registers: the TMR of the synthesis tool covers them where the mission requires it (D13); the reset recovers from any state |

The IV of a failed chunk is consumed, so a receiver sees a gap in the invocation counters of the correct chunks.

## 6. Timing and throughput

The output carries AadBeats more beats per chunk than the input. With the default buffer of two chunks the buffer
frees a chunk only after it has been read completely, which costs about one more cycle per chunk; the input pauses
at most AadBeats + 2 cycles per chunk while the outputs are always ready (FR-PF-01). A buffer of more chunks absorbs
bursts but does not change the steady state, which the output rate sets. A chunk leaves after its last beat has been
written (store and forward), behind its AAD beats and the output register.
