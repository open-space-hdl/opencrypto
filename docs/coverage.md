# OpenCrypto: Code Coverage

## 1. Method

The code coverage of the OpenCrypto sources is measured with QuestaSim (Questa Sim Microchip Edition 2024.3) over the
complete regression of `run.py`, the same test set that GHDL runs in CI:

```shell
python run.py --questa --coverage -p 1
```

The sources of `hdl/<module>/src` are compiled with `+cover=sbcef`: statements, branches, conditions, expressions
(focused expression coverage) and state machines. Open Logic, UVVM and the testbenches are not instrumented; Open Logic
is verified by its own regression. `run.py` merges the coverage of all tests into `coverage/coverage.ucdb` and writes
the reports `coverage/coverage_report.txt` (details per instance) and `coverage/coverage_byfile.txt`; a design unit
is covered when any of its instances in any test covers it.

Closure rules:

- Statements, branches, state machine states and transitions: every item is covered by a test or listed with its
  justification in section 4.
- Conditions and expressions: every miss is reviewed for untested behaviour (section 3); a remaining miss is listed
  with its justification in section 4.
- `-- coverage off` / `-- coverage on` are used for one kind of code only: the `when others` branch of a state machine
  whose enumerated state type lists every state (`ocr_gcm_output`, `ocr_key_table`, `ocr_framer`). The branch is the
  recovery path of an illegal state (architecture D13) and cannot be reached in simulation.

## 2. Result

Run on 2026-10-13: 348 tests (76 test cases in their configurations), all passed, 67 minutes; the framer tests ran
once more after the extension of TC-FR-02 (section 3) and their coverage is merged into the result. Numbers are
covered/total bins per file; bold marks a metric with misses. The register package contains no statements of its
own; the statements of `ocr_core.vhd` are the connections of the sectioned and the dense output. The throughput
test cases TC-CO-14 to TC-CO-16 and TC-FR-08, added on 2026-10-14, measure clock cycles of existing paths and change
no RTL; the result stays the coverage of the sources.

| File | Statements | Branches | FSM States | FSM Transitions | Conditions | Expressions |
| --- | --- | --- | --- | --- | --- | --- |
| `ocr_aes/src/ocr_aes_engine.vhd` | 31/31 | 13/13 |  |  | 4/4 | 2/2 |
| `ocr_aes/src/ocr_aes_unit.vhd` | 23/23 | 10/10 |  |  |  | 2/2 |
| `ocr_core/src/ocr_core.vhd` | 6/6 |  |  |  |  |  |
| `ocr_framer/src/ocr_framer.vhd` | 77/77 | 44/44 | 3/3 | **4/5** | **15/16** | **14/19** |
| `ocr_gcm/src/ocr_gcm.vhd` | 66/66 | 14/14 |  |  | 2/2 | **47/68** |
| `ocr_gcm/src/ocr_gcm_combine.vhd` | **63/64** | **28/29** |  |  | **10/12** | 9/9 |
| `ocr_gcm/src/ocr_gcm_input.vhd` | 145/145 | 97/97 |  |  | **60/62** | **23/24** |
| `ocr_gcm/src/ocr_gcm_keystream.vhd` | 43/43 | 28/28 |  |  | 8/8 | 5/5 |
| `ocr_gcm/src/ocr_gcm_output.vhd` | 102/102 | 68/68 | 5/5 | **13/14** | 16/16 | 6/6 |
| `ocr_gcm/src/ocr_gcm_pkg.vhd` | 47/47 |  |  |  |  |  |
| `ocr_gcm/src/ocr_gcm_tag.vhd` | 29/29 | 21/21 |  |  | 7/7 | 6/6 |
| `ocr_ghash/src/ocr_ghash.vhd` | 104/104 | 55/55 |  |  | 19/19 | 6/6 |
| `ocr_key_table/src/ocr_key_table.vhd` | 155/155 | 68/68 | 3/3 | 4/4 | 31/31 | 13/13 |
| `ocr_mib/src/ocr_mib.vhd` | **172/173** | **97/98** |  |  | 14/14 | 3/3 |
| `ocr_packer/src/ocr_packer.vhd` | 67/67 | 27/27 |  |  | 2/2 | 2/2 |
| `ocr_pkg/src/ocr_pkg.vhd` | 144/144 | 37/37 |  |  | 4/4 | 11/11 |
| Total | 1274/1276 (99.8 %) | 607/609 (99.7 %) | 11/11 (100.0 %) | 21/23 (91.3 %) | 192/197 (97.5 %) | 149/176 (84.7 %) |

All but two statements, all but two branches, every state and all but two transitions are covered. The misses are
listed in section 4: the end of a message at a full summary FIFO, the saturation of a 32-bit counter, the reset in
two short states, and condition and expression terms that the structure of the data path and of the framer
excludes.

## 3. Gaps found and closed

The first complete run showed behaviour that no test exercised and conditions that could not be false in their
context. Each gap was closed by a new or an extended test, or by the equivalent shorter condition. One defect of the
design was found on the way.

