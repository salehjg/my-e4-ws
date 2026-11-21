"""Compare SweepgenLdcCPU field dumps cell by cell (copied from scripts/presentation6; used by monte3.sh).

A dump is what the app writes with SWEEPGEN_LDC_DUMP=<prefix>: one file <prefix>.rank<r>.bin per
MPI process. A reference is the .npz of ldc_reference.py. Every input is assembled into global
arrays rho (NX, NY, NZ) and u (3, NX, NY, NZ).

Usage:
  python compare_fields.py BASE OTHER [OTHER ...] [--tol 1e-12] [--inv-tol 1e-12] [--calibrate F]
    BASE and each OTHER: a dump prefix or a reference .npz. Each OTHER is compared with BASE.
  python compare_fields.py --check PREFIX [...] [--inv-tol 1e-12]
    invariants of the inputs only (mass, z-mirror symmetry, subnormals, finiteness)

Thresholds: --tol for the differences to BASE, --inv-tol for mass_err and sym_err. With
--calibrate F (used for single precision against the double-precision reference), the thresholds
are F times the values of the first OTHER input (the scalar build), each at least 4 machine
epsilons of the dumped precision: every other build may be at most F times less accurate than the
scalar build.

For every input it reports:
  mass_err   |sum(rho) - NX*NY*NZ| / (NX*NY*NZ)       (mass is conserved by the walls)
  sym_err    max |field(x, y, z) - mirror(field)(x, y, NZ-1-z)|, with u_z changing sign
             (the cavity is symmetric about the plane z = (NZ-1)/2)
  subnormal  number of subnormal values in rho and u
and for every OTHER against BASE: max |d rho|, max |d u| and the number of bit-identical cells.
Exit status 1 if any number exceeds its threshold, any value is not finite, or the domains differ.
"""

import argparse
import glob
import struct
import sys

import numpy as np

REC = np.dtype([("x", "<i4"), ("y", "<i4"), ("z", "<i4"), ("v", "<f8", (4,))])


def load_dump(prefix):
    files = sorted(glob.glob(prefix + ".rank*.bin"))
    if not files:
        raise FileNotFoundError(f"no dump files {prefix}.rank*.bin")
    recs, real_bytes = [], set()
    for f in files:
        with open(f, "rb") as fh:
            head = fh.read(24)
            magic, rb, _pad, n = head[:8], *struct.unpack("<IIQ", head[8:])
            if magic != b"LDCDUMP1":
                raise ValueError(f"{f}: not an LDC dump")
            real_bytes.add(rb)
            r = np.frombuffer(fh.read(), dtype=REC)
            if len(r) != n:
                raise ValueError(f"{f}: {len(r)} records, header says {n}")
            recs.append(r)
    r = np.concatenate(recs)
    shape = (r["x"].max() + 1, r["y"].max() + 1, r["z"].max() + 1)
    if r["x"].min() != 0 or r["y"].min() != 0 or r["z"].min() != 0 or len(r) != np.prod(shape):
        raise ValueError(f"{prefix}: cells do not form a box starting at 0")
    rho = np.full(shape, np.nan)
    u = np.full((3,) + shape, np.nan)
    rho[r["x"], r["y"], r["z"]] = r["v"][:, 0]
    for k in range(3):
        u[k, r["x"], r["y"], r["z"]] = r["v"][:, k + 1]
    count = np.zeros(shape, dtype=int)
    np.add.at(count, (r["x"], r["y"], r["z"]), 1)
    if (count != 1).any():
        raise ValueError(f"{prefix}: some cells appear {count.max()} times or not at all")
    return rho, u, f"f{8 * real_bytes.pop()}" if len(real_bytes) == 1 else "mixed"


def load(path):
    if path.endswith(".npz"):
        d = np.load(path)
        return d["rho"], d["u"], "ref-f64"
    return load_dump(path)


def subnormals(a, kind):
    tiny = np.finfo(np.float32 if kind == "f32" else np.float64).tiny
    return int(((a != 0) & (np.abs(a) < tiny)).sum())


