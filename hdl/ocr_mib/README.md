# ocr_mib

Management information base (MG-1, MG-2): AXI4-Lite register file with the key load through write-only staging
registers, zeroize, slot query, message counters, event flags and interrupt, EDAC monitor of all buffers and memories
and error injection. The register map is generated from `regs/ocr_regs.yml` by `tools/regmap.py`.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements and configuration |
| [Architecture](docs/architecture.md) | Register bus, key load, query, counters, EDAC channels |
| [Register map](docs/register_map.md) | Registers and fields (generated) |
| [Verification plan](docs/verification_plan.md) | Test cases |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python run.py -p 4 "*ocr_mib_tb*"`.

| File | Content |
| --- | --- |
| `regs/ocr_regs.yml` | Register description |
| `src/ocr_mib.vhd` | Register file |
| `tb/ocr_mib_tb.vhd` | VUnit runner with one `run(...)` per test case |
| `tb/ocr_mib_th.vhd` | Harness: clock, register file, AXI4-Lite VVC |
