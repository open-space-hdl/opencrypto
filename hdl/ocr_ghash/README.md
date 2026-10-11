# ocr_ghash

GHASH (GH-1): block assembly with zero padding and length block, digit-serial multiplication in
GF(2<sup>128</sup>) with `Digit_g` bits per clock cycle, S and the byte counts of the AAD and the ciphertext per
message.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements and configuration |
| [Architecture](docs/architecture.md) | Block assembly, queue, multiplier |
| [Verification plan](docs/verification_plan.md) | Test cases |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python run.py -p 4 "*ocr_ghash*"` (every test for eight combinations of data width and digit).

| File | Content |
| --- | --- |
| `src/ocr_ghash.vhd` | GHASH |
| `tb/ocr_ghash_tb.vhd` | VUnit runner with one `run(...)` per test case |
| `tb/ocr_ghash_th.vhd` | Harness: clock, GHASH, beat source, H source, result checker |
| `tb/vunit_config.py` | Configurations and vector files |
