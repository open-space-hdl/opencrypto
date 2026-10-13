# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Synthesis check of OpenCrypto with GHDL: elaborates ocr_core in the default configuration (32 bits, AES-256, four
key slots), at 128 bits with 16 key slots and the release buffer, at 16 bits with AES-128 and one key slot, at 64 bits
with AES-192, eight key slots, the minimum numbers of AES units and GHASH digit and 16-bit byte counts, and with the
dense output at 64 and 128 bits (the latter with the release buffer); and ocr_framer in its default configuration
(32 bits, chunks of 4096 bytes) and at 128 bits with chunks of 1024 bytes and a buffer of four chunks.

Usage: python lint/synth_check.py
Uses the libraries compiled by the regression runner (run `python run.py --compile` first).
Exit code 0 when every configuration synthesizes without error and without inferred latch.
This is a technology-independent check of synthesizability; resources and timing need the FPGA tools.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIBS = ROOT / "vunit_out" / "ghdl" / "libraries"
CONFIGS = [("ocr_core", {}),
           ("ocr_core", {"DataWidth_g": "128", "NumKeys_g": "16", "ReleaseBuffer_g": "true",
                         "ReleaseBytes_g": "8192"}),
           ("ocr_core", {"DataWidth_g": "16", "KeyBits_g": "128", "NumKeys_g": "1"}),
           ("ocr_core", {"DataWidth_g": "64", "KeyBits_g": "192", "NumKeys_g": "8", "AesUnits_g": "6",
                         "GhashDigit_g": "64", "LenBits_g": "16"}),
           ("ocr_core", {"DataWidth_g": "64", "DenseOutput_g": "true"}),
           ("ocr_core", {"DataWidth_g": "128", "DenseOutput_g": "true", "ReleaseBuffer_g": "true",
                         "ReleaseBytes_g": "4096"}),
           ("ocr_framer", {}),
           ("ocr_framer", {"DataWidth_g": "128", "NumKeys_g": "16", "ChunkBytes_g": "1024",
                           "BufferChunks_g": "4"})]


def synth(top, generics, out_dir):
    cmd = ["ghdl", "--synth", "--std=08", "-frelaxed", f"-P{LIBS / 'olo'}", "--work=opencrypto",
           f"--workdir={LIBS / 'opencrypto'}"]
    cmd += [f"-g{name}={value}" for name, value in generics.items()]
    cmd.append(top)
    name = top + "".join(f"_{k[:-2]}{v}" for k, v in generics.items() if len(v) < 8)
    with open(out_dir / f"{name}.vhd", "w") as netlist:
        res = subprocess.run(cmd, stdout=netlist, stderr=subprocess.PIPE, text=True)
    log = res.stderr
    # Inferred latches are reported as "latch" warnings
    latches = [line for line in log.splitlines() if re.search(r"\blatch\b", line, re.IGNORECASE)]
    errors = [line for line in log.splitlines() if "error" in line.lower() or "exception" in line.lower()]
    ok = res.returncode == 0 and not latches and not errors
    print(f"{name}: {'OK' if ok else 'FAILED'}")
    for line in (errors + latches)[:20]:
        print("  " + line)
    return ok


def main():
    if not LIBS.exists():
        raise SystemExit("compiled libraries not found, run: python run.py --compile")
    with tempfile.TemporaryDirectory() as tmp:
        results = [synth(top, gen, Path(tmp)) for top, gen in CONFIGS]
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
