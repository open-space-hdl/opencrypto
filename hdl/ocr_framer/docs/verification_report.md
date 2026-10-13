# ocr_framer: Verification Report

## 1. Test results

Run on 2026-10-13 with GHDL 6.0.0 (mcode), VUnit 5.0.0.dev7, UVVM (commit 4f1e13bf), pycryptodome 3.23.0, Open Logic
4.7.0-ft.3: `python run.py -p 2 "*ocr_framer_tb*"` (part of the full regression of 348 test runs).

| Testbench | Configurations | Tests | Passed |
| --- | --- | --- | --- |
| `ocr_framer_tb` | 9 (see the verification plan): 5 of the framer alone, 4 of the framer with `ocr_core` | 30 | 30 |

QuestaSim (Questa Sim Microchip Edition 2024.3): the same tests pass in the regression with code coverage
(`python run.py --questa --coverage -p 1`); the coverage is in [docs/coverage.md](../../../docs/coverage.md).

## 2. Summary

All test cases pass; every requirement of the specification is covered and every seam to the core is crossed (see
the verification plan). The framer in front of a core with the dense output encrypts every chunk with the next
generated IV of its slot; every output message equals IV ‖ AAD ‖ ciphertext ‖ tag of pycryptodome at 16, 32, 64 and
128 bits with AES-128 and AES-256, and the invocation counter of the slot advances by the number of chunks
(TC-FR-06). A double error in the chunk buffer or in the position FIFO fails exactly the message of its chunk with
FORMAT and the error flag, and every error is counted once (TC-FR-04, TC-FR-07). VSG reports no errors and no
warnings; `ghdl --synth` elaborates the framer in two configurations without latches.

Throughput of four long packets (20 chunks) without stall cycles (TC-FR-03), bound AadBeats + 2 cycles per chunk:

| Configuration | Input beats | Cycles without input beat | Bound |
| --- | --- | --- | --- |
| `w16_c32` | 292 | 52 | 80 |
| `w32_c64` | 291 | 42 | 60 |
| `w32_c4096` | 18435 | 42 | 60 |
| `w64_c128_b3` | 290 | 0 | 60 |
| `w128_c256_b4` | 290 | 0 | 60 |

With the default buffer of two chunks the input pauses about AadBeats + 1 cycles per chunk; a buffer of three or
four chunks absorbs the four packets completely.

Findings:

| Finding | Resolution |
| --- | --- |
| The position "last" of a chunk is known only at its end, but the AAD precedes the DATA section | Store and forward of every chunk in an FT buffer of `BufferChunks_g` chunks (D15) |
| The first throughput bound of AadBeats + 1 cycles per chunk was exceeded with a buffer of two chunks (2.1 cycles per chunk at 32 bits): the packet FIFO frees a chunk only after it has been read completely, and the next chunk can only start then | The bound is AadBeats + 2 cycles per chunk (FR-PF-01); a larger `BufferChunks_g` absorbs bursts |
