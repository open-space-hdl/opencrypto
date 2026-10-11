# ocr_key_table: Architecture

## 1. Structure

```text
 S_Load ----> load state machine (KT-2) -----> write port --+---> key RAM  (valid, IV construction, key)
                 |    ^                                     +---> H RAM    (valid, H)
                 |    | H = CIPH_K(0^128)                   +---> IV RAM   (fixed field, invocation counter)
                 v    |                                     |       |   (olo_ft_ram_sdp_scrub, KT-1)
              M_Aux  S_Aux                                  |       | read port, one cycle
                                                            |       v
 S_Ctx -----> read arbiter (query first) --------------> read address --> resolution (KT-3, KT-4) --> job FIFO --> M_Job
 S_Query ---->      |                                                          |    |                (4 entries)
                    +-- job credits <------------------------------------------+    +--> counter + 1 (write port)
 Zeroize ---> erasure (KT-1) --> write port                                    +--> query response --> M_Query
```

| Memory | Word | Content |
| --- | --- | --- |
| Key RAM | `KeyBits_g` + 2 bits | Valid flag, IV construction ('1' generated IVs), key |
| H RAM | 129 bits | Valid flag, hash subkey |
| IV RAM | 96 bits | Fixed field (95:64), invocation counter (63:0) |

All three memories are `olo_ft_ram_sdp_scrub` with max(2, `NumKeys_g`) words; the valid flags are protected by the
SECDED code of their word, so a single event upset can neither activate an erased slot nor change its construction
unnoticed. The memories share one read address and read in the same cycle; each has its own write address.

## 2. Erasure (KT-1)

After the reset the table writes zeros to every word of the three memories, one word per clock cycle. The zeroize
command sets a pending flag; the erasure starts when no load and no context read is in progress, so that an
operation that started before the command cannot write into an erased slot. `Busy` is '1' from the command (or the
reset) to the end of the erasure and during every load. Contexts, loads and queries are not accepted during the
erasure. A zeroize during an erasure is followed by a second erasure.

## 3. Key load (KT-2)

| State | Action | Next |
| --- | --- | --- |
| `LdIdle_s` | Accept a load when no erasure is pending and no counter update uses the write port: write the key word (valid, construction, key), the IV word and an invalid H word, keep the key | `LdAux_s` (slot in range), `LdIdle_s` (slot out of range, ignored) |
| `LdAux_s` | Request CIPH<sub>K</sub>(0<sup>128</sup>) on `M_Aux` | `LdWait_s` when the request is taken |
| `LdWait_s` | Take the result on `S_Aux`, write the H word with its valid flag, clear the kept key | `LdIdle_s` |
| others | Recovery | `LdIdle_s` |

The slot is valid only when both valid flags are set, so a context of the slot between the two writes fails with KEY
and never uses the hash subkey of the previous key. The kept copy of the key is cleared as soon as the hash subkey
is written.

## 4. Context resolution and IV generation (KT-3, KT-4)

A read serves a query or a context; a query wins. A context is read only when a job credit is available: the credit
counter starts at the depth of the job FIFO (4), a read takes one, a job that leaves the FIFO returns one. The FIFO
therefore always has room for the job of a read and needs no back-pressure on the result path.

The result of a read is evaluated in the next cycle:

| Condition | Job error | Job IV |
| --- | --- | --- |
| Slot out of range, key or H word not valid | KEY | IV of the context |
| Generated IV, decryption or slot of external IVs | IV_MODE | IV of the context |
| Generated IV, counter = 2<sup>64</sup> - 1 | IV_EXHAUSTED | IV of the context |
| Generated IV, slot of generated IVs | OK | fixed field ‖ counter, IV section flag set |
| External IV, encryption on a slot of generated IVs | IV_MODE | IV of the context |
| External IV, otherwise | OK | IV of the context |
| Double error in one of the three words | ECC (wins) | as above |

A job with an error carries zeros instead of the key and the hash subkey. A slot number out of range reads address 0
and discards the result. A generated IV writes the counter + 1 back through the write port of the IV memory in the
same cycle; no read is issued in that cycle, so the next context of the same slot reads the updated counter. A
generated IV therefore takes two clock cycles, an external IV one (KT-PF-01).

The query response holds valid flag (both words valid and slot in range), construction, fixed field, counter, the
exhausted flag (counter = 2<sup>64</sup> - 1) and the double error flag of the read; it carries no key and no hash
subkey.

## 5. Fault tolerance

| Upset | Effect |
| --- | --- |
| Single error in a memory word | Corrected at the read and by the scrubber, ECC event |
| Double error in a memory word read by a context | Job with ECC, zero key and H; the counter is not written back |
| Double error read by a query | Double error flag in the response |
| Single or double error in the job FIFO | Corrected, or the job fails with ECC with zero key and H |
| Upset in a control register | Recovery state of the load state machine (`when others`); reset |

The error injection selects the key word (0), the H word (1) or the IV word (2) of the next load, or the next job
(3). The injection into a memory is held until the load and applied with its write: the H word with the write of the
hash subkey, the other words with the write at the start of the load. A scrubber write-back in between can therefore
not take the injection.

## 6. ECC events

| Index | Source |
| --- | --- |
| 0, 1, 2 | Read of the key, H and IV memory |
| 3, 4, 5 | Scrubber of the key, H and IV memory |
| 6 | Job FIFO (output of a job) |

## 7. Ports

| Port | Direction | Width | Description |
| --- | --- | --- | --- |
| `Clk`, `Rst` | in | 1 | Clock, synchronous high-active reset |
| `S_Ctx_*` | in | | Context: `Decrypt`, `Slot`, `IvGen`, `Iv` (96) with valid / ready |
| `M_Job_*` | out | | Job: `Decrypt`, `Key`, `H` (128), `Iv` (96), `IvOut`, `Err` (4), `Slot` with valid / ready |
| `S_Load_*` | in | | Load: `Slot`, `Key`, `IvGen`, `Fixed` (32), `Counter` (64) with valid / ready |
| `Zeroize` | in | 1 | Zeroize command (one cycle) |
| `Busy` | out | 1 | Erasure, zeroize or load in progress |
| `S_Query_*`, `M_Query_*` | in, out | | Query of a slot and its response (`KeyValid`, `IvGen`, `Exhausted`, `Fixed`, `Counter`, `Ded`) |
| `M_Aux_*`, `S_Aux_*` | out, in | | Hash subkey request (key) and result (block) |
| `Ecc_Sec`, `Ecc_Ded` | out | 7 | ECC events (section 6) |
| `ErrInj_*` | in | | Error injection: `Sel` (2), `BitFlip` (2: "01" single, "11" double error), `Valid` |
