# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of the ocr_packer testbench: every data width with the same messages."""

TESTS = ["test_pack", "test_backpressure", "test_throughput", "test_reset"]


def configure(lib, vectors):
    tb = lib.test_bench("ocr_packer_tb")
    d = vectors.DIR / "ocr_packer"
    vectors.packer_set(d / "pack.txt", 200, seed=501)
    vectors.packer_set(d / "pack_long.txt", 80, seed=502, max_len=300)
    for width in (16, 32, 64, 128):
        generics = {"DataWidth_g": width, "VecDir_g": d.as_posix()}
        for test in tb.get_tests():
            if test.name in TESTS:
                test.add_config(name=f"w{width}", generics=generics)
