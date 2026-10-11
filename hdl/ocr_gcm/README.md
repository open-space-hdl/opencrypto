# ocr_gcm

GCM data path (IN-1, IN-2, AE-1, CT-1, GH-1, TG-1, OU-1 to OU-3): authenticated encryption and decryption of sectioned
messages with the key, hash subkey and IV of a job per message, one beat per clock cycle, optional release buffer,
one status per message.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements and configuration |
| [Architecture](docs/architecture.md) | Stages, buffers, credits, output state machine, throughput |
| [Verification plan](docs/verification_plan.md) | Test cases |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python run.py -p 4 "*ocr_gcm_tb*"` (eleven configurations of width, key length, AES units, GHASH digit,
release buffer and byte counts).

| File | Content |
| --- | --- |
| `src/ocr_gcm_pkg.vhd` | Entries of the FIFOs between the stages, ECC buffer indices |
| `src/ocr_gcm_input.vhd` | Input parser and counter blocks |
| `src/ocr_gcm_keystream.vhd` | AES engine with credits, keystream and J0 FIFOs, hash subkey requests |
| `src/ocr_gcm_combine.vhd` | GCTR combiner |
| `src/ocr_gcm_tag.vhd` | Tag stage |
| `src/ocr_gcm_output.vhd` | Output assembly and status |
| `src/ocr_gcm.vhd` | Top level with the FT buffers and the release buffer |
| `tb/ocr_gcm_tb.vhd` | VUnit runner with one `run(...)` per test case |
| `tb/ocr_gcm_th.vhd` | Harness: clock, data path, models |
| `tb/ocr_gcm_job_source.vhd` | Job source model |
| `tb/vunit_config.py` | Configurations and vector files |
