# ocr_aes: Architecture

## 1. Structure

```text
              In_Key, In_Block, In_Tag
                      |
          +-----------v------------+
          | AddRoundKey round 0    |  StartSt  = In_Block xor w[0..3]
          | aesKeyFirst            |  StartWin = window of round 1
          +-----------+------------+
                      | Start(u) for the unit at the round-robin pointer
     +----------------+----------------+-----------------+
     v                v                v                 v
 +--------+       +--------+       +--------+       +--------+
 | unit 0 |       | unit 1 |  ...  | unit u |  ...  | unit   |   ocr_aes_unit: State, window, round, tag
 +---+----+       +---+----+       +---+----+       | U-1    |   one round per clock cycle
     |                |                |            +---+----+
     +----------------+--------+-------+----------------+
                               | Done(u): last round in this cycle (at most one unit)
                        +------v------+
                        | OR of the   |  output register: Out_Valid, Out_Block, Out_Tag
                        | results     |
                        +-------------+
```

## 2. Round unit (`ocr_aes_unit`)

| Register | Width | Content |
| --- | --- | --- |
| `Busy` | 1 | A block is in the unit |
| `Round` | 4 | Round that runs in this cycle, 1 to Nr |
| `State` | 128 | State before the round |
| `Win` | `KeyBits_g` | Window of the key expansion: its last four words are the round key of the round |
| `Tag` | `TagWidth_g` | Tag of the request |

In every cycle with `Busy` set the unit computes `aesRound(State, Win(127:0), Round = Nr)` and, independently, the
next window with `aesKeyStep(Win, KeyCtl(Round))`, where `KeyCtl` is the constant table of the step controls of the
key length. The data path and the key path are separate register-to-register paths; the round key of a round was
computed in the previous cycle. In the last round (`Done`) the unit offers its result and becomes free in the same
cycle, so a new block can start in the cycle of the last round: a unit is busy for exactly Nr cycles per block.

An illegal value of `Round` above Nr ends the block like the last round (recovery); the reset clears `Busy`.

## 3. Dispatch and results

The pointer selects the unit of the next request in round robin; `In_Ready` is set when that unit is idle or runs its
last round. With round robin and a fixed latency, the units are always used in the order of the requests, and at most
one unit finishes per cycle; the results leave in the order of the requests. The output register takes the OR of the
results of the units that finish (one at most).

Latency: a request accepted at clock edge t is in round 1 in the following cycle and in round Nr in the cycle that ends
at edge t + Nr; the output register holds the result after edge t + Nr, so the result is sampled at edge t + Nr + 1.

## 4. Resources

Per unit: 16 S-boxes of the round, 4 S-boxes of the key step, MixColumns, 128 + `KeyBits_g` + 5 + `TagWidth_g`
registers. The round-0 AddRoundKey and `aesKeyFirst` exist once in front of the units.
