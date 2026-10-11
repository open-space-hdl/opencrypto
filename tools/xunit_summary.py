# ---------------------------------------------------------------------------------------------------
# Copyright (c) 2026 by Julian Schneider
# Authors: Julian Schneider
# ---------------------------------------------------------------------------------------------------
"""Summary of a VUnit xunit result file: passed, failed and skipped tests, the failed ones by name.

Usage: python tools/xunit_summary.py results.xml [--times]
"""

import sys
import xml.etree.ElementTree as ET


def main():
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    root = ET.parse(sys.argv[1]).getroot()
    cases = root.iter("testcase")
    passed, failed, skipped, total_time = [], [], [], 0.0
    for case in cases:
        name = case.get("classname", "") + "." + case.get("name", "")
        total_time += float(case.get("time", 0))
        if case.find("failure") is not None or case.find("error") is not None:
            failed.append(name)
        elif case.find("skipped") is not None:
            skipped.append(name)
        else:
            passed.append((name, float(case.get("time", 0))))
    print(f"passed {len(passed)}, failed {len(failed)}, skipped {len(skipped)}, simulation time {total_time:.0f} s")
    for name in failed:
        print(f"FAILED {name}")
    if "--times" in sys.argv:
        for name, t in sorted(passed, key=lambda p: -p[1])[:15]:
            print(f"{t:8.1f} s  {name}")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main())
