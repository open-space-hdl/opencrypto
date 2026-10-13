# OpenCrypto

[![TRL 3](docs/img/trl-3.svg)](https://openspacehdl.org/trl/)

OpenCrypto is an open AES-GCM core for the authenticated encryption and decryption of real-time data streams, based on
the Open Logic VHDL Library. It implements the AES forward cipher of FIPS 197 with 128-, 192- and 256-bit keys and the
GCM-AE, GCM-AD and GMAC functions of NIST SP 800-38D with the algorithm selection of CCSDS 352.0-B-2 (AES-GCM with
128-bit tags). Messages of additional authenticated data and data travel on AXI4-Stream ports of 16, 32, 64 or 128
bits with back-pressure everywhere and one beat per clock cycle; every message selects its direction, its key slot and
its IV. A key table holds the keys, computes their hash subkeys and generates IVs with the deterministic construction
of SP 800-38D 8.2.1; keys enter through write-only registers and can never be read back. An optional release buffer
delivers a decrypted message only after its tag was verified, and an optional dense output delivers every message as
one gapless byte string. The framer `ocr_framer` in front of the core encrypts packets of any length, for example
compressed images, in self-contained chunks of bounded size with the chunk position as authenticated data. All buffers
and memories use the fault-tolerant entities of [Open Logic](https://github.com/open-logic/open-logic) (SECDED ECC,
scrubbing).

## Status

**Technology readiness level: TRL 3** (fully verified by simulation). The core has not been tested on hardware yet
and has no flight heritage; see [what the levels mean](https://openspacehdl.org/trl/) and the next steps in the
[roadmap](docs/roadmap.md#technology-readiness).

The core is complete and verified in simulation (GHDL and QuestaSim, 76 test cases at unit and core level in 348 test
runs over stream widths of 16 to 128 bits and all three key lengths, with the sectioned and the dense output and with
the framer in front of the core; code coverage closed, the remaining misses justified in
[docs/coverage.md](docs/coverage.md)). Every output byte is compared with the AES and AES-GCM
implementation of pycryptodome, which first reproduces the examples of FIPS 197 and the test cases of the GCM
specification. The [compliance matrix](docs/compliance.md) traces every clause of FIPS 197, SP 800-38D and the AES-GCM
clauses of CCSDS 352.0-B-2 in scope to its requirements and test cases. Two cores in series decrypt what the first one
encrypts; modified tags, AAD and ciphertexts, format errors, wrong key slots and IV sources, exhausted invocation
counters and injected double bit errors are detected and reported with their status. The bottleneck side of
back-to-back messages transfers one beat per clock cycle after the initial latency. The
[user guide](docs/user_guide.md) contains the conformance statement and the obligations that SP 800-38D leaves to the
user. Synthesis results on a target device and a hardware test are open; see [docs/roadmap.md](docs/roadmap.md).

## Documentation

The documents are also published as a website: [openspacehdl.org/opencrypto](https://openspacehdl.org/opencrypto/)
(built from this repository by `tools/docs/`).

| Document | Content |
| --- | --- |
| [docs/architecture.md](docs/architecture.md) | Architecture: building blocks, owned clauses, Open Logic usage, verification, traceability matrix |
| [docs/user_guide.md](docs/user_guide.md) | Integration: sources, generics, interfaces, programming sequence, integration constraints, conformance statement |
| [docs/conventions.md](docs/conventions.md) | Coding, verification and repository conventions |
| [docs/roadmap.md](docs/roadmap.md) | Technology readiness, module status and open items |
| [docs/compliance.md](docs/compliance.md) | Compliance matrix: requirements and test cases of every clause (generated) |
| [docs/coverage.md](docs/coverage.md) | Code coverage of the regression with QuestaSim |
| [hdl/ocr_mib/docs/register_map.md](hdl/ocr_mib/docs/register_map.md) | Register map (generated; C header `sw/ocr_regs.h`) |
| `hdl/<module>/docs/` | Specification, architecture, verification plan and verification report of each module |

## Repository structure

```text
opencrypto/
|-- docs/             Top-level documentation
|-- hdl/<module>/     One folder per module: src/, tb/, docs/
|-- tb/               Verification components shared by the testbenches (vector store, message, context and
|                     status models, AXI4-Lite VVC wrapper)
|-- lint/             VSG configuration (Open Logic rules), synthesizability check
|-- tools/            Test vector generator (pycryptodome), compliance matrix and register map generators
|   `-- docs/         Documentation website (MkDocs)
|-- sw/               C header of the register map (generated)
|-- open-logic/       Git submodule: Open Logic (fault-tolerant entities branch)
|-- uvvm/             Git submodule: UVVM verification framework
|-- component_list.txt  Modules in dependency order
`-- run.py            VUnit regression runner
```

## Running the tests

Prerequisites: Python 3, [GHDL](https://github.com/ghdl/ghdl) on the `PATH` and the Python packages of
`requirements.txt` (VUnit, VSG, PyYAML, pycryptodome).

```shell
git submodule update --init
python -m pip install -r requirements.txt
python run.py -p 4              # full regression with GHDL, 4 parallel simulations
python run.py "*ocr_gcm*"       # one module
python run.py --questa <test>   # QuestaSim
```

`run.py` generates the test vectors with pycryptodome into `vunit_out/vectors/`, compiles Open Logic into the VHDL
library `olo`, the required UVVM components into their own libraries and all OpenCrypto sources into the library
`opencrypto`. `OCR_GHDL_SIM_FLAGS` passes extra flags to the GHDL simulation, for example `--vcd=wave.vcd` for a
waveform.

Checks besides the regression:

```shell
python lint/lint.py                 # VSG, no errors and no warnings
python lint/synth_check.py          # synthesizability of the core and the framer with GHDL
python tools/compliance.py --check  # every clause and requirement traced to a test case
python tools/regmap.py --check      # generated register map files match hdl/ocr_mib/regs/ocr_regs.yml
python -m mkdocs build -f tools/docs/mkdocs.yml  # documentation website, fails on broken links
```

## Licence

OpenCrypto is licensed under the [PSI HDL Library License, Version 1.0](License.txt), the licence of Open Logic
(LGPL 2.1 with an exception for binaries, see [LGPL2_1.txt](LGPL2_1.txt)).
