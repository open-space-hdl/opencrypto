# ocr_key_table

Key table (KT-1 to KT-4): key, hash subkey and IV state of `NumKeys_g` key slots in scrubbed SECDED memories, erasure
after the reset and on zeroize, key load with the hash subkey from the AES engine, resolution of one context per
message into a job, and IV generation with the deterministic construction of NIST SP 800-38D 8.2.1.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements and configuration |
| [Architecture](docs/architecture.md) | Memories, load state machine, context resolution, fault tolerance |
| [Verification plan](docs/verification_plan.md) | Test cases |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python run.py -p 4 "*ocr_key_table_tb*"` (five configurations of key length and number of slots).

| File | Content |
| --- | --- |
| `src/ocr_key_table.vhd` | Key table |
| `tb/ocr_key_table_tb.vhd` | VUnit runner with one `run(...)` per test case |
| `tb/ocr_key_table_th.vhd` | Harness: clock, key table, context source, job checker, AES model of the hash subkey port |
| `tb/vunit_config.py` | Configurations and vector files |
