# ocr_core

Top level of OpenCrypto: the GCM data path, the key table and the register file connected to one AES-GCM core with a
context stream, input and output message streams, a status stream, an AXI4-Lite register port and an interrupt. The
user guide ([docs/user_guide.md](../../docs/user_guide.md)) describes its integration.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements of the seams and configuration |
| [Architecture](docs/architecture.md) | Connections of the modules and generics |
| [Verification plan](docs/verification_plan.md) | Test cases and seams |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python run.py -p 4 "*ocr_core_tb*"` (twelve configurations, one of them with two cores in series, six with the
dense output).

| File | Content |
| --- | --- |
| `src/ocr_core.vhd` | Top level |
| `tb/ocr_core_tb.vhd` | VUnit runner with one `run(...)` per test case |
| `tb/ocr_core_th.vhd` | Harness: clock, core A (and core B in series), models, AXI4-Lite VVCs |
| `tb/vunit_config.py` | Configurations and vector files |
