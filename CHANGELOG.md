# Changelog

The notable changes of OpenCrypto. The versions follow semantic versioning: 0.y.z while the core is at TRL 3, a
major version for an incompatible change of ports, stream formats, generics or register map, a minor version for a
feature and a patch version for a fix.

## [Unreleased]

### Changed

- Open Logic 4.7.0-ft.9 (from 4.7.0-ft.6); no port or generic of OpenCrypto changes.
- The key table resolves one context with a generated IV per three clock cycles (was two); contexts with external IVs
  stay at one per clock cycle. Up to seven resolved contexts wait in the key table (job FIFO of five entries, was
  four, and its output register of two).
- Latencies: a job leaves the key table two clock cycles later (a second read stage and the output register of the
  jobs), a data beat reaches the combiner one clock cycle later (output register of the data FIFO), and the dense
  output adds two clock cycles of latency (was one: input register of the packer).

### Fixed

- Setup timing at 200 MHz on AMD Versal devices: the read of a key memory, the job FIFO, the data FIFO or the release
  buffer (dense output) no longer passes the SECDED decoder, the logic behind it and the encoder of the next memory
  in one clock cycle. The key memories register their decoded word, and register stages follow the job FIFO and the
  data FIFO and precede the packer.

## [0.1.0] - 2026-10-18

First release. AES-GCM authenticated encryption and decryption of real-time data streams (FIPS 197, NIST SP 800-38D)
with 128-, 192- and 256-bit keys, a key table with an IV generation unit per slot, an optional dense output and the
framer for packets of any length. Verified by simulation (TRL 3) in GHDL and QuestaSim, on Open Logic 4.7.0-ft.6.
