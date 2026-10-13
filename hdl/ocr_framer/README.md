# ocr_framer

Framer (FR-1) in front of `ocr_core`: cuts packets of any length into chunks of `ChunkBytes_g` bytes and hands every
chunk to the core as one message with a 4-byte AAD that carries the position of the chunk in its packet (first,
middle, last, only), together with one context per chunk for an encryption with a generated IV.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements and configuration |
| [Architecture](docs/architecture.md) | Chunker, chunk buffer, positions, contexts, fault tolerance |
| [Verification plan](docs/verification_plan.md) | Test cases |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python run.py -p 4 "*ocr_framer*"` (the framer alone at every data width, and the framer with `ocr_core`
against pycryptodome).

| File | Content |
| --- | --- |
| `src/ocr_framer.vhd` | Framer |
| `tb/ocr_framer_tb.vhd` | VUnit runner with one `run(...)` per test case |
| `tb/ocr_framer_th.vhd` | Harness: clock, packet source, framer, context checker and message sink, or `ocr_core` with the dense output and its sinks |
| `tb/vunit_config.py` | Configurations and vector files |
