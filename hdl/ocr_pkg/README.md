# ocr_pkg

Common functions of OpenCrypto (CM-1): AES transformations and key expansion on the fly (FIPS 197), multiplication in
GF(2<sup>128</sup>) (NIST SP 800-38D), byte order of blocks and beats, section and status codes, defaults of the
generics.

| Document | Content |
| --- | --- |
| [Specification](docs/specification.md) | Requirements |
| [Architecture](docs/architecture.md) | Functions, key expansion in steps, digit multiplication |
| [Verification plan](docs/verification_plan.md) | Test cases |
| [Verification report](docs/verification_report.md) | Results |

Tests: `python run.py -p 4 "*ocr_pkg*"`.

| File | Content |
| --- | --- |
| `src/ocr_pkg.vhd` | The package |
| `tb/ocr_pkg_tb.vhd` | VUnit runner with one `run(...)` per test case |
| `tb/vunit_config.py` | Vector files of pycryptodome and of the standards |
