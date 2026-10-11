# ocr_mib: Verification Plan

## 1. Overview

The register file is driven through the UVVM AXI4-Lite VVC. The test sequencer plays the key table (load and query
handshakes, busy flag), the data path (status events) and the FT buffers (ECC events), and counts the zeroize
commands and the error injection strobes. Every register value is checked against the register map, using the
constants of the generated `ocr_regs_pkg`.

## 2. Test configuration

| Testbench | Harness | DUT and environment |
| --- | --- | --- |
| `ocr_mib_tb` | `ocr_mib_th` | `ocr_mib` at 100 MHz with 64-bit data, AES-256, 4 key slots, 10 AES units, 128-bit GHASH digit, 20-bit byte counts, release buffer of 2048 bytes; UVVM AXI4-Lite VVC |

One configuration: the register file does not depend on the generics beyond the values it reports and the slot
number width; the core tests (TC-CO-01) read the generics registers in four configurations. Simulator: GHDL;
QuestaSim for code coverage.

## 3. Test cases

| Test ID | Description | Requirements |
| --- | --- | --- |
| `test_reset_values` (TC-MG-01) | ID, generics, release buffer size and the reset value of every register with a fixed reset value; unused addresses read as zero and ignore writes; STATUS.BUSY follows the key table | MG-IF-01 to 03 |
| `test_key_load` (TC-MG-02) | Staged key, IV construction, fixed field and counter at the load port; KEY and IV_FIXED read as zero; staging cleared at the acceptance; BUSY during the load; LOAD_DONE; a load of a slot out of range, KEY_LOAD without START and a start while a load runs are ignored | MG-KL-01, MG-KL-02 |
| `test_zeroize` (TC-MG-03) | ZEROIZE: one command to the key table, staged key erased, the next load presents zeros | MG-KL-01, MG-KL-03 |
| `test_query` (TC-MG-04) | SLOT_QUERY: request, PENDING, SLOT_STATUS, SLOT_FIXED, SLOT_COUNT; a slot out of range reads as erased | MG-QU-01 |
| `test_counters` (TC-MG-05) | Status events of every code and direction: counters, event flags, clear of every counter by a write, CTRL.CLEAR, W1C of the events; codes 9 to 15 change nothing | MG-CN-01, MG-EV-01 |
| `test_irq` (TC-MG-06) | Irq only for enabled flags, cleared with the flag, ECC_DED interrupt | MG-IRQ-01, MG-EV-01 |
| `test_ecc` (TC-MG-07) | SEC and DED events on all 18 channels: counters per channel, sticky DED flags, ECC_SEC and ECC_DED events, clear of one channel and of all | MG-ECC-01, MG-EV-01 |
| `test_inject` (TC-MG-08) | ECC_INJECT: single error into data path target 7, double error into key table target 18, no injection without SINGLE or DOUBLE | MG-INJ-01 |

## 4. Requirement coverage

| Requirement | Test cases |
| --- | --- |
| MG-IF-01 to MG-IF-03 | TC-MG-01 |
| MG-KL-01 | TC-MG-02, TC-MG-03 |
| MG-KL-02 | TC-MG-02 |
| MG-KL-03 | TC-MG-03 |
| MG-QU-01 | TC-MG-04 |
| MG-CN-01 | TC-MG-05 |
| MG-EV-01 | TC-MG-05 to TC-MG-07 |
| MG-IRQ-01 | TC-MG-06 |
| MG-ECC-01 | TC-MG-07 |
| MG-INJ-01 | TC-MG-08 |
