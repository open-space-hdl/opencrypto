# OpenCrypto Roadmap

The development follows the plan of the [architecture](architecture.md) (section 11). This page tracks the state of
every module; a module is done when its verification report is written and its regression is green.

## Technology readiness

The core is at **TRL 3**: fully verified by simulation, not yet tested on hardware, no flight heritage. The
[TRL page](https://openspacehdl.org/trl/) explains what the levels mean for an IP core.

| Next level | What is needed | State |
| --- | --- | --- |
| TRL 4 | Synthesis and timing closure on a target FPGA; hardware test of encryption and decryption against an independent AES-GCM implementation (for example pycryptodome on a host connected through a link core), with key loads, generated IVs, every status code and the error injection; hardware test plan and test report | Open (see the open items) |
| TRL 5 | Single-event effects test (beam test) on a radiation-tolerant FPGA with the core in operation that confirms the single-event mitigation and quantifies the error rates; operation over the temperature range | Open |

## Modules

| Module | Blocks (architecture section 7) | Status |
| --- | --- | --- |
| `ocr_pkg` | CM-1 (AES transformations, GF arithmetic, formats), register package | Done |
| `tb` (shared) | Vector store, message, context and status models, AXI4-Lite VVC wrapper | Done |
| `ocr_aes` | AE-1 (AES engine) | Done |
| `ocr_ghash` | GH-1 (GHASH) | Done |
| `ocr_gcm` | IN-1, IN-2, CT-1, TG-1, OU-1 to OU-3 (GCM data path) | Done |
| `ocr_key_table` | KT-1 to KT-4 (key table, IV generation unit) | Done |
| `ocr_mib` | MG-1, MG-2 (register file, EDAC monitor) | Done |
| `ocr_core` | Core top level | Done |

## Open items

| Item | State |
| --- | --- |
| Synthesis on a target device: resources and timing | Open; `lint/synth_check.py` checks the synthesizability of four core configurations with GHDL |
| Hardware test against an independent AES-GCM implementation | Open |
| Code coverage with QuestaSim | Done: [coverage.md](coverage.md) |
| IV lengths other than 96 bits (GCM 5.2.1.1) | Not planned: 96-bit IVs are the recommended length and the only length of the deterministic construction with a 32-bit fixed field |
| Tags shorter than 128 bits (GCM 5.2.1.2, Appendix C) | Not planned: CCSDS 352.0-B-2 3.4.2 requires 128 bits |
| Several key lengths in one core | Not planned: one key length per core (`KeyBits_g`) |
