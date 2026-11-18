# Changelog

The notable changes of OpenCrypto. The versions follow semantic versioning: 0.y.z while the core is at TRL 3, a
major version for an incompatible change of ports, stream formats, generics or register map, a minor version for a
feature and a patch version for a fix.

## [0.1.1] - 2026-11-18

A patch release: register stages on the memory read paths for setup timing at 200 MHz, and Open Logic 4.8.0-ft.2.
The ports, generics, stream formats and the register map are those of 0.1.0.

### Changed

- Open Logic 4.8.0-ft.2 (1f4a6c3), based on Open Logic 4.8.0 (from 4.7.0-ft.6). The Open Logic sources that
  OpenCrypto uses are identical in both tags, so no port, generic or behaviour of OpenCrypto changes through the pin.
- The key table resolves one context with a generated IV per three clock cycles (was two); contexts with external IVs
  stay at one per clock cycle. Up to seven resolved contexts wait in the key table (job FIFO of five entries, was
  four, and its output register of two).
- Latencies: a job leaves the key table two clock cycles later (a second read stage and the output register of the
  jobs), a data beat reaches the combiner one clock cycle later (output register of the data FIFO), and the dense
  output adds two clock cycles of latency (was one: input register of the packer).
- Verification: the test end compares the alert counters of every level itself and ends the simulation with a
  failure, whatever the stop limits of the test.
- Documentation: a functional reset of the core (`Rst` asserted while the system keeps running) erases the keys and
  the IV state like a power-up. KT-IV-03 and the user guide (clock and reset, programming sequence, integration
  constraints) state the duty of the software after any reset: wait until `STATUS.BUSY` is '0', reload the keys and
  restore the invocation counters beyond every value used with the key before a slot is used again (NIST SP 800-38D
  8, 9.1).

### Fixed

- Register stages for setup timing at 200 MHz on AMD Versal devices: an implementation at 200 MHz missed setup timing
  where the read of a key memory, the job FIFO, the data FIFO or the release buffer (dense output) passed the SECDED
  decoder, the logic behind it and the encoder of the next memory in one clock cycle. The key memories now register
  their decoded word, and register stages follow the job FIFO and the data FIFO and precede the packer. This release
  has no implementation result at 200 MHz; timing closure at 200 MHz will be shown with the next implementation in a
  reference system of the family.
- Documentation website: builds with Python-Markdown 3.11.3 (heading anchors hook takes the new optional argument;
  markdown pinned).

## [0.1.0] - 2026-10-18

First release. AES-GCM authenticated encryption and decryption of real-time data streams (FIPS 197, NIST SP 800-38D)
with 128-, 192- and 256-bit keys, a key table with an IV generation unit per slot, an optional dense output and the
framer for packets of any length. Verified by simulation (TRL 3) in GHDL and QuestaSim, on Open Logic 4.7.0-ft.6.
