"""Check that the wall kernels are the same generated code in every SweepgenLdcCPU variant.

Usage: python check_walls.py <generated SweepgenLdcCPU.cpp> ...

From each file it extracts the wall kernel namespaces (NoSlip_kernels, UBB_kernels for the pull
pattern; NoSlipEven_kernels, UBBEven_kernels, NoSlipOdd_kernels, UBBOdd_kernels for AA) and
compares them across the files of the same streaming pattern. PASS if each kernel is
byte-identical in all files that contain it (exit status 1 otherwise).
"""

import hashlib
import re
import sys

KERNELS = ["NoSlip", "UBB", "NoSlipEven", "UBBEven", "NoSlipOdd", "UBBOdd"]


def extract(text, name):
    m = re.search(rf"^namespace {name}_kernels \{{\n(.*?)^\}} // namespace {name}_kernels$", text, re.S | re.M)
    return m.group(1) if m else None


def main(paths):
    ok = True
    for name in KERNELS:
        found = {}
        for p in paths:
            code = extract(open(p).read(), name)
            if code is not None:
                found[p] = hashlib.sha256(code.encode()).hexdigest()[:16]
        if not found:
            continue
        distinct = set(found.values())
        same = len(distinct) == 1
        ok &= same
        print(("PASS" if same else "FAIL") + f" {name}_kernels: {len(found)} files, {len(distinct)} distinct version(s)"
              + "".join(f"\n     {h} {p}" for p, h in found.items()) if not same else
              ("PASS" if same else "FAIL") + f" {name}_kernels: identical in {len(found)} files (sha256 {distinct.pop()})")
    print("CHECK_WALLS", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
