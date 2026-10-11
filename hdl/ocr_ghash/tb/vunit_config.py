# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of the ocr_ghash testbench: every data width with the smallest digit, the default digit
and the full digit; the length error with 8-bit byte counts."""

CONFIGS = [(16, 16), (16, 64), (16, 128), (32, 32), (32, 64), (64, 64), (64, 128), (128, 128)]


def spec_set(vectors, path):
    """GCM test cases of all key lengths, encryption and decryption, one key slot per key."""
    d = path.parent
    parts = [vectors.gcm_spec_set(d / f"spec_{bits}_{dec}.txt", bits, decrypt=bool(dec))
             for bits in (128, 192, 256) for dec in (0, 1)]
    lines, base = [], 0
    for f in parts:
        slots = 0
        for line in f.read_text().splitlines():
            tok = line.split()
            if tok and tok[0] in ("KEY", "MSG"):
                idx = 1 if tok[0] == "KEY" else 2
                tok[idx] = str(int(tok[idx]) + base)
                slots += tok[0] == "KEY"
                line = " ".join(tok)
            lines.append(line)
        base += slots
    path.write_text("\n".join(lines) + "\n", encoding="ascii", newline="\n")
    return path


def configure(lib, vectors):
    d = vectors.DIR / "ocr_ghash"
    spec = spec_set(vectors, d / "spec.txt")
    rand = vectors.gcm_random_set(d / "random.txt", 128, 150, seed=7, max_aad=80, max_data=300, slots=3,
                                  mode="mixed", ghash=True)
    long = vectors.gcm_random_set(d / "long.txt", 128, 40, seed=8, max_aad=400, max_data=600, slots=2,
                                  mode="mixed", ghash=True)
    tb = lib.test_bench("ocr_ghash_tb")
    for test in tb.get_tests():
        if test.name == "test_length_error":
            test.add_config(name="w32_d64_len8", generics={"DataWidth_g": 32, "Digit_g": 64, "LenBits_g": 8,
                                                           "VecSpec_g": spec.as_posix(), "VecRand_g": long.as_posix()})
        else:
            for width, digit in CONFIGS:
                test.add_config(name=f"w{width}_d{digit}",
                                generics={"DataWidth_g": width, "Digit_g": digit, "VecSpec_g": spec.as_posix(),
                                          "VecRand_g": rand.as_posix()})
