# ocr_gcm: Architecture

## 1. Structure

```text
            job (key, H, IV, direction, error)      H, descriptor per message
 S_Job ---------------+                        +---------------------------------------------+
                      v                        |                                             |
 S_In  ---> ocr_gcm_input ---> data FIFO --> ocr_gcm_combine --> output FIFO --> ocr_gcm_output --> [release
            (IN-1, IN-2)     (32 entries)    (CT-1)      |                         (OU-1, OU-3)    buffer] --> M_Out
                  |                            ^   ^      +--> hash FIFO --> ocr_ghash --+    ^  |
                  | requests (keystream, J0)   |   |      |                  (GH-1)      v    |  +-> status FIFO ->M_Sts
                  v                            |   |      +--> summary FIFO -----> ocr_gcm_tag --> result FIFO
            ocr_gcm_keystream -- keystream FIFO+   |                                ^  (TG-1)
            (AES engine,     -- J0 FIFO -----------+--------------------------------+
             credits)        -- hash subkey register --> M_Aux
 S_Aux ---------^
```

All FIFOs are `olo_ft_fifo_sync` (SECDED); the release buffer is an `olo_ft_fifo_packet`.

| Buffer | Entry | Depth |
| --- | --- | --- |
| Data FIFO | Beat with section, beat index in its block and the flags of the input parser | 32 |
| Keystream FIFO | Keystream block | 32 |
| J0 FIFO | CIPH<sub>K</sub>(J0) of a message | 16 (W of 16 and 32 bits), 32 |
| Hash subkey FIFO, descriptor FIFO, summary FIFO, result FIFO | One entry per message | as the J0 FIFO |
| Output FIFO | Body beat (AAD, data) | 32 |
| Hash FIFO | AAD or ciphertext beat | 16 |
| Status FIFO | Status of a message | 16 |

## 2. Input parser (`ocr_gcm_input`)

The parser holds two jobs: the job of the current message and the next job, which arrives with its hash subkey into
the hash subkey FIFO and its descriptor (direction, IV section flag, IV, slot, context error) into the descriptor
FIFO. It holds one beat back: the successor of a beat shows whether the beat ends its section (other section or
`Last`), whether it is the last body beat (the successor is a TAG beat) and whether a partial beat lies inside a
section. A beat is processed when its successor is known.

For every beat the parser checks the format (GC-IN-02). A correct beat goes to the data FIFO with its flags:

| Flag | Meaning |
| --- | --- |
| `K` | Beat of a DATA beat within its block |
| `KsPop` | The keystream block is used up after this beat (last beat of a block or of the DATA section) |
| `SecLast`, `BodyLast`, `MsgLast` | Last beat of its section, of the body (AAD and data), of the message |
| `NoBody` | First TAG beat of a message without AAD and DATA beat |
| `FmtErr`, `Rej`, `Dec` | Format error, marker of a rejected message, direction |

The first beat of every non-empty DATA block issues the AES request of its counter block IV ‖ [i + 1]<sub>32</sub>; the
request and the beat are accepted in the same cycle. J0 of a message is requested in any cycle without keystream
request, at the latest before the first beat of the next message; J0 of the next job may be requested once J0 of the
current job is requested. A message with a format error is cut at the error: the rest of the message is dropped and
a marker entry (no byte, `MsgLast`, `FmtErr`, and `KsPop` when a keystream block of the cut block is pending) ends it.
A rejected message is dropped completely and replaced by one marker entry with `Rej`.

## 3. Keystream (`ocr_gcm_keystream`)

The AES engine has no back-pressure, so every destination has credits: the keystream FIFO and the J0 FIFO have a
credit counter each (their depth), the hash subkey result register one credit. A request is accepted only when its
destination has a credit; the credit returns when the result leaves the FIFO. Hash subkey requests of the key table
have priority. Separate FIFOs for keystream and J0 avoid head-of-line blocking: the tag stage takes J0 at the end of a
message, while the combiner needs the keystream of the following messages.

## 4. Combiner (`ocr_gcm_combine`)

One data FIFO entry per cycle. A DATA beat is XORed with lanes `K` · B to `K` · B + B - 1 of the keystream block at the
head of the keystream FIFO (B bytes per beat), which is popped with `KsPop`. Lanes without byte enable are zero. A
body beat goes to the output FIFO and to the hash FIFO (the ciphertext of a decryption is its input, of an encryption
its result); a TAG beat fills the received tag; an entry with `NoBody` adds an empty body beat. The last entry of a
message writes the summary (direction, rejection, format error, ECC error of the data and keystream FIFOs, received
tag).

## 5. Tag stage (`ocr_gcm_tag`)

When S, the summary and (unless rejected) J0 of a message are available, the stage computes T = S ⊕ J0, compares it
with the received tag of a decryption and merges the status code (D11). One message per cycle; the result goes to the
result FIFO.

## 6. Output assembly (`ocr_gcm_output`)

```text
            descriptor                 last body beat              last tag beat / verdict
 Idle_s ----------------> Iv_s -----> Body_s ---------> Tag_s (encryption) -----------> next message
   ^   IV section flag      | last IV   |   \--------> Final_s (decryption) ----------> next message
   |   (else Body_s)        +-----------+  rejected message: one empty beat ----------> next message
   +---------------------------------------- no descriptor --------------------------------+
```

The stage loads one beat per cycle into its output register. An encryption emits its body beats directly and then the
16 tag bytes (zeros on failure, D12). A decryption holds one body beat back, so that the last beat with bytes carries
`Last` and the verdict; a decryption without any byte emits one empty beat. The descriptor of the next message is
taken in the cycle of the last beat of the previous message, so consecutive messages leave without a gap. The status
travels with the last beat in the output register and enters the status FIFO when the beat leaves; with the release
buffer, a message whose status is not OK is dropped (`In_Drop` with the last beat), and a message that the buffer
dropped because of its size reports OVERFLOW. The `when others` branch of the state machine returns to `Idle_s`.

## 7. Throughput

At 128 bits a message of n data blocks needs n + 1 AES blocks (J0), A + n + 1 GHASH blocks (the length block) and
A + n + 1 output beats (the tag), so all three are balanced; the buffers between the stages absorb the latencies, and
the bottleneck side transfers a beat in every cycle after an initial latency (GC-PF-01). At smaller widths the default
numbers of AES units and the default GHASH digit leave room for the short and partial blocks of short messages
(architecture D4, D5).
