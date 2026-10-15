# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configurations of the ocr_framer testbench: the framer alone at every data width and chunk sizes from
the minimum of 16 bytes to the default of 4096 bytes, and the framer with ocr_core (dense output) against
pycryptodome."""

import random

ALONE = ["test_chunks", "test_backpressure", "test_throughput", "test_ecc", "test_reset"]
CORE = ["test_encrypt", "test_ecc_core", "test_throughput_core"]

# name: (data width, chunk bytes, buffer chunks, key bits, with core, tests)
CONFIGS = {
    "w32_c64": (32, 64, 2, 256, False, ALONE),
    "w16_c32": (16, 32, 2, 256, False, ALONE),
    "w64_c128_b3": (64, 128, 3, 256, False, ALONE),
    "w128_c256_b4": (128, 256, 4, 256, False, ALONE),
    "w32_c4096": (32, 4096, 2, 256, False, ["test_chunks", "test_throughput"]),
    "w128_c16": (128, 16, 2, 256, False, ALONE),
    "w32_c64_core": (32, 64, 2, 256, True, CORE),
    "w16_c32_core": (16, 32, 2, 128, True, CORE),
    "w64_c1024_core": (64, 1024, 2, 256, True, CORE),
    "w128_c256_core": (128, 256, 2, 256, True, CORE),
    "w128_c4096_core": (128, 4096, 2, 256, True, ["test_throughput_core"]),
}


def vector_sets(vectors, d, chunk, bits, core, seed):
    """Vector files of one chunk size, key length and mode in the directory d."""
    rng = random.Random(seed)
    lengths = vectors.image_lengths(rng, chunk, 30)
    if core:
        vectors.framer_set(d / "enc_core.txt", bits, chunk, lengths, seed=seed + 1, core=True)
        ecc_lengths = [rng.randint(1, chunk) for _ in range(12)]
        vectors.framer_set(d / "ecc_core.txt", bits, chunk, ecc_lengths, seed=seed + 2, core=True,
                           poisoned={m for m in range(12) if m % 4 in (1, 3)})
        vectors.framer_set(d / "tp_core.txt", bits, chunk, [8 * chunk + 5, 5 * chunk, 3 * chunk + 1, 2 * chunk],
                           seed=seed + 3, core=True)
    else:
        vectors.framer_set(d / "chunks.txt", bits, chunk, lengths, seed=seed + 1, core=False)
        vectors.framer_set(d / "long.txt", bits, chunk, [8 * chunk + 5, 5 * chunk, 3 * chunk + 1, 2 * chunk],
                           seed=seed + 3, core=False)
        ecc_lengths = [chunk, 5, chunk - 1, 1] + [rng.randint(1, chunk) for _ in range(8)]
        vectors.framer_set(d / "ecc.txt", bits, chunk, ecc_lengths, seed=seed + 2, core=False,
                           poisoned={m for m in range(12) if m % 4 in (1, 3)})


def configure(lib, vectors):
    tb = lib.test_bench("ocr_framer_tb")
    for name, (width, chunk, bufs, bits, core, tests) in CONFIGS.items():
        d = vectors.DIR / "ocr_framer" / name
        vector_sets(vectors, d, chunk, bits, core, seed=700 + 10 * width + chunk + bits)
        generics = {"DataWidth_g": width, "KeyBits_g": bits, "NumKeys_g": 4, "ChunkBytes_g": chunk,
                    "BufferChunks_g": bufs, "Core_g": core, "VecDir_g": d.as_posix()}
        for test in tb.get_tests():
            if test.name in tests:
                test.add_config(name=name, generics=generics)