def invariants(rho, u, kind):
    n = rho.size
    mass_err = abs(rho.sum() - n) / n
    rho_m = rho[:, :, ::-1]
    u_m = u[:, :, :, ::-1].copy()
    u_m[2] = -u_m[2]
    sym_err = max(np.abs(rho - rho_m).max(), np.abs(u - u_m).max())
    sub = subnormals(rho, kind) + subnormals(u, kind)
    finite = bool(np.isfinite(rho).all() and np.isfinite(u).all())
    return mass_err, sym_err, sub, finite


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("inputs", nargs="+")
    p.add_argument("--check", action="store_true", help="invariants of the inputs only")
    p.add_argument("--tol", type=float, default=1e-12, help="threshold for max |d rho|, max |d u|")
    p.add_argument("--inv-tol", type=float, default=1e-12, help="threshold for mass_err, sym_err")
    p.add_argument("--calibrate", type=float, default=None, metavar="F",
                   help="thresholds = F x the first OTHER input's values")
    p.add_argument("--label-width", type=int, default=40)
    a = p.parse_args(argv)

    loaded = [(path, *load(path)) for path in a.inputs]
    inv = [invariants(rho, u, kind) for _, rho, u, kind in loaded]
    diffs = []
    if not a.check and len(loaded) > 1:
        _, rho0, u0, _ = loaded[0]
        for _, rho, u, _ in loaded[1:]:
            if rho.shape != rho0.shape:
                diffs.append(None)
                continue
            diffs.append((np.abs(rho - rho0).max(), np.abs(u - u0).max(),
                          int(((rho == rho0) & (u == u0).all(axis=0)).sum())))

    tol_rho = tol_u = a.tol
    tol_mass = tol_sym = a.inv_tol
    if a.calibrate is not None:
        if a.check or len(loaded) < 2 or diffs[0] is None:
            sys.exit("--calibrate needs BASE and at least one OTHER with the same domain")
        kind = loaded[1][3]
        floor = 4 * float(np.finfo(np.float32 if kind == "f32" else np.float64).eps)
        f = a.calibrate
        tol_rho, tol_u = (max(f * diffs[0][0], floor), max(f * diffs[0][1], floor))
        tol_mass, tol_sym = (max(f * inv[1][0], floor), max(f * inv[1][1], floor))
        print(f"calibrated on {loaded[1][0]} (x{f:g}, floor {floor:.2e}): "
              f"rho {tol_rho:.2e}, u {tol_u:.2e}, mass {tol_mass:.2e}, sym {tol_sym:.2e}\n")

    ok = True
    w = a.label_width
    print(f"{'input':<{w}} {'type':>7} {'domain':>12} {'mass_err':>10} {'sym_err':>10} {'subnorm':>7}")
    for (path, rho, u, kind), (mass_err, sym_err, sub, finite) in zip(loaded, inv):
        bad = (not finite) or mass_err > tol_mass or sym_err > tol_sym
        ok &= not bad
        dom = "x".join(map(str, rho.shape))
        print(f"{path[-w:]:<{w}} {kind:>7} {dom:>12} {mass_err:10.2e} {sym_err:10.2e} {sub:7d}"
              + ("  FAIL" if bad else ""))

    if diffs:
        print(f"\nagainst {loaded[0][0]}:")
        print(f"{'input':<{w}} {'max|drho|':>10} {'max|du|':>10} {'identical cells':>16}")
        for (path, rho, u, kind), d in zip(loaded[1:], diffs):
            if d is None:
                print(f"{path[-w:]:<{w}} domain {rho.shape} != {loaded[0][1].shape}  FAIL")
                ok = False
                continue
            drho, du, same = d
            bad = not (drho <= tol_rho and du <= tol_u)
            ok &= not bad
            print(f"{path[-w:]:<{w}} {drho:10.2e} {du:10.2e} {same:9d}/{rho.size:<6d}" + ("  FAIL" if bad else ""))
    print(f"\nRESULT {'PASS' if ok else 'FAIL'} (thresholds: d rho {tol_rho:g}, d u {tol_u:g}, "
          f"mass {tol_mass:g}, sym {tol_sym:g})")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
