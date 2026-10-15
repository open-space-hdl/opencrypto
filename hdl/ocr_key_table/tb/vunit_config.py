# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of the ocr_key_table testbench: key lengths with one, three, four, 16 and 256 key slots, and
four slots with paced scrubbers."""

CONFIGS = [(256, 4), (128, 1), (192, 3), (256, 16), (128, 256)]
# Paced scrubbers: a clock of 1 MHz (the clock of the harness follows ClkFreqHz_g) and one scrub pass every 2 ms,
# so one pass every 2000 clock cycles. GHDL 6.0.0 cannot override real generics with -g: the bench takes the
# frequency in Hz and the period in µs as integers.
PACED = {"k256_n4_paced": (256, 4, {"ClkFreqHz_g": 1_000_000, "ScrubPeriodUs_g": 2000})}


def configure(lib, vectors):
    tb = lib.test_bench("ocr_key_table_tb")
    dirs = {}
    for bits, keys in CONFIGS:
        d = vectors.DIR / "ocr_key_table" / f"k{bits}_n{keys}"
        dirs[(bits, keys)] = d
        seed = 1000 * keys + bits
        last = keys - 1
        vectors.kt_set(d / "kt.txt", bits, keys, 300, seed=seed)
        vectors.kt_set(d / "unloaded.txt", bits, keys, 40, seed=seed + 1, loaded=[])
        vectors.kt_set(d / "exhaust.txt", bits, keys, 12, seed=seed + 2, loaded=[0], ivgen_ratio=1.0, dec_ratio=0.0,
                       exhaust_slot=0, avoid=[s for s in range(1, 2 ** max(1, (keys - 1).bit_length()))])
        others = [s for s in range(keys - 1)] if keys > 1 else [0]
        vectors.kt_set(d / "traffic.txt", bits, keys, 300, seed=seed + 3, loaded=others,
                       avoid=[last] if keys > 1 else [])
        vectors.kt_set(d / "lastslot.txt", bits, keys, 0, seed=seed + 4, loaded=[last])
        vectors.kt_ecc_set(d / "ecc.txt", bits, seed=seed + 5)
        vectors.kt_set(d / "tp_ext.txt", bits, keys, 100, seed=seed + 6, ivgen_ratio=0.0)
        gen = [s for s in range(0, keys, 2)][:4]
        vectors.kt_set(d / "tp_gen.txt", bits, keys, 100, seed=seed + 7, loaded=gen, ivgen_ratio=1.0, dec_ratio=0.0,
                       avoid=[s for s in range(2 ** max(1, (keys - 1).bit_length())) if s not in gen])
        for test in tb.get_tests():
            if test.name == "test_load_during_traffic" and keys == 1:
                continue
            test.add_config(name=f"k{bits}_n{keys}",
                            generics={"KeyBits_g": bits, "NumKeys_g": keys, "VecDir_g": d.as_posix()})
    for name, (bits, keys, extra) in PACED.items():
        generics = {"KeyBits_g": bits, "NumKeys_g": keys, "VecDir_g": dirs[(bits, keys)].as_posix()}
        generics.update(extra)
        for test in tb.get_tests():
            test.add_config(name=name, generics=generics)
