# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of the ocr_gcm testbench: data widths and key lengths with the default numbers of AES
units and GHASH digits, the minimum and the maximum units and digit, the release buffer (with its minimum size) and
8-bit byte counts."""

# name: (data width, key bits, extra generics)
DEFAULT = {
    "w16_aes256": (16, 256, {}),
    "w32_aes128": (32, 128, {}),
    "w32_aes192": (32, 192, {}),
    "w64_aes128": (64, 128, {}),
    "w64_aes256": (64, 256, {}),
    "w128_aes128": (128, 128, {}),
    "w128_aes192": (128, 192, {}),
    "w128_aes256": (128, 256, {}),
}
MINIMUM = {"w32_aes256_min": (32, 256, {"AesUnits_g": 4, "GhashDigit_g": 32})}
MAXIMUM = {"w32_aes256_max": (32, 256, {"AesUnits_g": 14, "GhashDigit_g": 128})}
RELEASE = {
    "w32_aes256_rel": (32, 256, {"ReleaseBuffer_g": True, "ReleaseBytes_g": 512}),
    "w128_aes256_rel": (128, 256, {"ReleaseBuffer_g": True, "ReleaseBytes_g": 1024}),
}
# The smallest release buffer: 16 beats of 32 bits
RELEASE_MIN = {"w32_aes256_rel64": (32, 256, {"ReleaseBuffer_g": True, "ReleaseBytes_g": 64})}
LENGTH = {"w32_aes128_len8": (32, 128, {"LenBits_g": 8})}

TESTS_DEFAULT = ["test_gcm_spec", "test_encrypt", "test_decrypt", "test_mixed", "test_iv_section",
                 "test_throughput_encrypt", "test_throughput_decrypt", "test_format", "test_reject", "test_ecc",
                 "test_hash_subkey", "test_reset", "test_backlog"]
TESTS_MINIMUM = [t for t in TESTS_DEFAULT if not t.startswith("test_throughput")]
TESTS_RELEASE = ["test_release", "test_ecc", "test_mixed", "test_throughput_decrypt", "test_format", "test_reject"]
TESTS_RELEASE_MIN = ["test_release"]
TESTS_LENGTH = ["test_length"]


def vector_sets(vectors, d, bits):
    """All vector files of one key length in the directory d."""
    vectors.gcm_spec_set(d / "spec_enc.txt", bits)
    vectors.gcm_spec_set(d / "spec_dec.txt", bits, decrypt=True)
    vectors.gcm_random_set(d / "enc.txt", bits, 120, seed=bits + 1, max_aad=64, max_data=300, slots=2, mode="enc")
    vectors.gcm_random_set(d / "dec.txt", bits, 120, seed=bits + 2, max_aad=64, max_data=300, slots=2, mode="dec")
    vectors.gcm_random_set(d / "mixed.txt", bits, 150, seed=bits + 3, max_aad=64, max_data=300, slots=3,
                           mode="mixed")
    vectors.gcm_random_set(d / "ivgen.txt", bits, 80, seed=bits + 4, max_aad=48, max_data=200, slots=2, mode="enc",
                           ivgen=True)
    vectors.gcm_random_set(d / "tp_enc.txt", bits, 150, seed=bits + 5, max_aad=48, max_data=160, slots=2,
                           mode="enc")
    vectors.gcm_random_set(d / "tp_dec.txt", bits, 150, seed=bits + 6, max_aad=48, max_data=160, slots=2,
                           mode="dec")
    vectors.format_set(d / "format.txt", bits, seed=bits + 7)
    vectors.reject_set(d / "reject.txt", bits, seed=bits + 8)
    vectors.backlog_set(d / "backlog.txt", bits, 200, seed=bits + 12)
    vectors.tiny_set(d / "tiny.txt", bits, 200, seed=bits + 13)
    vectors.ecc_set(d / "ecc.txt", bits, seed=bits + 9)
    vectors.ecc_set(d / "ecc_rel.txt", bits, seed=bits + 9, release=True)
    vectors.gcm_random_set(d / "length.txt", bits, 60, seed=bits + 10, max_aad=400, max_data=500, slots=1,
                           mode="mixed", len_bits=8)
    for size in (512, 1024):
        vectors.release_set(d / f"release_{size}.txt", bits, 60, seed=bits + 11, release_bytes=size)
    vectors.release_set(d / "release_64.txt", bits, 60, seed=bits + 14, release_bytes=64, width=32)


def configure(lib, vectors):
    dirs = {}
    for bits in (128, 192, 256):
        d = vectors.DIR / "ocr_gcm" / f"aes{bits}"
        vector_sets(vectors, d, bits)
        dirs[bits] = d
    tb = lib.test_bench("ocr_gcm_tb")
    groups = [(DEFAULT, TESTS_DEFAULT), (MINIMUM, TESTS_MINIMUM), (MAXIMUM, TESTS_DEFAULT), (RELEASE, TESTS_RELEASE),
              (RELEASE_MIN, TESTS_RELEASE_MIN), (LENGTH, TESTS_LENGTH)]
    for test in tb.get_tests():
        for configs, tests in groups:
            if test.name not in tests:
                continue
            for name, (width, bits, extra) in configs.items():
                generics = {"DataWidth_g": width, "KeyBits_g": bits, "VecDir_g": dirs[bits].as_posix()}
                generics.update(extra)
                test.add_config(name=name, generics=generics)
