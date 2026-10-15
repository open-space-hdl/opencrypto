# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Synthesis check of OpenCrypto with GHDL: elaborates and synthesises ocr_core, ocr_framer and the AES engine in
their default configurations and at the bounds of every numeric generic, and checks that every configuration outside
the declared ranges stops the elaboration with its message.

ocr_core: the default configuration (32 bits, AES-256, four key slots), 128 bits with 16 key slots and the release
buffer, 16 bits with AES-128 and one key slot, 64 bits with AES-192, eight key slots, the minimum numbers of AES units
and GHASH digit and 16-bit byte counts, the dense output at 64 and 128 bits (the latter with the release buffer), the
smallest core (16 bits, AES-128, two AES units, 16-bit GHASH digit, release buffer of 16 beats, dense output), the
maximum numbers of AES units and GHASH digit at 32 bits with the dense output, 256 key slots with 8-bit byte counts
and paced scrubbers (1 ms at 100 MHz), and the largest release buffer (65536 bytes). The AES engine with one unit.
ocr_framer: the default configuration (32 bits, chunks of 4096 bytes), 128 bits with chunks of 1024 bytes and a buffer
of four chunks, one key slot and the smallest chunks (16 bytes), 256 key slots and the largest chunks (65536 bytes),
and the largest chunk buffer (64 chunks).