| Gap | Resolution |
| --- | --- |
| Key table: a query accepted in the cycle after another query was not answered; the pulse of the first response cleared the pulse of the second (defect) | The response pulse is cleared before it is set. TC-KT-02 sends queries in consecutive cycles and counts the answers; the previous logic answers 6 of 11 |
| Key table: a load requested during an erasure, a zeroize during a load and during context reads, a reset right after a load is accepted, an injection requested during a load, a double error in the job of a generated IV | TC-KT-05, TC-KT-07 and TC-KT-10 extended |
| Data path: the buffers inside the data path never filled; the hash subkey result was always taken at once; an IV section never followed a rejected message or a decryption directly; no rejected job carried the IV section flag | New TC-GC-15 (200 one-beat encryptions, 200 short messages of every kind, then a sink and a status sink that are rarely ready); TC-GC-11 and TC-GC-09 extended |
| Data path: four conditions could not be false in their context: the J0 request of the next job (implied by the branch before it), the check of an empty beat (implied by the check of a partial beat), the format error register of the combiner (a format error always arrives with the last entry of its message) and the drop condition of the release buffer (the error flag is set on the last beat only) | Replaced by the equivalent shorter conditions; the format error register was removed |
| Register file: only one counter was cleared by a write; status codes 9 to 15, KEY_LOAD without START and a start during a running load were never applied | TC-MG-05 and TC-MG-02 extended |
| Package: the precedence of OVERFLOW was checked with constant arguments only, which the simulator evaluates at compile time | TC-PK-09 merges every pair of codes at run time |
| ECC events with stall cycles at the outputs: an error must be counted once while its entry waits | TC-CO-07 runs with 50 % stall cycles at the outputs and checks the exact counts. QuestaSim then showed a lost double error in the output assembly: a procedure of its combinational process read the error flag directly, and QuestaSim does not include such a signal in the sensitivity list of `process (all)`. The flag is a parameter now; the rule is part of the [conventions](conventions.md) |
| Framer: the limit of the contexts owed to the core was never reached; a context receiver that is slow but takes contexts never lets them pile up | TC-FR-02 holds the context receiver for 3000 cycles: the framer stops taking chunks at its limit, delivers the chunks it holds and resumes when the contexts are taken |

## 4. Remaining misses

| Location | Item not covered | Justification |
| --- | --- | --- |
| `ocr_gcm/src/ocr_gcm_combine.vhd:170` | Branch, statement and both condition terms: the last entry of a message at a full summary FIFO | A summary exists for a message that the input parser accepted and the tag stage has not taken yet. The hash subkey FIFO, which has the same depth and holds one entry per accepted message not yet started in GHASH, stops the input parser first: the summary FIFO is full at the end of a message only when exactly one message is in GHASH, all others wait in the hash FIFO and the input parser holds no further job. TC-GC-15 runs 200 one-beat encryptions in the minimum configuration, where GHASH is the slowest stage and the hash subkey FIFO fills; this exact alignment did not occur. The guard keeps the summary FIFO from overflowing |
| `ocr_mib/src/ocr_mib.vhd:172` | Branch and statement: saturation of a message counter | A counter saturates after 2<sup>32</sup> - 1 messages, which no simulation reaches. The function is a comparison with all ones and is the same for all ten counters |
| `ocr_gcm/src/ocr_gcm_output.vhd:369` | Transition `Iv_s -> Idle_s` | The transition is the reset in the state `Iv_s`, which holds only the 1 to 6 beats of an IV section. The synchronous reset sets `Idle_s` from any state without a condition on the state; TC-GC-12 resets the data path while messages are in it and checks every following message |
| `ocr_gcm/src/ocr_gcm_input.vhd:395, 408, 410` | Condition and expression term: hash subkey FIFO full while the descriptor FIFO accepts | Both FIFOs are written together and have the same depth; the hash subkey FIFO is read when GHASH starts a message, the descriptor FIFO when the output starts it. The descriptor FIFO fills first under back-pressure (TC-GC-15); the hash subkey FIFO can hold one entry more only while the output is one message ahead of GHASH, which requires GHASH to be idle. The term keeps the hash subkey FIFO from overflowing |
| `ocr_gcm/src/ocr_gcm.vhd:730 to 751` | 16 expression terms `Valid` = '0' and 5 terms `Ready` = '0' of the ECC event qualification | An ECC event is counted when an entry with an error leaves its FIFO (flag, valid and ready). The flags of an FT FIFO decode the output word also while the FIFO is empty; the regression never leaves an erroneous word at the output of an empty FIFO, because an injected error is written into the next entry and leaves with it. The exact counts of TC-GC-10 and TC-CO-07 (with stall cycles at the outputs) show that every error is counted exactly once |
| `ocr_framer/src/ocr_framer.vhd:435 to 438` | 4 expression terms `Valid` = '0' of the ECC event qualification | As for the data path: the injected error is written into the next entry and leaves with it, never at the output of an empty FIFO. The exact counts of TC-FR-04 show that every error is counted exactly once |
| `ocr_framer/src/ocr_framer.vhd:215, 223` | Condition and expression term: position FIFO full | The position FIFO holds one entry per complete chunk whose output has not started and has room for at least 4 · `BufferChunks_g` entries, the maximum number of chunks in the chunk buffer. It can only fill when the chunk buffer holds that maximum, and then the chunk buffer does not take a further chunk either; this alignment did not occur in the regression, not even with the context receiver held in TC-FR-02. The term keeps the position FIFO from overflowing |
| `ocr_framer/src/ocr_framer.vhd:353` | Transition `Aad_s -> Idle_s` | The transition is the reset in the state `Aad_s`, which holds only the one or two AAD beats of a chunk. The synchronous reset sets `Idle_s` from any state without a condition on the state; TC-FR-05 resets the framer while chunks are in it and checks every following chunk |

## 5. Reproduction

```shell
python run.py --questa --coverage -p 1
vcover report -du=* -details -zeros coverage/coverage.ucdb
```

The second command lists the items that are not covered, per design unit.
