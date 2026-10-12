# ocr_ghash: Architecture

## 1. Structure

![Block diagram of ocr_ghash: block assembly, block queue, digit-serial multiplier, output register and the register of
the next hash subkey](img/ocr_ghash_arch.drawio.svg)

## 2. Block assembly

The assembly writes the bytes of each beat into the block register X at the position of beat K of the block
(`beatToBlock`), with the lanes without byte enable zero. A block is complete after R = 128 / `DataWidth_g` beats or
at the end of a section (zero padding); an empty section has no block. After the last beat of a message the assembly
pushes the length block in the next cycle (`LenPending`), during which it does not take a beat. The byte counts of the
AAD and of the ciphertext saturate at 2<sup>`LenBits_g`</sup> - 1 and set the length error.

A queue entry holds X, the flags "first block of the message" and "length block", and the length and ECC errors of
the message; the byte counts of the result are taken from the length block. The queue is an `olo_base_pl_stage` of
one stage for a 128-bit digit and of three stages otherwise: a multiplier that needs several cycles per block falls
behind on the short blocks of short sections and catches up in its idle cycles of long sections; three stages give it
room for that (GH-PF-01).

## 3. Multiplier

For every block the multiplier runs s = 128 / `Digit_g` steps. Step k takes the digit k (from the rightmost bits of
the block) of A = Y ⊕ X (A = X for the first block of a message, GCM 6.4 step 2) and computes
Z := Z · u<sup>D</sup> + digit · H (`gfMulDigit`, Z = 0 in step 0). After the last step Y := Z; Y stays the result of
the previous block during the steps, so the next block starts in the following cycle without a gap. The hash subkey
of a message is loaded into H with the first block; the register of the next hash subkey is refilled in the same
cycle. The result of the length block is S; the multiplier waits when the output register still holds the S of the
previous message.

## 4. Timing

| Digit | Cycles per block | Use (architecture D5) |
| --- | --- | --- |
| 128 | 1 | Default for 64 and 128 bits |
| 64 | 2 | Default for 16 and 32 bits |
| 32 | 4 | Smaller multiplier, full rate for long messages at 16 and 32 bits |
| 16 | 8 | Smallest multiplier at 16 bits |

The critical path is the digit multiplication with the reduction (an XOR tree over up to 128 · D / 128 products per
result bit) plus the XOR of Y and X on the digit.