Usage: python lint/synth_check.py [name ...]
Uses the libraries compiled by the regression runner (run `python run.py --compile` first). Names select
configurations; without names all run. Exit code 0 when every configuration synthesises without error and without
inferred latch, and every configuration outside the ranges stops with its expected message.
GHDL 6.0.0 cannot override real generics with -g, so the check synthesises ocr_core through a wrapper generated from
its entity, with the integer generics ClkFreqHz_g (Hz) and ScrubPeriodUs_g (µs) in place of the real generics
ClkFreqHz_g and ScrubPeriod_g.
This is a technology-independent check of synthesizability; resources and timing need the FPGA tools.
"""

import re
import subprocess
import sys
import tempfile
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LIBS = ROOT / "vunit_out" / "ghdl" / "libraries"
CORE = ROOT / "hdl" / "ocr_core" / "src" / "ocr_core.vhd"
WRAPPER = "ocr_core_synth"

# Configurations that must synthesise: (name, top, generics); ocr_core runs through the wrapper
CONFIGS = [
    ("core_default", "ocr_core", {}),
    ("core_w128_n16_rel8192", "ocr_core", {"DataWidth_g": "128", "NumKeys_g": "16", "ReleaseBuffer_g": "true",
                                           "ReleaseBytes_g": "8192"}),
    ("core_w16_k128_n1", "ocr_core", {"DataWidth_g": "16", "KeyBits_g": "128", "NumKeys_g": "1"}),
    ("core_w64_k192_n8_min_len16", "ocr_core", {"DataWidth_g": "64", "KeyBits_g": "192", "NumKeys_g": "8",
                                                "AesUnits_g": "6", "GhashDigit_g": "64", "LenBits_g": "16"}),
    ("core_w64_dense", "ocr_core", {"DataWidth_g": "64", "DenseOutput_g": "true"}),
    ("core_w128_dense_rel4096", "ocr_core", {"DataWidth_g": "128", "DenseOutput_g": "true",
                                             "ReleaseBuffer_g": "true", "ReleaseBytes_g": "4096"}),
    ("core_smallest", "ocr_core", {"DataWidth_g": "16", "KeyBits_g": "128", "AesUnits_g": "2", "GhashDigit_g": "16",
                                   "ReleaseBuffer_g": "true", "ReleaseBytes_g": "32", "DenseOutput_g": "true"}),
    ("core_w32_max_dense", "ocr_core", {"AesUnits_g": "14", "GhashDigit_g": "128", "DenseOutput_g": "true"}),
    ("core_n256_len8_paced", "ocr_core", {"NumKeys_g": "256", "LenBits_g": "8", "ScrubPeriodUs_g": "1000"}),
    ("core_w128_rel65536", "ocr_core", {"DataWidth_g": "128", "ReleaseBuffer_g": "true",
                                        "ReleaseBytes_g": "65536"}),
    ("aes_engine_u1", "ocr_aes_engine", {"KeyBits_g": "128", "Units_g": "1"}),
    ("framer_default", "ocr_framer", {}),
    ("framer_w128_n16_c1024_b4", "ocr_framer", {"DataWidth_g": "128", "NumKeys_g": "16", "ChunkBytes_g": "1024",
                                                "BufferChunks_g": "4"}),
    ("framer_w128_n1_c16", "ocr_framer", {"DataWidth_g": "128", "NumKeys_g": "1", "ChunkBytes_g": "16"}),
    ("framer_w16_n256_c65536", "ocr_framer", {"DataWidth_g": "16", "NumKeys_g": "256", "ChunkBytes_g": "65536"}),
    ("framer_w16_c32_b64", "ocr_framer", {"DataWidth_g": "16", "ChunkBytes_g": "32", "BufferChunks_g": "64"}),
]

# Configurations outside the declared ranges and the message their elaboration stops with
NEGATIVE = [
    ("core_width_24", "ocr_core", {"DataWidth_g": "24"}, "DataWidth_g must be 16, 32, 64 or 128"),
    ("core_key_160", "ocr_core", {"KeyBits_g": "160"}, "KeyBits_g must be 128, 192 or 256"),
    ("core_units_below_min", "ocr_core", {"AesUnits_g": "3"}, "AesUnits_g below ceil(Nr / R)"),
    ("core_units_above_nr", "ocr_core", {"KeyBits_g": "128", "AesUnits_g": "11"},
     "Units_g must not exceed the number of rounds"),
    ("core_digit_below_width", "ocr_core", {"GhashDigit_g": "16"}, "GhashDigit_g below DataWidth_g"),
    ("core_digit_48", "ocr_core", {"DataWidth_g": "16", "GhashDigit_g": "48"}, "Digit_g must be a power of two"),
    ("core_release_3000", "ocr_core", {"ReleaseBuffer_g": "true", "ReleaseBytes_g": "3000"},
     "ReleaseBytes_g must be a power of two from 16 beats to 65536 bytes"),
    ("core_release_8_beats", "ocr_core", {"DataWidth_g": "128", "ReleaseBuffer_g": "true", "ReleaseBytes_g": "128"},
     "ReleaseBytes_g must be a power of two from 16 beats to 65536 bytes"),
    ("core_release_131072", "ocr_core", {"ReleaseBuffer_g": "true", "ReleaseBytes_g": "131072"},
     "ReleaseBytes_g must be a power of two from 16 beats to 65536 bytes"),
    ("core_scrub_500us", "ocr_core", {"ScrubPeriodUs_g": "500"}, "ScrubPeriod_g must be >= 0.001 s"),
    ("core_clk_999_paced", "ocr_core", {"ClkFreqHz_g": "999", "ScrubPeriodUs_g": "1000"},
     "ScrubClkHz_g must be >= 1000.0"),
    ("key_table_160", "ocr_key_table", {"KeyBits_g": "160"}, "ocr_key_table: KeyBits_g must be 128, 192 or 256"),
    ("packer_width_24", "ocr_packer", {"DataWidth_g": "24"}, "ocr_packer: DataWidth_g must be 16, 32, 64 or 128"),
    ("framer_width_24", "ocr_framer", {"DataWidth_g": "24"}, "ocr_framer: DataWidth_g must be 16, 32, 64 or 128"),
    ("framer_chunk_24", "ocr_framer", {"ChunkBytes_g": "24"}, "ocr_framer: ChunkBytes_g must be a multiple of 16"),
    ("framer_chunk_65552", "ocr_framer", {"ChunkBytes_g": "65552"}, "ocr_framer: ChunkBytes_g must not exceed 65536"),
]


def wrapper_source():
    """Entity ocr_core_synth with the generics and ports of ocr_core, the real generics replaced by integers."""
    text = CORE.read_text(encoding="utf-8")
    entity = re.search(r"^entity ocr_core is\n(.*?)^end entity;", text, re.S | re.M).group(1)
    generic_part, port_part = entity.split("    port (", 1)
    generics = re.findall(r"^\s+(\w+_g)\s*:", generic_part, re.M)
    ports = re.findall(r"^\s+(\w+)\s*:\s*(?:in|out)\b", port_part, re.M)
    entity, n_clk = re.subn(r"^(\s+)ClkFreqHz_g(\s*):\s*real\s*:=\s*[0-9.e]+;",
                            r"\1ClkFreqHz_g\2: positive := 100000000;", entity, flags=re.M)
    entity, n_scrub = re.subn(r"^(\s+)ScrubPeriod_g(\s*):\s*real\s*:=\s*[0-9.e]+", r"\1ScrubPeriodUs_g : natural := 0",
                              entity, flags=re.M)
    assert n_clk == 1 and n_scrub == 1, "real generics of ocr_core not found"
    maps = {"ClkFreqHz_g": "ClkFreqHz_g => real(ClkFreqHz_g)",
            "ScrubPeriod_g": "ScrubPeriod_g => real(ScrubPeriodUs_g) * 1.0e-6"}
    return "\n".join([
        "library ieee;",
        "    use ieee.std_logic_1164.all;",
        "    use ieee.numeric_std.all;",
        "library opencrypto;",
        "    use opencrypto.ocr_pkg.all;",
        f"entity {WRAPPER} is",
        entity.rstrip(),
        "end entity;",
        f"architecture rtl of {WRAPPER} is",
        "begin",
        "    i_core : entity opencrypto.ocr_core",
        "        generic map (" + ", ".join(maps.get(g, f"{g} => {g}") for g in generics) + ")",
        "        port map (" + ", ".join(f"{p} => {p}" for p in ports) + ");",
        "end architecture;",
        "",
    ])


def run_synth(top, generics, work, out_file):
    cmd = ["ghdl", "--synth", "--std=08", "-frelaxed", f"-P{LIBS / 'olo'}", f"-P{LIBS / 'opencrypto'}"]
    if top == "ocr_core":
        cmd += ["--work=synth", f"--workdir={work}"]
        top = WRAPPER
    else:
        cmd += ["--work=opencrypto", f"--workdir={LIBS / 'opencrypto'}"]
    cmd += [f"-g{name}={value}" for name, value in generics.items()]
    cmd.append(top)
    with open(out_file, "w") as netlist:
        res = subprocess.run(cmd, stdout=netlist, stderr=subprocess.PIPE, text=True)
    return res.returncode, res.stderr


def synth(name, top, generics, work):
    code, log = run_synth(top, generics, work, work / f"{name}.vhd")
    # Inferred latches are reported as "latch" warnings
    latches = [line for line in log.splitlines() if re.search(r"\blatch\b", line, re.IGNORECASE)]
    errors = [line for line in log.splitlines() if "error" in line.lower() or "exception" in line.lower()]
    ok = code == 0 and not latches and not errors
    print(f"{name}: {'OK' if ok else 'FAILED'}", flush=True)
    for line in (errors + latches)[:20]:
        print("  " + line)
    return ok


def outside(name, top, generics, message, work):
    code, log = run_synth(top, generics, work, work / f"{name}.vhd")
    ok = code != 0 and message in log
    print(f"{name}: {'stopped as expected' if ok else 'FAILED'}", flush=True)
    if not ok:
        for line in log.splitlines()[:20]:
            print("  " + line)
    return ok


def main():
    if not LIBS.exists():
        raise SystemExit("compiled libraries not found, run: python run.py --compile")
    names = set(sys.argv[1:])
    with tempfile.TemporaryDirectory() as tmp:
        work = Path(tmp)
        source = work / f"{WRAPPER}.vhd"
        source.write_bytes(wrapper_source().encode("utf-8"))
        res = subprocess.run(["ghdl", "-a", "--std=08", "-frelaxed", f"-P{LIBS / 'olo'}", f"-P{LIBS / 'opencrypto'}",
                              "--work=synth", f"--workdir={work}", str(source)], capture_output=True, text=True)
        if res.returncode != 0:
            raise SystemExit("wrapper does not analyse:\n" + res.stderr)
        results = [synth(n, t, g, work) for n, t, g in CONFIGS if not names or n in names]
        results += [outside(n, t, g, m, work) for n, t, g, m in NEGATIVE if not names or n in names]
    sys.exit(0 if all(results) else 1)


if __name__ == "__main__":
    main()
