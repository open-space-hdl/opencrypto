# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of the ocr_core testbench."""

ALL = ["test_registers", "test_key_load", "test_messages", "test_iv_generation", "test_context_errors",
       "test_zeroize", "test_ecc", "test_ecc_key_table", "test_irq", "test_throughput_encrypt",
       "test_throughput_decrypt", "test_reset"]
SUBSET = ["test_registers", "test_messages", "test_iv_generation", "test_context_errors", "test_throughput_encrypt",
          "test_throughput_decrypt"]
IVGEN = ["test_throughput_ivgen"]
RELEASE = ["test_registers", "test_messages", "test_throughput_encrypt", "test_throughput_decrypt",
           "test_throughput_release"]

# name: (data width, key bits, key slots, extra generics, tests)
CONFIGS = {
    "w32_k256_n4": (32, 256, 4, {}, ALL),
    "w128_k256_n4": (128, 256, 4, {}, ALL + IVGEN),
    "w16_k128_n2": (16, 128, 2, {}, SUBSET),
    "w64_k192_n8": (64, 192, 8, {}, SUBSET + IVGEN),
    "w32_k256_n4_rel": (32, 256, 4, {"ReleaseBuffer_g": True, "ReleaseBytes_g": 512},
                        RELEASE),
    "w64_k256_n4_series": (64, 256, 4, {"Series_g": True}, ["test_series"]),
    # Dense output
    "w32_k256_n4_dense": (32, 256, 4, {"DenseOutput_g": True},
                          SUBSET + ["test_ecc", "test_reset"]),
    "w128_k256_n4_dense": (128, 256, 4, {"DenseOutput_g": True}, SUBSET + ["test_reset"] + IVGEN),
    "w16_k128_n2_dense": (16, 128, 2, {"DenseOutput_g": True}, SUBSET),
    "w64_k192_n8_dense_rel": (64, 192, 8, {"DenseOutput_g": True, "ReleaseBuffer_g": True, "ReleaseBytes_g": 512},
                              RELEASE),
}


def configure(lib, vectors):
    tb = lib.test_bench("ocr_core_tb")
    made = {}
    for name, (width, bits, keys, extra, tests) in CONFIGS.items():
        key = (bits, keys)
        d = vectors.DIR / "ocr_core" / f"k{bits}_n{keys}"
        if key not in made:
            seed = 100 * keys + bits
            slots = min(keys, 3)
            vectors.gcm_random_set(d / "mixed.txt", bits, 120, seed=seed + 1, max_aad=64, max_data=300, slots=slots,
                                   mode="mixed")
            vectors.gcm_random_set(d / "ivgen.txt", bits, 60, seed=seed + 2, max_aad=48, max_data=200,
                                   slots=min(keys, 2), mode="enc", ivgen=True)
            vectors.core_error_set(d / "errors.txt", bits, keys, seed=seed + 3)
            vectors.zeroized_set(d / "zeroized.txt", bits, 8, seed=seed + 4, slots=slots)
            vectors.ecc_set(d / "ecc.txt", bits, seed=seed + 5)
            vectors.kt_core_ecc_set(d / "kt_ecc.txt", bits, seed=seed + 9)
            vectors.gcm_random_set(d / "tp_enc.txt", bits, 120, seed=seed + 6, max_aad=48, max_data=160,
                                   slots=slots, mode="enc")
            vectors.gcm_random_set(d / "tp_dec.txt", bits, 120, seed=seed + 7, max_aad=48, max_data=160,
                                   slots=slots, mode="dec")
            vectors.series_set(d / "series.txt", bits, 80, seed=seed + 8, slots=slots)
            # Release buffer of 512 bytes: messages of half the buffer and longer
            for rel_name, length, dec in (("rel_enc_half", 240, False), ("rel_enc_long", 400, False),
                                      ("rel_dec_half", 256, True), ("rel_dec_long", 400, True)):
                vectors.fixed_set(d / f"{rel_name}.txt", bits, 12, seed=seed + 10, data_len=length, decrypt=dec)
            # Chunks of a framer: 4 bytes of AAD, generated IVs
            for n in (256, 1024):
                vectors.fixed_set(d / f"chunk_{n}.txt", bits, 16, seed=seed + 11, data_len=n, aad_len=4, ivgen=True)
            made[key] = d
        generics = {"DataWidth_g": width, "KeyBits_g": bits, "NumKeys_g": keys, "VecDir_g": d.as_posix()}
        generics.update(extra)
        for test in tb.get_tests():
            if test.name in tests:
                test.add_config(name=name, generics=generics)
