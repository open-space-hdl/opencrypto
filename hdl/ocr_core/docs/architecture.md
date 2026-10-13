# ocr_core: Architecture

## 1. Structure

![Block diagram of ocr_core: ocr_mib, ocr_key_table, ocr_gcm and the optional ocr_packer with the signal groups
between them](img/ocr_core_arch.drawio.svg)

The core contains no logic of its own: it connects the modules and resolves the generics. With `DenseOutput_g` the
output packer (`ocr_packer`, OU-4) sits between the output of the data path and `M_Out`; without it the output of the
data path is `M_Out`. `AesUnits_g` = 0
and `GhashDigit_g` = 0 select the defaults of the width (`aesDefaultUnits`, `ghashDefaultDigit` of `ocr_pkg`), and
the register file reports the values that the data path uses.

| Connection | From | To | Content |
| --- | --- | --- | --- |
| Job | `ocr_key_table` | `ocr_gcm` | Direction, key, hash subkey, IV, IV section flag, context error, slot |
| Hash subkey request | `ocr_key_table` | `ocr_gcm` (AES engine) | Key of a load; the result CIPH<sub>K</sub>(0<sup>128</sup>) goes back |
| Load, zeroize, busy | `ocr_mib` | `ocr_key_table` | Staged key and IV state, one-cycle zeroize, busy flag back |
| Query | `ocr_mib` | `ocr_key_table` | Slot; slot state back |
| Status events | `ocr_gcm` | `ocr_mib` | Code and direction of every status |
| ECC events | `ocr_gcm`, `ocr_key_table` | `ocr_mib` | Channels 0 to 10 (data path), 11 to 17 (key table) |
| Error injection | `ocr_mib` | `ocr_gcm`, `ocr_key_table` | Target, pattern, valid |
| Output messages | `ocr_gcm` | `ocr_packer` (`DenseOutput_g`) or `M_Out` | Sectioned output messages |

## 2. Clock, reset and start-up

All modules run in `Clk` and share the synchronous high-active reset `Rst`. After the reset the key table erases its
slots (STATUS.BUSY = '1'); contexts are accepted after the erasure, loads through the register file are accepted
when BUSY is '0'. The register file holds no key after the reset.

## 3. Generics

| Generic | Data path | Key table | Register file |
| --- | --- | --- | --- |
| `DataWidth_g` | width of the streams, defaults of units and digit | | GENERICS |
| `KeyBits_g` | AES engine | memories | GENERICS, staging registers |
| `NumKeys_g` | slot width of the jobs and the status | number of slots | GENERICS, range checks |
| `AesUnits_g`, `GhashDigit_g` | resolved values | | GENERICS, GENERICS2 (resolved values) |
| `LenBits_g` | byte counts | | GENERICS2 |
| `ReleaseBuffer_g`, `ReleaseBytes_g` | release buffer | | GENERICS, RELEASE_BYTES |
| `DenseOutput_g` | output packer | | GENERICS |
| `ClkFreqHz_g`, `ScrubPeriod_g` | | scrubbers | |
