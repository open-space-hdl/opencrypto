# ocr_key_table: Specification

## 1. Overview

`ocr_key_table` holds the key material of OpenCrypto (KT-1 to KT-4): the key, the hash subkey and the IV state of
`NumKeys_g` key slots. It erases every slot after the reset and on zeroize, loads a slot and computes its hash subkey
with the AES engine of the data path, resolves the context of every message into a job for the GCM data path, and
generates the IVs of the slots that use the deterministic construction of NIST SP 800-38D 8.2.1. Keys and hash
subkeys have no read path.

## 2. Requirements

### 2.1 Interfaces

| ID | Requirement | Clauses |
| --- | --- | --- |
| KT-IF-01 | The table shall take one context per message (direction, key slot, IV source, IV) and output one job per context in the order of the contexts (direction, key, hash subkey, IV, IV section flag, context error, key slot). | GCM 5.2.1.1 |
| KT-IF-02 | A key load shall take the slot, the key, the IV construction ('1' generated IVs), the fixed field and the first invocation counter; a load of a slot out of range shall be accepted and ignored. | GCM 8.2 |
| KT-IF-03 | A slot query shall return the valid flag, the IV construction, the exhausted flag, the fixed field, the invocation counter and the double error flag of the slot, and never the key or the hash subkey; queries may follow each other in consecutive cycles, and every accepted query shall be answered. | GCM 5.1, 9.1 |
| KT-IF-04 | The hash subkey of a load shall be requested on the hash subkey port with the key of the load and written into the slot with the result. | GCM 7.1 |
| KT-IF-05 | The reset shall abort any load and erase every slot. | none (D7, D13) |

### 2.2 Key memories and key load (KT-1, KT-2)

| ID | Requirement | Clauses |
| --- | --- | --- |
| KT-MEM-01 | Key, hash subkey and IV state shall be held in scrubbed SECDED memories, with the valid flags inside the protected words. | GCM 5.3 |
| KT-MEM-02 | After the reset and on zeroize every slot shall be erased (key, hash subkey, IV state and valid flags) within `NumKeys_g` + 3 clock cycles; `Busy` shall be '1' while an erasure or a load is in progress, and contexts, loads and queries shall wait for the end of the erasure; a zeroize during a load or a context read shall take effect after it. | GCM 5.1 |
| KT-LD-01 | A load shall write key, IV construction, fixed field and invocation counter and invalidate the slot; the slot shall become valid when its hash subkey H = CIPH<sub>K</sub>(0<sup>128</sup>) is written. Every key of `KeyBits_g` bits shall be accepted. | GCM 7.1, 7.2; AES 6.2 |
| KT-LD-02 | A load shall not disturb the resolution of the contexts of the other slots. | none (D7) |

### 2.3 Context resolution and IV generation (KT-3, KT-4)

| ID | Requirement | Clauses |
| --- | --- | --- |
| KT-RS-01 | A context of a slot out of range or of a slot that is not valid shall produce a job with the error KEY; every job with an error shall carry a key and a hash subkey of zeros. | GCM 5.1 |
| KT-RS-02 | A context shall produce a job with the error IV_MODE when it requests a generated IV for a decryption or for a slot of external IVs, or when it encrypts with an external IV on a slot of generated IVs. | GCM 8.2 |
| KT-IV-01 | A context that requests a generated IV on a valid slot of generated IVs shall produce a job with IV = fixed field ‖ invocation counter and the IV section flag, and the invocation counter of the slot shall be incremented. | GCM 8, 8.2.1 |
| KT-IV-02 | When the invocation counter of a slot has the value 2<sup>64</sup> - 1, a context that requests a generated IV shall produce a job with the error IV_EXHAUSTED and the counter shall not change; the query shall report the slot as exhausted. | GCM 8.3 |
| KT-IV-03 | The query shall return the current invocation counter of a slot, so that the user can save it and load the slot with it after a loss of power. | GCM 9.1 |

### 2.4 Performance and fault tolerance

| ID | Requirement | Clauses |
| --- | --- | --- |
| KT-PF-01 | While jobs are taken, the table shall resolve one context per clock cycle with external IVs and one context per two clock cycles with generated IVs. | none (D3) |
| KT-FT-01 | A single error in a memory or in the job FIFO shall be corrected with an ECC event; a double error shall produce the error ECC in the job (with key and hash subkey of zeros) or the double error flag in the query, with an ECC event; the scrubbers shall correct single errors of slots that no context reads; every memory and the job FIFO shall take an error injection. | none (P5) |

## 3. Interpretation of the standard

- GCM 8.2.1 leaves the layout of the fixed field and the invocation field to the implementation. The table uses a
  32-bit fixed field and a 64-bit invocation counter (the layout that GCM 8.2.1 names as an example); the user assigns
  a distinct fixed field to every device that uses the same key.
- GCM 8.3 limits the number of invocations with one key. With the deterministic construction the invocation field
  limits it: the counter runs from its loaded value to 2<sup>64</sup> - 2, and the value 2<sup>64</sup> - 1 marks the
  slot as exhausted.
- GCM 9.1 requires that the invocation field does not repeat after a loss of power. The table cannot keep state over
  a power cycle; the user saves the counter from the query and loads the slot with a counter beyond every value that
  was used.
- Keys are never read back (GCM 5.1): the query returns the slot state only, and every job with an error carries
  zeros instead of the key and the hash subkey.

## 4. Configuration parameters

| Generic | Default | Range | Description |
| --- | --- | --- | --- |
| `KeyBits_g` | 256 | 128, 192, 256 | Key length |
| `NumKeys_g` | 4 | 1 to 256 | Number of key slots; the slot number has max(1, ceil(log2(`NumKeys_g`))) bits |
| `ClkFreqHz_g` | 100.0e6 | ≥ 1000 | Clock frequency, sizes the pacer of the scrubbers |
| `ScrubPeriod_g` | 0.0 | ≥ 0 | 0: the scrubbers run in every clock cycle without access to their memory; > 0: one pass over all slots every `ScrubPeriod_g` seconds (1 ms granularity) |
