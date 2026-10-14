# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of the ocr_aes_engine testbench: every key length with one unit, the minimum and the
default numbers of the data widths and the full number of rounds, and every number of units from 1 to 14 with
at least one key length."""

CONFIGS = [(128, 1), (128, 3), (128, 5), (128, 7), (128, 8), (128, 9), (128, 10), (192, 3), (192, 11), (192, 12),
           (256, 2), (256, 4), (256, 6), (256, 13), (256, 14)]


def configure(lib, vectors):
    d = vectors.DIR / "ocr_aes"
    tb = lib.test_bench("ocr_aes_engine_tb")
    files = {bits: vectors.ecb_set(d / f"ecb_{bits}.txt", bits, 200, seed=bits) for bits in (128, 192, 256)}
    for bits, units in CONFIGS:
        tb.add_config(name=f"aes{bits}_u{units}",
                      generics={"KeyBits_g": bits, "Units_g": units, "VecEcb_g": files[bits].as_posix()})
