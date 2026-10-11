# ocr_aes

AES engine (AE-1): the forward cipher of FIPS 197 for keys of 128, 192 and 256 bits with `Units_g` iterative round
units, the round keys expanded on the fly from the key of every request, a fixed latency of Nr + 1 clock cycles and a
throughput of `Units_g` / Nr blocks per clock cycle.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements and configuration |
| [Architecture](docs/architecture.md) | Round units, dispatch, latency |
| [Verification plan](docs/verification_plan.md) | Test cases |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python run.py -p 4 "*ocr_aes*"` (every test for nine combinations of key length and number of units).

| File | Content |
| --- | --- |
| `src/ocr_aes_unit.vhd` | Round unit |
| `src/ocr_aes_engine.vhd` | Engine: units, round-robin dispatch, output register |
| `tb/ocr_aes_engine_tb.vhd` | VUnit runner with one `run(...)` per test case |
| `tb/ocr_aes_engine_th.vhd` | Harness: clock, engine, request source, result checker |
| `tb/vunit_config.py` | Configurations and vector files |
