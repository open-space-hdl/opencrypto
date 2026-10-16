# OpenCrypto Conventions

OpenCrypto follows the coding conventions of Open Logic and the module development process of the architecture
document. This page lists the rules and the few OpenCrypto-specific additions.

## VHDL coding

- The [Open Logic coding conventions](../open-logic/doc/Conventions.md) apply in full: port names
  `<Interface>_<Signal>`, generics `_g`, constants `_c`, variables `_v`, types `_t`, FSM types `<Name>Fsm_t` with
  states `_s`, functions in `lowerCamelCase`, four spaces of indentation, no tabs, no trailing whitespace.
- Entities are named `ocr_<function>` (for example `ocr_key_table`). All OpenCrypto sources are compiled into the VHDL
  library `opencrypto`; Open Logic is compiled into the library `olo`.
- Language: VHDL-2008.
- Entities with non-trivial state use the two-process pattern of Open Logic: all registers in one `TwoProcess_r`
  record, signals `r` and `r_next`, a combinational process starting with `v := r;` and ending with
  `r_next <= v;`, a sequential process with `r <= r_next;` and the reset override at its end.
- A subprogram declared in a combinational process (`process (all)`) reads signals only through its parameters.
  Simulators differ in whether a signal that only such a subprogram reads is part of the sensitivity list; the
  process then misses its changes in one simulator and not in the other.
- A loop does not update the elements of one vector variable in place over many iterations
  (`T_v(i + j) := T_v(i + j) xor ...`): an elaborator follows the chain of partial updates recursively and can
  exhaust its stack (Vivado 2025.2 did so with 16384 updates). Each element is summed in a scalar and written
  once.
- Resets are synchronous and high-active. Only state registers are reset. The core has one clock domain `Clk`.
- Every data path between blocks is a valid / ready stream (AXI4-Stream handshake semantics) or a valid-only stream
  of one-cycle events where the receiver is never slower than the source.
- Message streams carry the first byte of a section in byte lane 0 (`TData(7:0)`). All bytes of a beat are valid
  except in the last beat of a section, whose valid bytes are contiguous from lane 0 (`TKeep`).
- A 128-bit block is a `std_logic_vector(127 downto 0)` whose first byte (the leftmost byte of the string of the
  standards) is in bits 127 downto 120, so that the hexadecimal examples of the standards read as VHDL literals. The
  bit string x<sub>0</sub> ... x<sub>127</sub> of GCM 6.3 is the same vector seen with an ascending range.
- Standard functions (FIFOs, RAMs, crossings, synchronisers, arbiters, pipeline stages) are instantiated from Open
  Logic, never rewritten. FIFOs, RAMs and crossings use the fault-tolerant `olo_ft_*` entities.
- State machines have a `when others` branch that returns to a defined recovery state; the reset leads to that state
  from any state.
- Every line that implements a requirement of the standards is traceable through the module specification; comments
  name the clause where it helps the reader (for example `-- AES 5.2` or `-- GCM 7.2 step 8`).
- File header: copyright line and authors, then a 1 to 2 sentence description that links to the module
  documentation. Never write "all rights reserved".
- Never use em-dashes in code, comments or documentation. Use UTF-8 only.
- VSG 3.27 with the Open Logic configuration in `lint/config` must report no errors and no warnings:
  `python lint/lint.py`. Safe automatic fixes: `python lint/lint.py --fix`.
- The design must be synthesizable in a technology-independent way: `python lint/synth_check.py` elaborates
  `ocr_core` with the synthesis of GHDL (after `python run.py --compile`) and fails on errors and inferred latches.
  `to_01` and other simulation-only functions are not used in RTL.
- `compile_order.txt` lists the synthesis sources in compile order. After adding, removing or renaming a source or
  changing the dependencies between sources, regenerate it with `python run.py --compile-order`; the CI fails when it
  is not current.
- Traceability: every requirement of a specification is verified by at least one test case of the verification plan,
  every clause of the traceability matrix (architecture section 10) by the test cases of its requirements, and
  every test case of a plan is run by a testbench. `python tools/compliance.py` writes the
  [compliance matrix](compliance.md); `python tools/compliance.py --check` fails on a gap.

## Module development process

Every module goes through the seven phases of the architecture document (section 9):

| Phase | Output |
| --- | --- |
| A Requirements | `hdl/<module>/docs/specification.md`: requirements with IDs, each tracing to clauses of the standards |
| B Architecture | `hdl/<module>/docs/architecture.md`: blocks, ports, state machines, data formats |
| C Verification plan | `hdl/<module>/docs/verification_plan.md`: test cases with IDs, requirement coverage |
| D RTL | `hdl/<module>/src/*.vhd` |
| E Testbenches | `hdl/<module>/tb/<entity>_th.vhd` (harness) and `<entity>_tb.vhd` (VUnit runner) |
| F Verification | Regression green, `hdl/<module>/docs/verification_report.md` |
| G Integration | Tests at the next level that cross every seam the module touches |

