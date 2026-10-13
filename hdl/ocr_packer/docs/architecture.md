# ocr_packer: Architecture

## 1. Structure

![Block diagram of ocr_packer: byte rotation of the input beat, residual register, merge into the output beat and
output register](img/ocr_packer_arch.drawio.svg)

The packer is one entity with the two-process pattern. It keeps the bytes of the current message that do not fill an
output beat yet in a residual register (`Res`, `ResCnt` bytes in lanes 0 to `ResCnt` - 1, `ResSec` the section of the
first of them) and has one output register.

## 2. Packing

For every input beat with k valid bytes (`Keep` contiguous from lane 0) the packer rotates the beat by `ResCnt`
lanes: input byte i goes to lane (i + `ResCnt`) mod B, B = `DataWidth_g` / 8. The lanes from `ResCnt` up hold the
input bytes behind the residual bytes; the lanes below `ResCnt` hold the input bytes that do not fit into the beat.
With T = `ResCnt` + k:

| Case | Output | New residual |
| --- | --- | --- |
| T ≥ B | Full beat: residual bytes in lanes 0 to `ResCnt` - 1, rotated input bytes above | T - B bytes: the rotated input bytes of lanes 0 to T - B - 1; section of the input beat |
| T < B, not the last beat | None | T bytes: residual bytes and rotated input bytes |
| T < B, last beat | Last beat with T bytes (none for a message without byte) | None |

When the last beat of a message gives T > B, the packer sends the full beat, keeps the T - B remaining bytes and
sends them as the last beat in the next cycle (flush); during the flush cycle the input is not ready (PA-PF-01). The
error flag of the last input beat goes to the output beat that carries `Last`.

One rotation serves both the merge and the new residual, so the logic is one B-way byte multiplexer per lane and a
byte counter; no byte enables are interpreted beyond their number.

## 3. Sections

The section code of an output beat is the section of its first byte (PA-FN-02): `ResSec` when residual bytes start
the beat, otherwise the section of the input beat. A consumer that needs the exact section boundaries uses the
section lengths of the message format: the IV section has 12 bytes, the TAG section 16 bytes, and the status reports
the AAD and DATA bytes.

## 4. Inputs outside the format

The output assembly of the core never sends them; the packer still behaves deterministically:

| Input | Behaviour |
| --- | --- |
| A beat without valid byte inside a message | Contributes no byte |
| A beat without valid byte as the last beat after bytes | The residual bytes leave as the last beat; when the bytes before filled whole beats, the last output beat carries no byte |
| Byte enables that are not contiguous (a double error in the release buffer can cause them) | The number of enabled bytes is packed from lane 0; the message carries the error flag of the release buffer |

## 5. Timing

Latency one clock cycle (output register). The input ready follows the output ready combinationally, as in an
Open Logic pipeline stage. The critical path is the byte counter of the input beat, the rotation by `ResCnt` and the
lane multiplexer: log2(B) + 1 levels of 2:1 byte multiplexers.
