# ocr_packer

Output packer (OU-4) of the dense output of `ocr_core`: closes the gaps that the sections of an output message leave
at their ends, so that the message leaves as a gapless byte stream with only its last beat partial.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements and configuration |
| [Architecture](docs/architecture.md) | Residual register, rotation, flush |
| [Verification plan](docs/verification_plan.md) | Test cases |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python run.py -p 4 "*ocr_packer*"` (every test at 16, 32, 64 and 128 bits).

| File | Content |
| --- | --- |
| `src/ocr_packer.vhd` | Output packer |
| `tb/ocr_packer_tb.vhd` | VUnit runner with one `run(...)` per test case |
| `tb/ocr_packer_th.vhd` | Harness: clock, message source, packer, dense message sink |
| `tb/vunit_config.py` | Configurations and vector files |
