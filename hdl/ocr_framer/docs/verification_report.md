# ocr_framer: Verification Report

## 1. Test results

Run on 2026-10-15 in the CI job `simulation-ghdl` (Ubuntu 24.04) with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit
4f1e13bf), pycryptodome 3.23.0, Open Logic 4.7.0-ft.6: `python run.py -p 4` (full regression of 441 test runs; this
module: `python run.py "*ocr_framer_tb*"`).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_framer_tb` | 11 (see the verification plan): 6 of the framer alone, 5 of the framer with `ocr_core` | 40 | 40 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass on 2026-10-16 without and with code coverage
(`python run.py --questa -p 1`, `python run.py --questa --coverage -p 1`); the coverage is in
[docs/coverage.md](../../../docs/coverage.md).

GHDL runs before 2026-10-14 passed one list of simulator flags to all simulations (VUnit 5.0.0.dev7 appends the
generics of every test to it), so a GHDL test could run with generics of an earlier test. QuestaSim was not
affected. Since then every GHDL simulation has its own flags and `run.py` checks its generics.

Run on 2026-10-20 with GHDL 6.0.0 (mcode), Open Logic 4.7.0-ft.9, with the register stages of the core:
`ocr_framer_tb` 40 of 40, full regression 447 of 447 passed, 0 skipped; the QuestaSim runs above predate the change.
TC-FR-08: the input has 184, 73 and 49 cycles without a beat at 16, 32 and 64 bits (was 185, 81 and 50); every chunk
still takes exactly C(n) cycles, and all other figures are unchanged.

## 2. Summary

All test cases pass; every requirement of the specification is covered and every seam to the core is crossed (see
the verification plan). The framer in front of a core with the dense output encrypts every chunk with the next
generated IV of its slot; every output message equals IV ‖ AAD ‖ ciphertext ‖ tag of pycryptodome at 16, 32, 64 and
128 bits with AES-128 and AES-256, and the invocation counter of the slot advances by the number of chunks
(TC-FR-06). A double error in the chunk buffer or in the position FIFO fails exactly the message of its chunk with
FORMAT and the error flag, and every error is counted once (TC-FR-04, TC-FR-07). VSG reports no errors and no
warnings; `ghdl --synth` elaborates the framer in five configurations without latches.

Throughput of four long packets (20 chunks) without stall cycles (TC-FR-03), bound AadBeats + 2 cycles per chunk:

| Configuration | Input beats | Cycles without input beat | Bound |
| --- | --- | --- | --- |
| `w16_c32` | 292 | 52 | 80 |
| `w32_c64` | 291 | 42 | 60 |
| `w32_c4096` | 18435 | 42 | 60 |
| `w64_c128_b3` | 290 | 0 | 60 |
| `w128_c256_b4` | 290 | 0 | 60 |
| `w128_c16` | 20 | 46 | 60 |

With the default buffer of two chunks the input pauses about AadBeats + 1 cycles per chunk; a buffer of three or
four chunks absorbs the four packets completely.

Throughput of the framer and the core with the dense output, the same four packets (20 chunks: 18 of C bytes, one of
5 and one of 1 byte) without stall cycles (TC-FR-08). Cycles from the last beat of the first chunk at the output to
the last beat of the last chunk, against the sum of C(n) of the other 19 chunks; cycles without beat at the output
after the first chunk and at the input:

| Configuration | C(C bytes) | Cycles | Sum of C(n) | Output: beats, cycles without beat (expected) | Input: beats, cycles without beat (bound) |
| --- | --- | --- | --- | --- | --- |
| `w16_c32_core` | 32 | 582 | 582 | 580, 2 (2) | 292, 185 (362) |
| `w32_c64_core` | 24 | 429 | 429 | 427, 2 (2) | 291, 81 (202) |
| `w64_c1024_core` | 133 | 2275 | 2275 | 2254, 21 (21) | 2306, 50 (142) |
| `w128_c256_core` | 19 | 333 | 333 | 312, 21 (21) | 290, 42 (102) |
| `w128_c4096_core` | 259 | 4413 | 4413 | 4392, 21 (21) | 4610, 42 (102) |

In front of the core every chunk takes exactly C(n) cycles: the core sets the pace, and the framer and its buffer of
two chunks never hold it up. The first chunk of a sequence is not part of the measurement: its IV beats can leave the
core before the framer has buffered the chunk (store and forward), so its last beat comes up to ceil(n / B) cycles
later than the rate suggests.

Findings:

| Finding | Resolution |
| --- | --- |
| The position "last" of a chunk is known only at its end, but the AAD precedes the DATA section | Store and forward of every chunk in an FT buffer of `BufferChunks_g` chunks (D15) |
| The first measurement of the framer with the core counted the cycles from the first output beat: 147 cycles too many at 64 bits and 1024 bytes, all of them in the first chunk, whose IV beats leave before the chunk is buffered | TC-FR-08 measures from the last beat of the first chunk; the latency of the first chunk is described in the user guide, section 7.2 |
| The first throughput bound of AadBeats + 1 cycles per chunk was exceeded with a buffer of two chunks (2.1 cycles per chunk at 32 bits): the packet FIFO frees a chunk only after it has been read completely, and the next chunk can only start then | The bound is AadBeats + 2 cycles per chunk (FR-PF-01); a larger `BufferChunks_g` absorbs bursts |
| Chunks of fewer than 16 beats, a buffer of 64 chunks and one or 256 key slots had never been elaborated, and `ChunkBytes_g` had no upper bound | `w128_c16` runs chunks of one beat; `lint/synth_check.py` synthesises chunks of 16 and 65536 bytes, 64 chunks and one and 256 slots; `ChunkBytes_g` is at most 65536 (FR-IF-03) |

## 3. Generic values

Declared ranges as in the specification; a value outside them stops the elaboration, and `lint/synth_check.py` checks
the messages of the assertions (width, chunk size). Simulated: the VUnit configurations of `ocr_framer_tb`. Synthesised:
the configurations of `lint/synth_check.py` (`ghdl --synth`, no latch).

| Generic | Declared range | Simulated | Synthesised |
| --- | --- | --- | --- |
| `DataWidth_g` | 16, 32, 64, 128 | 16, 32, 64, 128 | 16, 32, 128 |
| `NumKeys_g` | 1 to 256 | 4 | 1, 4, 16, 256 |
| `ChunkBytes_g` | multiple of 16, 16 to 65536 | 16, 32, 64, 128, 256, 1024, 4096 | 16, 32, 1024, 4096, 65536 |
| `BufferChunks_g` | 2 to 64 | 2, 3, 4 | 2, 4, 64 |
| `RamStyle_g` | RAM styles of Open Logic | "auto" | "auto" |

65536 bytes is the largest chunk that is elaborated and synthesised; the chunker, the chunk buffer and the counters of
the framer are sized from `ChunkBytes_g`. `RamStyle_g` is a synthesis attribute of the chunk buffer and has no effect in
simulation; it is not verified functionally.
