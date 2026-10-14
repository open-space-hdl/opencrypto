# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Test vectors of OpenCrypto, computed with pycryptodome.

The testbenches read the vector files that this module writes when run.py starts (the module configurations
hdl/<module>/tb/vunit_config.py call the set functions below). Expected values come from the AES and GCM
implementations of pycryptodome and from the examples of FIPS 197 and of the GCM specification; the self test checks
that pycryptodome reproduces these examples.

Vector file format (one record per line, hexadecimal strings without prefix, '-' for an empty string):

  ECB <key> <input block> <output block>                 AES forward cipher (AES engine)
  KEY <slot> <key> <h> <ivgen 0|1> <fixed> <counter>     key slot: key, hash subkey, IV construction and state
  MSG <dec 0|1> <slot> <ivgen 0|1> <iv> <flags>         context of a message (flags: hex, bench options)
  IN  <section> <bytes>                                  input section, in order (section: I, A, D or T)
  OUT <section> <bytes>                                  expected output section, in order; 'OUT X -' = content
                                                         not checked, only the end of the message and its flag
  GH  <s>                                                expected GHASH result S of the message (GHASH bench)
  STS <code> <aad bytes> <data bytes> <iv>               expected status of the message
  END                                                    end of the message

Usage: python tools/ocr_vectors.py --selftest
"""

import argparse
import random
import sys
from pathlib import Path

from Crypto.Cipher import AES

# Status codes (docs/architecture.md, section 6)
OK, AUTH, FORMAT, KEY, IV_MODE, IV_EXHAUSTED, LENGTH, ECC, OVERFLOW = range(9)

# Bench options of a message (MSG flags)
FLAG_ERRINJ_SEC = 0x1   # inject a single bit error into a buffer while the message passes
FLAG_ERRINJ_DED = 0x2   # inject a double bit error
FLAG_ABORT = 0x4        # the source stops the message (reset tests)
FLAG_IMG_END = 0x40     # framer benches: the message is the last chunk of its input packet (TLast on its last beat)

# Chunk positions of the framer (CCSDS sequence flag encoding), bits 7:6 of the first AAD byte
POS_MIDDLE, POS_FIRST, POS_LAST, POS_SINGLE = 0, 1, 2, 3

# FIPS 197 Appendix C: (key, plaintext, ciphertext); Appendix B: cipher example
FIPS197_ECB = [
    ("2b7e151628aed2a6abf7158809cf4f3c", "3243f6a8885a308d313198a2e0370734", "3925841d02dc09fbdc118597196a0b32"),
    ("000102030405060708090a0b0c0d0e0f", "00112233445566778899aabbccddeeff", "69c4e0d86a7b0430d8cdb78070b4c55a"),
    ("000102030405060708090a0b0c0d0e0f1011121314151617", "00112233445566778899aabbccddeeff",
     "dda97ca4864cdfe06eaf70a0ec0d7191"),
    ("000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f", "00112233445566778899aabbccddeeff",
     "8ea2b7ca516745bfeafc49904b496089"),
]

# Test cases of the GCM specification (McGrew, Viega) with 96-bit IVs: name, key, iv, plaintext, aad, ciphertext, tag
_P64 = ("d9313225f88406e5a55909c5aff5269a86a7a9531534f7da2e4c303d8a318a72"
        "1c3c0c95956809532fcf0e2449a6b525b16aedf5aa0de657ba637b391aafd255")
_A20 = "feedfacedeadbeeffeedfacedeadbeefabaddad2"
_K = "feffe9928665731c6d6a8f9467308308"
_IV = "cafebabefacedbaddecaf888"
GCM_SPEC = [
    ("tc1", "00" * 16, "00" * 12, "", "", "", "58e2fccefa7e3061367f1d57a4e7455a"),
    ("tc2", "00" * 16, "00" * 12, "00" * 16, "", "0388dace60b6a392f328c2b971b2fe78", "ab6e47d42cec13bdf53a67b21257bddf"),
    ("tc3", _K, _IV, _P64, "",
     "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e"
     "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091473f5985", "4d5c2af327cd64a62cf35abd2ba6fab4"),
    ("tc4", _K, _IV, _P64[:120], _A20,
     "42831ec2217774244b7221b784d0d49ce3aa212f2c02a4e035c17e2329aca12e"
     "21d514b25466931c7d8f6a5aac84aa051ba30b396a0aac973d58e091", "5bc94fbc3221a5db94fae95ae7121a47"),
    ("tc7", "00" * 24, "00" * 12, "", "", "", "cd33b28ac773f74ba00ed1f312572435"),
    ("tc8", "00" * 24, "00" * 12, "00" * 16, "", "98e7247c07f0fe411c267e4384b0f600", "2ff58d80033927ab8ef4d4587514f0fb"),
    ("tc9", _K + _K[:16], _IV, _P64, "",
     "3980ca0b3c00e841eb06fac4872a2757859e1ceaa6efd984628593b40ca1e19c"
     "7d773d00c144c525ac619d18c84a3f4718e2448b2fe324d9ccda2710acade256", "9924a7c8587336bfb118024db8674a14"),
    ("tc10", _K + _K[:16], _IV, _P64[:120], _A20,
     "3980ca0b3c00e841eb06fac4872a2757859e1ceaa6efd984628593b40ca1e19c"
     "7d773d00c144c525ac619d18c84a3f4718e2448b2fe324d9ccda2710", "2519498e80f1478f37ba55bd6d27618c"),
    ("tc13", "00" * 32, "00" * 12, "", "", "", "530f8afbc74536b9a963b4f1c4cb738b"),
    ("tc14", "00" * 32, "00" * 12, "00" * 16, "", "cea7403d4d606b6e074ec5d3baf39d18", "d0d1c8a799996bf0265b98b5d48ab919"),
    ("tc15", _K + _K, _IV, _P64, "",
     "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa"
     "8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662898015ad", "b094dac5d93471bdec1a502270e3cc6c"),
    ("tc16", _K + _K, _IV, _P64[:120], _A20,
     "522dc1f099567d07f47f37a32a84427d643a8cdcbfe5c0c97598a2bd2555d1aa"
     "8cb08e48590dbb3da7b08b1056828838c5f61e6393ba7a0abcc9f662", "76fc6ece0f4e1768cddf8853bb2d551b"),
]


def hx(data):
    return data.hex() if data else "-"


# ---------------------------------------------------------------------------------------------------
# Reference functions (pycryptodome)
# ---------------------------------------------------------------------------------------------------
def aes_ecb(key, block):
    return AES.new(key, AES.MODE_ECB).encrypt(block)


def hash_subkey(key):
    return aes_ecb(key, bytes(16))


def j0(iv):
    return iv + b"\x00\x00\x00\x01"


def gcm_encrypt(key, iv, aad, plaintext):
    cipher = AES.new(key, AES.MODE_GCM, nonce=iv, mac_len=16)
    cipher.update(aad)
    return cipher.encrypt_and_digest(plaintext)


def gcm_decrypt(key, iv, aad, ciphertext, tag):
    """Plaintext of the counter mode (also for a wrong tag) and the verdict of the tag."""
    cipher = AES.new(key, AES.MODE_GCM, nonce=iv, mac_len=16)
    cipher.update(aad)
    plaintext = cipher.decrypt(ciphertext)
    try:
        cipher.verify(tag)
        return plaintext, True
    except ValueError:
        return plaintext, False


def ghash_s(key, iv, aad, data_c):
    """S = GHASH_H(A || 0 || C || 0 || len(A) || len(C)) = T xor CIPH_K(J0) (GCM 7.1 steps 5 and 6)."""
    _, tag = gcm_encrypt(key, iv, aad, gcm_decrypt(key, iv, aad, data_c, bytes(16))[0])
    return bytes(a ^ b for a, b in zip(tag, aes_ecb(key, j0(iv))))


def selftest():
    """pycryptodome reproduces the examples of FIPS 197 and of the GCM specification."""
    for key, pt, ct in FIPS197_ECB:
        assert aes_ecb(bytes.fromhex(key), bytes.fromhex(pt)).hex() == ct, f"FIPS 197 example {key}"
    for name, key, iv, pt, aad, ct, tag in GCM_SPEC:
        c, t = gcm_encrypt(bytes.fromhex(key), bytes.fromhex(iv), bytes.fromhex(aad), bytes.fromhex(pt))
        assert c.hex() == ct and t.hex() == tag, f"GCM test case {name}: {c.hex()} {t.hex()}"
    return len(FIPS197_ECB) + len(GCM_SPEC)


# ---------------------------------------------------------------------------------------------------
# Messages of the core
# ---------------------------------------------------------------------------------------------------
class Slot:
    def __init__(self, key, ivgen=False, fixed=0, counter=0):
        self.key = key
        self.ivgen = ivgen
        self.fixed = fixed
        self.counter = counter

    def next_iv(self):
        """Deterministic construction (GCM 8.2.1): fixed field || invocation counter."""
        iv = self.fixed.to_bytes(4, "big") + self.counter.to_bytes(8, "big")
        self.counter += 1
        return iv


class VectorFile:
    """Writes a vector file; keeps the state of the key slots to predict generated IVs."""

    def __init__(self, path):
        self.path = Path(path)
        self.lines = [f"# OpenCrypto test vectors, {Path(__file__).name}, pycryptodome {AES.__name__}"]
        self.slots = {}
        self.count = 0

    # AES engine ----------------------------------------------------------------------------------------
    def ecb(self, key, block):
        self.lines.append(f"ECB {key.hex()} {block.hex()} {aes_ecb(key, block).hex()}")
        self.count += 1

    # Key table -----------------------------------------------------------------------------------------
    def key(self, slot, key, ivgen=False, fixed=0, counter=0, write=True):
        self.slots[slot] = Slot(key, ivgen, fixed, counter)
        if write:
            self.lines.append(f"KEY {slot} {key.hex()} {hash_subkey(key).hex()} {int(ivgen)} {fixed:08x} "
                              f"{counter:016x}")

    # Messages ------------------------------------------------------------------------------------------
    def encrypt(self, slot, aad, data, iv=None, ivgen=False, flags=0, ghash=False):
        """GCM-AE of a message. aad, data: bytes, b'' for an empty section, None for no section."""
        s = self.slots[slot]
        if ivgen:
            iv = s.next_iv()
        c, t = gcm_encrypt(s.key, iv, aad or b"", data or b"")
        self._msg(0, slot, ivgen, iv if not ivgen else bytes(12), flags)
        if aad is not None:
            self.lines.append(f"IN A {hx(aad)}")
        if data is not None:
            self.lines.append(f"IN D {hx(data)}")
        if aad is None and data is None:
            self.lines.append("IN D -")
        if ivgen:
            self.lines.append(f"OUT I {iv.hex()}")
        if aad:
            self.lines.append(f"OUT A {aad.hex()}")
        if c:
            self.lines.append(f"OUT D {c.hex()}")
        self.lines.append(f"OUT T {t.hex()}")
        if ghash:
            self.lines.append(f"GH {ghash_s(s.key, iv, aad or b'', c).hex()}")
        self._end(OK, aad, data, iv)
        return c, t

    def decrypt(self, slot, aad, data_c, tag, iv, flags=0, ghash=False):
        """GCM-AD of a message; the verdict follows from the tag."""
        s = self.slots[slot]
        p, ok = gcm_decrypt(s.key, iv, aad or b"", data_c or b"", tag)
        self._msg(1, slot, False, iv, flags)
        if aad is not None:
            self.lines.append(f"IN A {hx(aad)}")
        if data_c is not None:
            self.lines.append(f"IN D {hx(data_c)}")
        self.lines.append(f"IN T {hx(tag)}")
        if aad:
            self.lines.append(f"OUT A {aad.hex()}")
        if p:
            self.lines.append(f"OUT D {p.hex()}")
        if not aad and not p:
            self.lines.append("OUT D -")
        if ghash:
            self.lines.append(f"GH {ghash_s(s.key, iv, aad or b'', data_c or b'').hex()}")
        self._end(OK if ok else AUTH, aad, data_c, iv)
        return p, ok

    def failed(self, dec, slot, sections, code, iv=bytes(12), ivgen=False, aad_bytes=0, data_bytes=0,
               iv_used=None, flags=0, empty_out=False):
        """Message that fails with a code: the input sections as given, the output content not checked
        (empty_out: one empty beat expected, as for a rejected context)."""
        self._msg(dec, slot, ivgen, iv, flags)
        for sec, data in sections:
            self.lines.append(f"IN {sec} {hx(data)}")
        self.lines.append("OUT D -" if empty_out else "OUT X -")
        self.lines.append(f"STS {code} {aad_bytes} {data_bytes} {(iv_used if iv_used is not None else iv).hex()}")
        self.lines.append("END")
        self.count += 1

    def override_last(self, code, zero_tag=False):
        """Changes the expected status code of the last message; zero_tag: its TAG section becomes zeros (D12)."""
        for i in range(len(self.lines) - 1, -1, -1):
            tok = self.lines[i].split()
            if tok[0] == "MSG":
                break
            if tok[0] == "STS":
                tok[1] = str(code)
                self.lines[i] = " ".join(tok)
            elif tok[0] == "OUT" and tok[1] == "T" and zero_tag:
                self.lines[i] = "OUT T " + "00" * 16

    def _msg(self, dec, slot, ivgen, iv, flags):
        self.lines.append(f"MSG {dec} {slot} {int(ivgen)} {iv.hex()} {flags:x}")

    def _end(self, code, aad, data, iv):
        self.lines.append(f"STS {code} {len(aad or b'')} {len(data or b'')} {iv.hex()}")
        self.lines.append("END")
        self.count += 1

    def write(self):
        self.path.parent.mkdir(parents=True, exist_ok=True)
        self.path.write_text("\n".join(self.lines) + "\n", encoding="ascii", newline="\n")
        return self.path


def rand_bytes(rng, n):
    return bytes(rng.getrandbits(8) for _ in range(n))


def corrupt(rng, data):
    """Flips one random bit."""
    b = bytearray(data)
    i = rng.randrange(len(b))
    b[i] ^= 1 << rng.randrange(8)
    return bytes(b)


# ---------------------------------------------------------------------------------------------------
# Vector sets of the testbenches
# ---------------------------------------------------------------------------------------------------
def ecb_set(path, key_bits, count, seed):
    """FIPS 197 examples of the key length(s), then keys and blocks of all zeros and all ones, then random keys
    and blocks. key_bits: one key length or a list of key lengths."""
    vf = VectorFile(path)
    rng = random.Random(seed)
    for bits in key_bits if isinstance(key_bits, (list, tuple)) else [key_bits]:
        for key, pt, _ in FIPS197_ECB:
            if len(key) * 4 == bits:
                vf.ecb(bytes.fromhex(key), bytes.fromhex(pt))
        edge = [bytes(16), b"\xff" * 16]
        for i in range(count):
            if i < 4:
                key = bytes(bits // 8) if i % 2 == 0 else b"\xff" * (bits // 8)
                vf.ecb(key, edge[i // 2])
            else:
                vf.ecb(rand_bytes(rng, bits // 8), rand_bytes(rng, 16))
    return vf.write()


def gcm_spec_set(path, key_bits, decrypt=False):
    """Test cases of the GCM specification for the key length, in slot 0 and 1 (one key each)."""
    vf = VectorFile(path)
    cases = [c for c in GCM_SPEC if len(c[1]) * 4 == key_bits]
    keys = []
    for case in cases:
        if case[1] not in keys:
            keys.append(case[1])
    for slot, key in enumerate(keys):
        vf.key(slot, bytes.fromhex(key))
    for name, key, iv, pt, aad, ct, tag in cases:
        slot = keys.index(key)
        aad_b = bytes.fromhex(aad) if aad else None
        if decrypt:
            vf.decrypt(slot, aad_b, bytes.fromhex(ct) if ct else None, bytes.fromhex(tag), bytes.fromhex(iv),
                       ghash=True)
        else:
            vf.encrypt(slot, aad_b, bytes.fromhex(pt) if pt else None, iv=bytes.fromhex(iv), ghash=True)
    return vf.write()


def random_lengths(rng, count, max_aad, max_data):
    """Section lengths with the boundary cases first: absent, empty, one byte, block boundaries."""
    special = [(None, 1), (0, None), (None, 0), (1, None), (None, 1), (16, 16), (15, 17), (17, 15), (1, 1),
               (0, 0), (32, 31), (13, 64)]
    result = []
    for i in range(count):
        if i < len(special):
            a, d = special[i]
        else:
            a = rng.choice([None, rng.randint(0, max_aad)])
            d = rng.choice([None, rng.randint(0, max_data)]) if a is not None else rng.randint(0, max_data)
        if a is not None:
            a = min(a, max_aad)
        if d is not None:
            d = min(d, max_data)
        result.append((a, d))
    return result


def gcm_random_set(path, key_bits, count, seed, max_aad=80, max_data=300, slots=1, mode="enc", ghash=False,
                   ivgen=False, len_bits=None):
    """Random messages. mode: 'enc', 'dec' (correct tags), 'mixed' (both directions, some tags corrupted).
    ivgen: encryptions with IVs of the IV generation unit of their slot. len_bits: sections longer than
    2^len_bits - 1 bytes fail with LENGTH (the TAG section of an encryption is then zeros)."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    for s in range(slots):
        vf.key(s, rand_bytes(rng, key_bits // 8), ivgen=ivgen, fixed=rng.getrandbits(32),
               counter=rng.getrandbits(40))
    limit = None if len_bits is None else 2 ** len_bits - 1
    for a_len, d_len in random_lengths(rng, count, max_aad, max_data):
        slot = rng.randrange(slots)
        aad = None if a_len is None else rand_bytes(rng, a_len)
        data = None if d_len is None else rand_bytes(rng, d_len)
        iv = rand_bytes(rng, 12)
        dec = mode == "dec" or (mode == "mixed" and rng.random() < 0.5) and not ivgen
        too_long = limit is not None and (len(aad or b"") > limit or len(data or b"") > limit)
        if not dec:
            vf.encrypt(slot, aad, data, iv=iv, ivgen=ivgen, ghash=ghash)
        else:
            c, t = gcm_encrypt(vf.slots[slot].key, iv, aad or b"", data or b"")
            c_in = None if data is None else c
            if mode == "mixed" and rng.random() < 0.3:
                # A modified tag, AAD or ciphertext fails the verification (GCM 7.2 step 8)
                what = rng.choice(["tag", "aad", "data"])
                if what == "aad" and aad:
                    aad = corrupt(rng, aad)
                elif what == "data" and c_in:
                    c_in = corrupt(rng, c_in)
                else:
                    t = corrupt(rng, t)
            vf.decrypt(slot, aad, c_in, t, iv, ghash=ghash)
        if too_long:
            vf.override_last(LENGTH, zero_tag=not dec)
    return vf.write()


def format_set(path, key_bits, seed):
    """Messages that violate the format of the message (docs/architecture.md, section 6): FORMAT, content of the
    output not checked. Every format error is followed by a correct message of the same direction, so that the
    recovery of the parser is checked."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    vf.key(0, rand_bytes(rng, key_bits // 8))

    def good(dec):
        aad, data, iv = rand_bytes(rng, 21), rand_bytes(rng, 37), rand_bytes(rng, 12)
        if dec:
            c, t = gcm_encrypt(vf.slots[0].key, iv, aad, data)
            vf.decrypt(0, aad, c, t, iv)
        else:
            vf.encrypt(0, aad, data, iv=iv)

    tag = rand_bytes(rng, 16)
    cases = [
        (0, [("D", rand_bytes(rng, 20)), ("A", rand_bytes(rng, 5))]),        # AAD after DATA
        (1, [("D", rand_bytes(rng, 20)), ("A", rand_bytes(rng, 5)), ("T", tag)]),
        (0, [("I", rand_bytes(rng, 12)), ("D", rand_bytes(rng, 9))]),        # IV section on the input
        (1, [("I", rand_bytes(rng, 12)), ("D", rand_bytes(rng, 9)), ("T", tag)]),
        (0, [("A", rand_bytes(rng, 3)), ("D", rand_bytes(rng, 30)), ("T", tag)]),  # TAG on an encryption
        (1, [("A", rand_bytes(rng, 3)), ("D", rand_bytes(rng, 30))]),        # decryption without TAG
        (1, [("D", rand_bytes(rng, 33)), ("T", rand_bytes(rng, 15))]),       # tag of 15 bytes
        (1, [("D", rand_bytes(rng, 33)), ("T", rand_bytes(rng, 17))]),       # tag of 17 bytes
        (1, [("D", rand_bytes(rng, 33)), ("T", tag), ("T", rand_bytes(rng, 4))]),  # tag of 20 bytes
        (0, [("A", rand_bytes(rng, 1)), ("A", rand_bytes(rng, 20))]),        # partial beat inside a section
        (1, [("D", rand_bytes(rng, 1)), ("D", rand_bytes(rng, 20)), ("T", tag)]),
        (0, [("A", b""), ("A", rand_bytes(rng, 8)), ("D", rand_bytes(rng, 8))]),  # empty beat inside a section
        (0, [("a", rand_bytes(rng, 5)), ("D", rand_bytes(rng, 8))]),         # byte enables not contiguous
        (1, [("A", rand_bytes(rng, 7)), ("d", rand_bytes(rng, 18)), ("T", tag)]),
        (0, [("D", rand_bytes(rng, 40)), ("D", b"")]),                       # empty beat at the end of a section
        (1, [("T", tag), ("D", rand_bytes(rng, 4)), ("T", tag)]),            # DATA after TAG
    ]
    for dec, sections in cases:
        iv = rand_bytes(rng, 12)
        vf.failed(dec, 0, sections, FORMAT, iv=iv)
        good(dec)
    return vf.write()


def reject_set(path, key_bits, seed):
    """Messages whose job carries a context error (KEY, IV_MODE, IV_EXHAUSTED, ECC): consumed, one empty output
    beat with the error flag; each followed by a correct message. At the end a rejected job with the IV section flag,
    followed by an encryption with a generated IV, and a decryption followed by an encryption with a generated IV."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    vf.key(0, rand_bytes(rng, key_bits // 8))
    for i, code in enumerate([KEY, IV_MODE, IV_EXHAUSTED, ECC, KEY, KEY]):
        dec = i % 2
        iv = rand_bytes(rng, 12)
        sections = [("A", rand_bytes(rng, 9 + 7 * i)), ("D", rand_bytes(rng, 3 + 11 * i))]
        if dec:
            sections.append(("T", rand_bytes(rng, 16)))
        vf.failed(dec, 0, sections, code, iv=iv, flags=FLAG_JOB_ERR, empty_out=True)
        aad, data, iv = rand_bytes(rng, 5 * i), rand_bytes(rng, 17 * i + 1), rand_bytes(rng, 12)
        if dec:
            c, t = gcm_encrypt(vf.slots[0].key, iv, aad, data)
            vf.decrypt(0, aad, c, t, iv)
        else:
            vf.encrypt(0, aad, data, iv=iv)
    vf.slots[0].fixed, vf.slots[0].counter = rng.getrandbits(32), rng.getrandbits(40)
    vf.failed(0, 0, [("A", rand_bytes(rng, 6)), ("D", rand_bytes(rng, 10))], IV_EXHAUSTED, ivgen=True,
              flags=FLAG_JOB_ERR, empty_out=True)
    vf.encrypt(0, rand_bytes(rng, 7), rand_bytes(rng, 19), ivgen=True)
    aad, data, iv = rand_bytes(rng, 11), rand_bytes(rng, 23), rand_bytes(rng, 12)
    c, t = gcm_encrypt(vf.slots[0].key, iv, aad, data)
    vf.decrypt(0, aad, c, t, iv)
    vf.encrypt(0, None, rand_bytes(rng, 5), ivgen=True)
    return vf.write()


def tiny_set(path, key_bits, count, seed):
    """Encryptions of 1 to 4 bytes of DATA without AAD: one input beat per message at 32 bits and more, so that the
    AES engine and GHASH set the pace of the data path."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    vf.key(0, rand_bytes(rng, key_bits // 8))
    for _ in range(count):
        vf.encrypt(0, None, rand_bytes(rng, rng.randint(1, 4)), iv=rand_bytes(rng, 12))
    return vf.write()


def backlog_set(path, key_bits, count, seed):
    """Short messages of every kind for the back-pressure inside the data path: encryptions with external and with
    generated IVs and decryptions (20 % with a modified tag), absent or empty sections, AAD of up to 4 and DATA of up
    to 8 bytes."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    vf.key(0, rand_bytes(rng, key_bits // 8))
    vf.key(1, rand_bytes(rng, key_bits // 8), ivgen=True, fixed=rng.getrandbits(32), counter=rng.getrandbits(40))
    for _ in range(count):
        kind = rng.random()
        aad = rand_bytes(rng, rng.randint(0, 4)) if rng.random() < 0.5 else None
        data = rand_bytes(rng, rng.randint(0, 8)) if rng.random() < 0.8 else None
        if kind < 0.35:
            vf.encrypt(0, aad, data, iv=rand_bytes(rng, 12))
        elif kind < 0.6:
            vf.encrypt(1, aad, data, ivgen=True)
        else:
            iv = rand_bytes(rng, 12)
            c, t = gcm_encrypt(vf.slots[0].key, iv, aad or b"", data or b"")
            if rng.random() < 0.2:
                t = corrupt(rng, t)
            vf.decrypt(0, aad, c if data is not None else None, t, iv)
    return vf.write()


def release_set(path, key_bits, count, seed, release_bytes, width=None):
    """Mixed messages for the release buffer: small ones (at most 146 bytes of output, at most 256 + 4 beats and so
    below a buffer of at least 512 bytes) and large ones (at least 2.5 times the buffer, OVERFLOW unless they fail
    otherwise); some decryptions fail. With width (bits of the stream) the buffer holds D = release_bytes / (width /
    8) beats: the set starts with the messages of exactly D and D + 1 sectioned output beats of both directions (the
    longest message that fits and the shortest that overflows), and the small messages have at most D beats."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    vf.key(0, rand_bytes(rng, key_bits // 8))
    if width is not None:
        b = width // 8
        depth = release_bytes // b

        def beats(a_len, d_len, dec):
            # Sectioned output beats: non-empty AAD and DATA sections, the TAG of an encryption
            n = -(-a_len // b) + -(-d_len // b) + (0 if dec else 16 // b)
            return max(1, n)

        for dec, a_len in ((False, 0), (False, 5), (True, 0), (True, 5)):
            fit = (depth - beats(a_len, 0, dec) + (1 if dec and a_len == 0 else 0)) * b
            for d_len, over in ((fit, False), (fit + 1, True)):
                assert beats(a_len, d_len, dec) == depth + over
                aad, data, iv = rand_bytes(rng, a_len), rand_bytes(rng, d_len), rand_bytes(rng, 12)
                if dec:
                    c, t = gcm_encrypt(vf.slots[0].key, iv, aad, data)
                    vf.decrypt(0, aad, c, t, iv)
                else:
                    vf.encrypt(0, aad, data, iv=iv)
                if over:
                    vf.override_last(OVERFLOW)
    for i in range(count):
        large = rng.random() < 0.2
        if large:
            a_len, d_len = rng.randint(0, 40), rng.randint(int(2.5 * release_bytes), int(3 * release_bytes))
        else:
            a_len, d_len = rng.randint(0, 40), rng.randint(0, 90)
            while width is not None and beats(a_len, d_len, False) > depth:
                a_len, d_len = rng.randint(0, 40), rng.randint(0, 90)
        aad, data, iv = rand_bytes(rng, a_len), rand_bytes(rng, d_len), rand_bytes(rng, 12)
        dec = rng.random() < 0.6
        if dec:
            c, t = gcm_encrypt(vf.slots[0].key, iv, aad, data)
            if rng.random() < 0.3:
                t = corrupt(rng, t)
            _, ok = vf.decrypt(0, aad, c, t, iv)
        else:
            vf.encrypt(0, aad, data, iv=iv)
            ok = True
        if large and ok:
            vf.override_last(OVERFLOW)
    return vf.write()


def fixed_set(path, key_bits, count, seed, data_len, decrypt=False, aad_len=None, ivgen=False):
    """Messages of one length for throughput measurements: count encryptions (or decryptions with correct tags) of
    data_len bytes of DATA, with aad_len bytes of AAD (None: no AAD section), with external IVs or (ivgen,
    encryptions only) with the IVs of the IV generation unit of the slot."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    vf.key(0, rand_bytes(rng, key_bits // 8), ivgen=ivgen, fixed=rng.getrandbits(32), counter=rng.getrandbits(40))
    for _ in range(count):
        aad = None if aad_len is None else rand_bytes(rng, aad_len)
        data, iv = rand_bytes(rng, data_len), rand_bytes(rng, 12)
        if decrypt:
            c, t = gcm_encrypt(vf.slots[0].key, iv, aad or b"", data)
            vf.decrypt(0, aad, c, t, iv)
        else:
            vf.encrypt(0, aad, data, iv=iv, ivgen=ivgen)
    return vf.write()


FLAG_JOB_ERR = 0x8
FLAG_OUT_OK = 0x10
FLAG_OUT_ERR = 0x20


def core_error_set(path, key_bits, num_keys, seed):
    """Messages whose context the key table rejects, between correct messages: slot not loaded, slot out of
    range, external IV for a slot of generated IVs, generated IV for a slot of external IVs, generated IV for a
    decryption, exhausted invocation counter (slot 1 starts at 2^64 - 2: one IV left)."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    vf.key(0, rand_bytes(rng, key_bits // 8))
    vf.key(1, rand_bytes(rng, key_bits // 8), ivgen=True, fixed=rng.getrandbits(32), counter=2 ** 64 - 2)
    unloaded = 2 if num_keys > 2 else None
    out_of_range = num_keys if num_keys < 2 ** max(1, (num_keys - 1).bit_length()) else None

    def good():
        aad, data, iv = rand_bytes(rng, rng.randint(0, 30)), rand_bytes(rng, rng.randint(1, 70)), rand_bytes(rng, 12)
        if rng.random() < 0.5:
            vf.encrypt(0, aad, data, iv=iv)
        else:
            c, t = gcm_encrypt(vf.slots[0].key, iv, aad, data)
            vf.decrypt(0, aad, c, t, iv)

    def body(dec):
        sections = [("A", rand_bytes(rng, rng.randint(0, 20))), ("D", rand_bytes(rng, rng.randint(1, 50)))]
        if dec:
            sections.append(("T", rand_bytes(rng, 16)))
        return sections

    cases = []
    if unloaded is not None:
        cases += [(0, unloaded, False, KEY), (1, unloaded, False, KEY)]
    if out_of_range is not None:
        cases += [(0, out_of_range, False, KEY)]
    cases += [(0, 1, False, IV_MODE), (0, 0, True, IV_MODE), (1, 1, True, IV_MODE)]
    for dec, slot, ivgen, code in cases:
        good()
        iv = bytes(12) if ivgen else rand_bytes(rng, 12)
        vf.failed(dec, slot, body(dec), code, iv=iv, ivgen=ivgen, empty_out=True)
    # The last IV of slot 1, then the slot is exhausted
    good()
    vf.encrypt(1, rand_bytes(rng, 9), rand_bytes(rng, 33), ivgen=True)
    vf.failed(0, 1, body(0), IV_EXHAUSTED, iv=bytes(12), ivgen=True, empty_out=True)
    good()
    return vf.write()


def zeroized_set(path, key_bits, count, seed, slots=2):
    """Messages after a zeroize: every context selects an erased slot (KEY, one empty output beat)."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    for i in range(count):
        dec = i % 2
        sections = [("A", rand_bytes(rng, rng.randint(0, 20))), ("D", rand_bytes(rng, rng.randint(1, 40)))]
        if dec:
            sections.append(("T", rand_bytes(rng, 16)))
        vf.failed(dec, i % slots, sections, KEY, iv=rand_bytes(rng, 12), empty_out=True)
    return vf.write()


def series_set(path, key_bits, count, seed, slots=2):
    """Encryptions with external IVs for two cores in series: the second core decrypts the output of the first."""
    return gcm_random_set(path, key_bits, count, seed, max_aad=48, max_data=200, slots=slots, mode="enc")


def kt_ecc_set(path, key_bits, seed):
    """Key table error injection: for the key, H and IV memory and the job FIFO one context after a single error
    (OK) and one after a double error (ECC); KEY record 0 loads slot 0 for external IVs. KEY record 1 loads the same
    key into slot 0 for generated IVs: two contexts with generated IVs, after a single and a double error in the job
    FIFO, each after a new load (same IV; the job with the double error carries the IV but no IV section flag)."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    key = rand_bytes(rng, key_bits // 8)
    fixed, counter = rng.getrandbits(32), rng.getrandbits(48)
    vf.key(0, key)
    vf.key(0, key, ivgen=True, fixed=fixed, counter=counter)
    for _ in range(4):
        for code in (OK, ECC):
            iv = rand_bytes(rng, 12)
            vf._msg(0, 0, False, iv, 0)
            vf.lines.append(f"STS {code} 0 0 {iv.hex()}")
            vf.lines.append("END")
            vf.count += 1
    iv = fixed.to_bytes(4, "big") + counter.to_bytes(8, "big")
    for code in (OK, ECC):
        vf._msg(0, 0, True, bytes(12), 0)
        vf.lines.append(f"STS {code} 0 0 {iv.hex()}")
        vf.lines.append("END")
        vf.count += 1
    return vf.write()


def kt_core_ecc_set(path, key_bits, seed):
    """Key table error injection through the core: for the key, H and IV word of a load and for the job FIFO one
    encryption after a single error (OK) and one after a double error (rejected with ECC, one empty output beat);
    slot 0 holds an external-IV key."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    vf.key(0, rand_bytes(rng, key_bits // 8))
    for _ in range(4):
        for ded in (0, 1):
            aad, data, iv = rand_bytes(rng, 13), rand_bytes(rng, 37), rand_bytes(rng, 12)
            if ded:
                vf.failed(0, 0, [("A", aad), ("D", data)], ECC, iv=iv, empty_out=True)
            else:
                vf.encrypt(0, aad, data, iv=iv)
    return vf.write()


def kt_set(path, key_bits, num_keys, count, seed, loaded=None, exhaust_slot=None, ivgen_ratio=0.4, avoid=(),
           dec_ratio=0.4):
    """Contexts for the key table: KEY records of the loaded slots (generated or external IVs), then contexts of
    loaded, unloaded and out-of-range slots in both directions with both IV sources. The expected job error is the
    status code (KEY, IV_MODE, IV_EXHAUSTED or OK), the expected IV the IV of the job (generated IVs follow the
    invocation counter of their slot). exhaust_slot: slot loaded with the counter 2^64 - 3 (two IVs left)."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    slot_bits = max(1, (num_keys - 1).bit_length())
    if loaded is None:
        loaded = list(range(num_keys - 1)) if num_keys > 1 else [0]
    for s in loaded:
        gen = s % 2 == 0
        counter = (2 ** 64 - 3) if s == exhaust_slot else rng.getrandbits(48)
        vf.key(s, rand_bytes(rng, key_bits // 8), ivgen=gen, fixed=rng.getrandbits(32), counter=counter)
    for _ in range(count):
        slot = rng.randrange(2 ** slot_bits)
        if slot in loaded and rng.random() < 0.7:
            pass
        elif loaded and rng.random() < 0.8:
            slot = rng.choice(loaded)
        while slot in avoid:
            slot = rng.randrange(2 ** slot_bits)
        dec = rng.random() < dec_ratio
        ivgen = rng.random() < ivgen_ratio
        iv = rand_bytes(rng, 12)
        s = vf.slots.get(slot)
        code, iv_used = OK, iv
        if slot >= num_keys or s is None:
            code = KEY
        elif ivgen:
            if dec or not s.ivgen:
                code = IV_MODE
            elif s.counter == 2 ** 64 - 1:
                code = IV_EXHAUSTED
            else:
                iv_used = s.next_iv()
        elif not dec and s.ivgen:
            code = IV_MODE
        if ivgen:
            iv = bytes(12)
            if code != OK:
                iv_used = iv
        vf._msg(int(dec), slot, ivgen, iv, 0)
        vf.lines.append(f"STS {code} 0 0 {iv_used.hex()}")
        vf.lines.append("END")
        vf.count += 1
    return vf.write()

# FT buffers of the GCM data path (ocr_gcm_pkg, GcmEcc*_c)
ECC_BUFFERS = ["dat", "ks", "j0", "hash", "out", "h", "desc", "sum", "res", "sts", "rel"]


def ecc_set(path, key_bits, seed, release=False):
    """Per FT buffer four messages: encryption with a single error, encryption with a double error, decryption
    with a single error, decryption with a double error (the test injects into the next entry of the buffer before
    each message). A single error is corrected; a double error fails the message with ECC, except in the status
    FIFO (only the status reports ECC) and in the release buffer (the status is OK, the output carries the error
    flag)."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    vf.key(0, rand_bytes(rng, key_bits // 8))
    for buf in ECC_BUFFERS if release else ECC_BUFFERS[:-1]:
        for dec in (0, 1):
            for ded in (0, 1):
                aad, data, iv = rand_bytes(rng, 19), rand_bytes(rng, 45), rand_bytes(rng, 12)
                flags = 0
                if ded and buf == "sts":
                    flags = FLAG_OUT_OK
                elif ded and buf == "rel":
                    flags = FLAG_OUT_ERR
                if dec:
                    c, t = gcm_encrypt(vf.slots[0].key, iv, aad, data)
                    vf.decrypt(0, aad, c, t, iv, flags=flags)
                else:
                    vf.encrypt(0, aad, data, iv=iv, flags=flags)
                if ded and buf != "rel":
                    vf.override_last(ECC, zero_tag=not dec and buf != "sts")
    return vf.write()


def packer_set(path, count, seed, max_len=70):
    """Sectioned output messages for the output packer: the sections of an output message of the core (IV, AAD, DATA,
    TAG, each optional, in this order), with the boundary cases first: one byte, a message without any byte, the
    lengths of the core outputs, empty sections between sections with bytes. The expected output sections are the
    input sections; 20 % of the messages carry the error flag (status AUTH)."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    special = [
        [("D", 1)], [("D", 0)], [("I", 12), ("A", 5), ("D", 17), ("T", 16)], [("I", 12), ("T", 16)],
        [("A", 3), ("T", 16)], [("A", 0), ("D", 9)], [("D", 16), ("T", 16)], [("A", 15), ("D", 1), ("T", 16)],
        [("I", 12), ("A", 4), ("D", 64), ("T", 16)], [("A", 7)], [("I", 12), ("A", 1), ("D", 0), ("T", 16)],
        [("A", 1), ("D", 1), ("T", 1)],
    ]
    for i in range(count):
        if i < len(special):
            secs = special[i]
        else:
            secs = []
            for code in "IADT":
                if rng.random() < (0.4 if code == "I" else 0.7):
                    n = {"I": 12, "T": 16}.get(code, rng.randint(0, max_len)) if rng.random() < 0.7 else \
                        rng.randint(0, max_len)
                    secs.append((code, n))
            # A beat without byte is the only beat of a message, or the first beat of a section between others (the
            # output assembly never ends a message with bytes by an empty beat)
            while len(secs) > 1 and secs[-1][1] == 0:
                secs.pop()
            if not secs:
                secs = [("D", rng.randint(0, max_len))]
        err = i >= len(special) and rng.random() < 0.2 or i == 1
        vf._msg(0, 0, False, bytes(12), 0)
        data = [(code, rand_bytes(rng, n)) for code, n in secs]
        for code, d in data:
            vf.lines.append(f"IN {code} {hx(d)}")
        for code, d in data:
            vf.lines.append(f"OUT {code} {hx(d)}")
        vf.lines.append(f"STS {AUTH if err else OK} 0 0 {bytes(12).hex()}")
        vf.lines.append("END")
        vf.count += 1
    return vf.write()


def image_lengths(rng, chunk_bytes, count, max_chunks=3):
    """Lengths of the input packets of the framer: the boundary cases first (empty, one byte, one byte less, exactly,
    one byte more than a chunk, exactly two and three chunks, two chunks and three bytes), then random lengths up to
    max_chunks chunks."""
    c = chunk_bytes
    special = [0, 1, c - 1, c, c + 1, 2 * c, 2 * c + 3, 3 * c, 15, 16, 17]
    result = special[:count]
    while len(result) < count:
        result.append(rng.randint(1, max_chunks * c))
    return result


def chunk_position(index, chunks):
    """Position of chunk index of a packet of chunks chunks."""
    if chunks == 1:
        return POS_SINGLE
    if index == 0:
        return POS_FIRST
    if index == chunks - 1:
        return POS_LAST
    return POS_MIDDLE


def framer_set(path, key_bits, chunk_bytes, lengths, seed, core, poisoned=(), slot=0):
    """Input packets of the framer, one message per chunk: the chunk as input DATA section, FLAG_IMG_END on the last
    chunk of a packet. core=False (framer alone): the expected output is the AAD section with the chunk position and
    the chunk as DATA section. core=True (framer and ocr_core with the dense output): the expected output is the
    encryption with the next generated IV of the slot: IV, AAD, ciphertext and tag. The chunks of poisoned (indices
    of the messages) carry an injected double error: the content is not checked, the message fails with FORMAT (the
    IV is still consumed)."""
    rng = random.Random(seed)
    vf = VectorFile(path)
    vf.key(slot, rand_bytes(rng, key_bits // 8), ivgen=True, fixed=rng.getrandbits(32), counter=rng.getrandbits(40))
    s = vf.slots[slot]
    m = 0
    for length in lengths:
        image = rand_bytes(rng, length)
        chunks = max(1, (length + chunk_bytes - 1) // chunk_bytes)
        for k in range(chunks):
            chunk = image[k * chunk_bytes:(k + 1) * chunk_bytes]
            aad = bytes([chunk_position(k, chunks) << 6, 0, 0, 0])
            flags = FLAG_IMG_END if k == chunks - 1 else 0
            vf._msg(0, slot, True, bytes(12), flags)
            vf.lines.append(f"IN D {hx(chunk)}")
            iv = s.next_iv() if core else bytes(12)
            if m in poisoned:
                vf.lines.append("OUT X -")
                vf.lines.append(f"STS {FORMAT} 0 0 {iv.hex()}")
            elif core:
                c, t = gcm_encrypt(s.key, iv, aad, chunk)
                vf.lines.append(f"OUT I {iv.hex()}")
                vf.lines.append(f"OUT A {aad.hex()}")
                if c:
                    vf.lines.append(f"OUT D {c.hex()}")
                vf.lines.append(f"OUT T {t.hex()}")
                vf.lines.append(f"STS {OK} 4 {len(chunk)} {iv.hex()}")
            else:
                vf.lines.append(f"OUT A {aad.hex()}")
                vf.lines.append(f"OUT D {hx(chunk)}")
                vf.lines.append(f"STS {OK} 4 {len(chunk)} {iv.hex()}")
            vf.lines.append("END")
            vf.count += 1
            m += 1
    return vf.write()


def main():
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--selftest", action="store_true", help="check pycryptodome against the examples")
    args = parser.parse_args()
    if args.selftest:
        print(f"pycryptodome reproduces {selftest()} examples of FIPS 197 and of the GCM specification")
        return 0
    parser.print_help()
    return 0


if __name__ == "__main__":
    sys.exit(main())