A module is one group of blocks of the architecture (section 7). `hdl/<module>/README.md` links the four documents
and explains how to run the tests.

Requirement IDs have the form `<GROUP>-<AREA>-<NN>`, for example `GC-IN-02`. The last column of a requirement table
names the clauses with their standard (`AES 5.1.3`, `GCM 6.4`, `CCSDS 3.4.2`) or `none`.

## Diagrams

- Every architecture document has a block diagram; state machines and data formats have one where text alone is
  hard to follow.
- Diagrams are draw.io drawings stored as editable SVG with the drawing embedded (`<name>.drawio.svg`) in the `img/`
  folder next to the document. The SVG is the source: open it in draw.io to change it. It is exported with the light
  theme on an opaque white background, so that it reads in both colour schemes of the documentation site.
- Blocks: light blue for OpenCrypto logic, white with a blue outline for an OpenCrypto entity instantiated as a
  whole, light grey for an Open Logic entity, drawn inside the block that instantiates it or, for a FIFO between two
  blocks, as a small box on the connection. A dashed outline groups the blocks of one entity instance; a dashed box
  is present for one value of a generic only (the release buffer); a stacked block is replicated (the round units of
  the AES engine). The title carries the building block ID of the architecture (`CT-1 Combiner`), the entity follows
  in grey.
- Connections: thick lines for streams and buses, thin lines for single signals. Every line is horizontal or
  vertical; a dot marks a branch, an arc marks a line that crosses another without a connection. Ports cross the
  frame of the entity, inputs on the left, outputs on the right where the layout allows.
- A diagram is at most about 1000 px wide, so that its text stays readable in the content column, and its alt text
  names the blocks it shows.

## Verification

- VUnit runs every test (`run.py`); UVVM supplies VVCs, BFMs, checks, randomisation and functional coverage.
- The harness (`_th`) contains clocks, reset, the DUT and the VVCs, the testbench (`_tb`) contains one
  `if run("<test id>") then` block per test case of the verification plan. The test IDs of the plan and the names
  in `run(...)` are identical.
- A test passes only when UVVM reports no unexpected alerts and every expected alert occurred
  (`ocr_tb_pkg.ocrTestEnd`).
- Tests observe ports and management interfaces only, never internal signals.
- GHDL is the default simulator; QuestaSim (`python run.py --questa`) is used for code coverage
  ([coverage.md](coverage.md)). Every test passes in both simulators.
- Every GHDL simulation gets its own copy of the option `ghdl.sim_flags`: VUnit 5.0.0.dev7 appends the generics of a
  test to the list of that option in place, so without the copy a test inherits the generics of earlier tests.
  `run.py` makes the copy and stops the run when a GHDL command does not carry exactly the generics of its
  configuration.
- Generic ranges are verified, not only declared: every value of a generic that changes the structure (widths, key
  lengths, numbers of units, booleans) runs in the regression, and the bounds of every numeric range are elaborated
  and synthesised (`python lint/synth_check.py`). A value outside the declared range stops the elaboration (range
  constraint or assertion). The verification report of every module lists the declared range, the simulated and
  the synthesised values of its generics. A testbench clock follows a frequency generic of the design.
- A side effect is never obtained by calling an impure function and discarding its result: QuestaSim may remove such
  a call. Protected types offer a procedure for it.
- A random value is drawn into a variable before it is used in the actual of an unconstrained array parameter
  (`Len_v := Rand_v.rand(1, 300); octet(..., tbPayload(Len_v, Seed_v))`): QuestaSim does not evaluate an impure call
  inside such an actual exactly once, so the stimulus and the expected message would differ.
- Expected values come from pycryptodome: `tools/ocr_vectors.py` writes the messages of every test configuration with
  their expected output when `run.py` starts; the examples of FIPS 197 and of the GCM specification are part of the
  vector sets. Tests never use the RTL of the core, or functions of `ocr_pkg` that the RTL uses, to compute expected
  values.
- Negative tests inject the fault from the bench (modified tag, AAD or ciphertext, wrong section order or byte
  enables, unloaded key slot, wrong IV source, exhausted invocation counter, oversized section, double error through
  the `ErrInj` ports) and expect the status code, the counter or the flag.

## Git

- `main` holds the integrated state. Every module or change is developed on a branch `feature/<module>` or
  `bugfix/<topic>` and merged with `--no-ff` once its regression is green.
- Commit messages: imperative subject line, body explains what and why.
