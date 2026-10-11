# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""VUnit configuration of the ocr_pkg testbench: vectors of pycryptodome and of the standards."""


def configure(lib, vectors):
    d = vectors.DIR / "ocr_pkg"
    ecb = vectors.ecb_set(d / "ecb.txt", [128, 192, 256], 50, seed=1)
    gcm = d / "gcm_spec.txt"
    # The GCM test cases of all key lengths in one file (key slots 0 to 5)
    files = [vectors.gcm_spec_set(d / f"gcm_spec_{bits}.txt", bits) for bits in (128, 192, 256)]
    lines, slot_base = [], 0
    for f in files:
        part = f.read_text().splitlines()
        slots = 0
        for line in part:
            tok = line.split()
            if tok and tok[0] in ("KEY", "MSG"):
                idx = 1 if tok[0] == "KEY" else 2
                tok[idx] = str(int(tok[idx]) + slot_base)
                if tok[0] == "KEY":
                    slots += 1
                line = " ".join(tok)
            lines.append(line)
        slot_base += slots
    gcm.write_text("\n".join(lines) + "\n", encoding="ascii", newline="\n")
    tb = lib.test_bench("ocr_pkg_tb")
    tb.set_generic("VecEcb_g", ecb.as_posix())
    tb.set_generic("VecGcm_g", gcm.as_posix())
