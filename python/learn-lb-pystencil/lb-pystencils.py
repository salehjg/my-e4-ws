"""
Lattice Boltzmann Method — Lid-Driven Cavity, D2Q9 BGK

Target: local pystencils source checkout at ../../submodules/pystencils
relative to this script file.

Important change vs. previous version:
* This version avoids pystencils indexed fields like f(9): double[2D].
  Instead, each D2Q9 population is a separate scalar 2D field f0 ... f8.
  This removes any ambiguity about where the PDF/index dimension is stored in
  memory in pystencils >= 2 source builds.
"""

from pathlib import Path
import argparse
import sys
import time

# ── Import local pystencils source tree ─────────────────────────────────────
_THIS_FILE = Path(__file__).resolve()
_LOCAL_PYSTENCILS = (_THIS_FILE.parent / "../../submodules/pystencils").resolve()
_LOCAL_PYSTENCILS_SRC = _LOCAL_PYSTENCILS / "src"

if _LOCAL_PYSTENCILS_SRC.exists():
    sys.path.insert(0, str(_LOCAL_PYSTENCILS_SRC))
else:
    raise ImportError(
        "Could not find local pystencils source checkout at "
        f"{_LOCAL_PYSTENCILS_SRC}. Expected path relative to this script: "
        "../../submodules/pystencils/src"
    )

import numpy as np
import sympy as sp
import pystencils as ps

#   matplotlib is imported lazily inside the plotting path so that headless board
#   runs (`--no-plot`) do not require it.

print(f"Using pystencils from: {Path(ps.__file__).resolve()}")

# ── Grid & physical parameters ─────────────────────────────────────────────
NX, NY = 100, 100
U_LID = 0.1
RE = 100
NU = U_LID * NX / RE
TAU = 3.0 * NU + 0.5
OMEGA = 1.0 / TAU
N_STEPS = 5000
OUTPUT = str(_THIS_FILE.parent / "lbm_result_pystencils_scalar_fields.png")
COMPARE_WITH_NUMPY = True
COMPARE_STEPS = None

# ── Code generation configuration (set from CLI in main) ────────────────────
# Controls the target/mode used by all generated kernels. Defaults reproduce the
# original behaviour (a generic scalar CPU kernel).
_CFG_OPTS = {
    "target": "generic",  # "generic" | "rvv"
    "mode": "fixed",       # RVV only: "fixed" (VLS) | "vla" (stripmine)
    "vlen": 256,           # RVV assumed/floor VLEN in bits
    "lanes": None,         # RVV VLS lane count (defaults to VLEN/64 for f64)
}


def make_config(iteration_slice=None):
    """Build a `CreateKernelConfig` for the configured target/mode."""
    cfg = ps.CreateKernelConfig()
    if iteration_slice is not None:
        cfg.iteration_slice = iteration_slice

    if _CFG_OPTS["target"] == "rvv":
        cfg.target = ps.Target.RISCV_RVV
        cfg.cpu.vectorize.enable = True
        cfg.cpu.vectorize.assume_inner_stride_one = True
        cfg.cpu.vectorize.mode = _CFG_OPTS["mode"]
        cfg.cpu.rvv.vlen = _CFG_OPTS["vlen"]
        if _CFG_OPTS["mode"] == "fixed":
            lanes = _CFG_OPTS["lanes"] or (_CFG_OPTS["vlen"] // 64)  # f64 -> LMUL=1
            cfg.cpu.vectorize.lanes = lanes
    return cfg


# Direction index: 0 rest, 1 E, 2 N, 3 W, 4 S, 5 NE, 6 NW, 7 SW, 8 SE
C = np.array([
    [0, 0],
    [1, 0],
    [0, 1],
    [-1, 0],
    [0, -1],
    [1, 1],
    [-1, 1],
    [-1, -1],
    [1, -1],
], dtype=np.int32)
W = np.array([4 / 9, 1 / 9, 1 / 9, 1 / 9, 1 / 9, 1 / 36, 1 / 36, 1 / 36, 1 / 36], dtype=np.float64)
Q = 9
OPPOSITE = [0, 3, 4, 1, 2, 7, 8, 5, 6]


def make_equilibrium(rho, ux, uy):
    """Return list [f0, ..., f8], each with shape (NX, NY)."""
    u_sq = ux * ux + uy * uy
    f = []
    for i, (cx, cy) in enumerate(C):
        cu = cx * ux + cy * uy
        f.append(W[i] * rho * (1.0 + 3.0 * cu + 4.5 * cu * cu - 1.5 * u_sq))
    return f


def build_pull_collide_kernel():
    """BGK collision kernel (streaming handled separately)."""
    fields = ps.fields(
        "f0, f1, f2, f3, f4, f5, f6, f7, f8, "
        "g0, g1, g2, g3, g4, g5, g6, g7, g8: double[2D]"
    )
    f = fields[:Q]
    g = fields[Q:]
    omega = sp.Symbol("omega")

    p = [f[i][0, 0] for i in range(Q)]
    rho = sum(p)
    ux = (p[1] - p[3] + p[5] - p[6] - p[7] + p[8]) / rho
    uy = (p[2] - p[4] + p[5] + p[6] - p[7] - p[8]) / rho
    u_sq = ux * ux + uy * uy

    assignments = []
    for i, (cx, cy) in enumerate(C):
        cu = float(cx) * ux + float(cy) * uy
        feq = float(W[i]) * rho * (1.0 + 3.0 * cu + 4.5 * cu * cu - 1.5 * u_sq)
        assignments.append(ps.Assignment(g[i][0, 0], p[i] - omega * (p[i] - feq)))

    return ps.create_kernel(assignments, config=make_config()).compile()


def build_stream_kernel():
    """Pull-streaming kernel from g -> f over interior cells (directions 0..8)."""
    fields = ps.fields(
        "f0, f1, f2, f3, f4, f5, f6, f7, f8, "
        "g0, g1, g2, g3, g4, g5, g6, g7, g8: double[2D]"
    )
    f = fields[:Q]
    g = fields[Q:]

    assignments = []
    for i, (cx, cy) in enumerate(C):
        assignments.append(ps.Assignment(f[i][0, 0], g[i][-int(cx), -int(cy)]))

    interior = (slice(1, -1), slice(1, -1))
    return ps.create_kernel(assignments, config=make_config(interior)).compile()


def build_boundary_stream_kernel(iteration_slice):
    """Pull-streaming kernel from g -> f over a boundary slice (directions 0..8)."""
    fields = ps.fields(
        "f0, f1, f2, f3, f4, f5, f6, f7, f8, "
        "g0, g1, g2, g3, g4, g5, g6, g7, g8: double[2D]"
    )
    f = fields[:Q]
    g = fields[Q:]

    assignments = []
    for i, (cx, cy) in enumerate(C):
        assignments.append(ps.Assignment(f[i][0, 0], g[i][-int(cx), -int(cy)]))

    return ps.create_kernel(
        assignments, config=make_config(iteration_slice)
    ).compile()



def build_macro_kernel():
    fields = ps.fields("f0, f1, f2, f3, f4, f5, f6, f7, f8, rho, ux, uy: double[2D]")
    f = fields[:Q]
    rho_f, ux_f, uy_f = fields[Q:]

    rho_expr = sum(fi[0, 0] for fi in f)
    ux_expr = (f[1][0, 0] - f[3][0, 0] + f[5][0, 0] - f[6][0, 0] - f[7][0, 0] + f[8][0, 0]) / rho_expr
    uy_expr = (f[2][0, 0] - f[4][0, 0] + f[5][0, 0] + f[6][0, 0] - f[7][0, 0] - f[8][0, 0]) / rho_expr

    assignments = [
        ps.Assignment(rho_f[0, 0], rho_expr),
        ps.Assignment(ux_f[0, 0], ux_expr),
        ps.Assignment(uy_f[0, 0], uy_expr),
    ]
    #   The macro kernel writes to boundary cells too; keep it scalar (generic) to
    #   avoid the boundary/stride assumptions of the vector backends.
    return ps.create_kernel(assignments, config=ps.CreateKernelConfig()).compile()


def kernel_args(prefix, arrays):
    return {f"{prefix}{i}": arrays[i] for i in range(Q)}


def apply_bounce_back_boundaries(f):
    """Boundary updates on list [f0, ..., f8], each shape (NX, NY)."""
    # Bounce-back on bottom, left, right walls.
    for i in range(Q):
        op = OPPOSITE[i]
        f[i][0, :] = f[op][0, :]
        f[i][-1, :] = f[op][-1, :]
        f[i][:, 0] = f[op][:, 0]

    # Moving top lid, y = NY - 1 (Zou-He velocity BC).
    y = -1
    rho_lid = (
        f[0][:, y] + f[1][:, y] + f[3][:, y] + 2.0 * (f[2][:, y] + f[5][:, y] + f[6][:, y])
    ) / (1.0 + U_LID)

    f[4][:, y] = f[2][:, y] - (2.0 / 3.0) * rho_lid * U_LID
    f[7][:, y] = f[5][:, y] - (1.0 / 6.0) * rho_lid * U_LID + 0.5 * (f[1][:, y] - f[3][:, y])
    f[8][:, y] = f[6][:, y] + (1.0 / 6.0) * rho_lid * U_LID - 0.5 * (f[1][:, y] - f[3][:, y])


def copy_all(dst, src):
    for d, s in zip(dst, src):
        d[...] = s


def swap_lists(a, b):
    return b, a


def run_numpy_reference(steps, nx, ny, u_lid, tau):
    """Reference LBM using NumPy roll + Zou-He lid for comparison."""
    rho = np.ones((nx, ny), dtype=np.float64)
    ux = np.zeros((nx, ny), dtype=np.float64)
    uy = np.zeros((nx, ny), dtype=np.float64)

    f = make_equilibrium(rho, ux, uy)
    f = np.stack(f, axis=0)

    for _ in range(steps):
        rho = f.sum(axis=0)
        ux = np.einsum("i,ixy->xy", C[:, 0], f) / rho
        uy = np.einsum("i,ixy->xy", C[:, 1], f) / rho

        u_sq = ux * ux + uy * uy
        f_eq = np.empty_like(f)
        for i, (cx, cy) in enumerate(C):
            cu = cx * ux + cy * uy
            f_eq[i] = W[i] * rho * (1.0 + 3.0 * cu + 4.5 * cu * cu - 1.5 * u_sq)

        f += -(f - f_eq) / tau

        for i, (cx, cy) in enumerate(C):
            f[i] = np.roll(f[i], shift=int(cx), axis=0)
            f[i] = np.roll(f[i], shift=int(cy), axis=1)

        for i in range(Q):
            op = OPPOSITE[i]
            f[i, 0, :] = f[op, 0, :]
            f[i, -1, :] = f[op, -1, :]
            f[i, :, 0] = f[op, :, 0]

        y = ny - 1
        rho_lid = (
            f[0, :, y] + f[1, :, y] + f[3, :, y] + 2.0 * (f[2, :, y] + f[5, :, y] + f[6, :, y])
        ) / (1.0 + u_lid)
        f[4, :, y] = f[2, :, y] - (2.0 / 3.0) * rho_lid * u_lid
        f[7, :, y] = f[5, :, y] - (1.0 / 6.0) * rho_lid * u_lid + 0.5 * (f[1, :, y] - f[3, :, y])
        f[8, :, y] = f[6, :, y] + (1.0 / 6.0) * rho_lid * u_lid - 0.5 * (f[1, :, y] - f[3, :, y])

    rho = f.sum(axis=0)
    ux = np.einsum("i,ixy->xy", C[:, 0], f) / rho
    uy = np.einsum("i,ixy->xy", C[:, 1], f) / rho
    return rho, ux, uy


def macroscopic_from_f_list(f_list):
    """Compute macroscopic fields from a list of f arrays using NumPy."""
    f_stack = np.stack(f_list, axis=0)
    rho = f_stack.sum(axis=0)
    ux = np.einsum("i,ixy->xy", C[:, 0], f_stack) / rho
    uy = np.einsum("i,ixy->xy", C[:, 1], f_stack) / rho
    return rho, ux, uy


def parse_args(argv=None):
    p = argparse.ArgumentParser(description="D2Q9 BGK lid-driven cavity (pystencils)")
    p.add_argument("--target", choices=["generic", "rvv"], default="generic",
                   help="Code generation target for the collide/stream kernels.")
    p.add_argument("--mode", choices=["fixed", "vla"], default="fixed",
                   help="RVV vectorization mode: fixed (VLS) or vla (stripmine).")
    p.add_argument("--vlen", type=int, default=256,
                   help="RVV assumed (VLS) / floor (VLA) VLEN in bits.")
    p.add_argument("--lanes", type=int, default=None,
                   help="RVV VLS lane count (default VLEN/64 -> LMUL=1 for f64).")
    p.add_argument("--nx", type=int, default=NX)
    p.add_argument("--ny", type=int, default=NY)
    p.add_argument("--steps", type=int, default=N_STEPS)
    p.add_argument("--no-plot", action="store_true",
                   help="Skip matplotlib output (for headless / board runs).")
    p.add_argument("--no-compare", action="store_true",
                   help="Skip the NumPy reference comparison.")
    return p.parse_args(argv)


def main(argv=None):
    global NX, NY, NU, TAU, OMEGA, N_STEPS

    args = parse_args(argv)
    NX, NY = args.nx, args.ny
    NU = U_LID * NX / RE
    TAU = 3.0 * NU + 0.5
    OMEGA = 1.0 / TAU
    N_STEPS = args.steps
    _CFG_OPTS.update(
        target=args.target, mode=args.mode, vlen=args.vlen, lanes=args.lanes
    )

    print(f"target={args.target} mode={args.mode} vlen={args.vlen} lanes={args.lanes}")
    print(f"NX={NX}, NY={NY}, Re={RE}, nu={NU:.6g}, tau={TAU:.6g}, omega={OMEGA:.6g}")

    rho = np.ones((NX, NY), dtype=np.float64)
    ux = np.zeros((NX, NY), dtype=np.float64)
    uy = np.zeros((NX, NY), dtype=np.float64)

    f = make_equilibrium(rho, ux, uy)
    g = [fi.copy() for fi in f]

    collide_stream = build_pull_collide_kernel()
    macro = build_macro_kernel()
    stream = build_stream_kernel()
    top_stream = build_boundary_stream_kernel((slice(None), slice(-1, None)))
    bottom_stream = build_boundary_stream_kernel((slice(None), slice(0, 1)))
    left_stream = build_boundary_stream_kernel((slice(0, 1), slice(None)))
    right_stream = build_boundary_stream_kernel((slice(-1, None), slice(None)))

    t_start = time.perf_counter()
    for step in range(N_STEPS):
        kargs = {}
        kargs.update(kernel_args("f", f))
        kargs.update(kernel_args("g", g))
        kargs["omega"] = OMEGA
        collide_stream(**kargs)

        # Streaming: pull neighbor PDFs into each interior cell.
        stream_args = {}
        stream_args.update(kernel_args("f", f))
        stream_args.update(kernel_args("g", g))
        stream(**stream_args)
        top_stream(**stream_args)
        bottom_stream(**stream_args)
        left_stream(**stream_args)
        right_stream(**stream_args)

        apply_bounce_back_boundaries(f)

        if (step + 1) % 1000 == 0:
            macro_args = kernel_args("f", f)
            macro_args.update({"rho": rho, "ux": ux, "uy": uy})
            macro(**macro_args)
            speed = np.sqrt(ux * ux + uy * uy)
            print(
                f"step {step + 1}/{N_STEPS}: "
                f"rho=[{np.nanmin(rho):.6g}, {np.nanmax(rho):.6g}], "
                f"speed max={np.nanmax(speed):.6g}, finite={np.isfinite(speed).all()}"
            )

    elapsed = time.perf_counter() - t_start
    if elapsed > 0 and N_STEPS > 0:
        mlups = (NX * NY * N_STEPS) / elapsed / 1e6
        print(
            f"timing: {N_STEPS} steps in {elapsed:.3f} s "
            f"-> {mlups:.2f} MLUP/s ({NX}x{NY} grid)"
        )

    macro_args = kernel_args("f", f)
    macro_args.update({"rho": rho, "ux": ux, "uy": uy})
    macro(**macro_args)

    # Known wall velocities for visualization.
    ux[:, 0] = 0.0
    uy[:, 0] = 0.0
    ux[0, :] = 0.0
    uy[0, :] = 0.0
    ux[-1, :] = 0.0
    uy[-1, :] = 0.0
    ux[:, -1] = U_LID
    uy[:, -1] = 0.0

    speed = np.sqrt(ux * ux + uy * uy)
    speed = np.nan_to_num(speed, nan=0.0, posinf=0.0, neginf=0.0)
    print(
        f"final: rho=[{np.nanmin(rho):.6g}, {np.nanmax(rho):.6g}], "
        f"speed=[{np.nanmin(speed):.6g}, {np.nanmax(speed):.6g}], "
        f"finite={np.isfinite(speed).all()}"
    )

    if args.no_plot:
        return _numpy_compare(f, args)

    import matplotlib.pyplot as plt

    fig, axes = plt.subplots(1, 2, figsize=(12, 5), constrained_layout=True)
    fig.suptitle(f"Lid-Driven Cavity  (Re={RE}, {NX}×{NY}, {N_STEPS} steps)", fontsize=13)

    im = axes[0].imshow(
        speed.T,
        origin="lower",
        cmap="viridis",
        interpolation="nearest",
        vmin=0.0,
        vmax=U_LID,
    )
    axes[0].set_title("Speed |u|")
    axes[0].set_xlabel("x")
    axes[0].set_ylabel("y")
    axes[0].set_xlim(0, NX - 1)
    axes[0].set_ylim(0, NY - 1)
    axes[0].set_aspect("equal")
    fig.colorbar(im, ax=axes[0])

    x = np.arange(NX)
    y = np.arange(NY)
    axes[1].streamplot(x, y, ux.T, uy.T, color=speed.T, cmap="plasma", density=1.5, linewidth=0.8)
    axes[1].set_title("Streamlines")
    axes[1].set_xlabel("x")
    axes[1].set_ylabel("y")
    axes[1].set_xlim(0, NX - 1)
    axes[1].set_ylim(0, NY - 1)
    axes[1].set_aspect("equal")

    plt.savefig(OUTPUT, dpi=150)
    plt.show()
    print(f"Done! Saved {OUTPUT}")

    return _numpy_compare(f, args)


def _numpy_compare(f, args):
    """Compare the pystencils result against the NumPy reference solver.

    Returns the relative L2 error (or None if comparison was skipped).
    """
    if args.no_compare or not COMPARE_WITH_NUMPY:
        return None
    steps = N_STEPS if COMPARE_STEPS is None else min(COMPARE_STEPS, N_STEPS)
    rho_np, ux_np, uy_np = run_numpy_reference(steps, NX, NY, U_LID, TAU)
    rho_ps, ux_ps, uy_ps = macroscopic_from_f_list(f)
    speed = np.sqrt(ux_ps * ux_ps + uy_ps * uy_ps)
    speed_np = np.sqrt(ux_np * ux_np + uy_np * uy_np)
    l2 = np.linalg.norm(speed - speed_np) / (np.linalg.norm(speed_np) + 1.0e-12)
    linf = np.max(np.abs(speed - speed_np))
    print(f"numpy compare (steps={steps}): rel_l2={l2:.6g}, linf={linf:.6g}")
    return l2


if __name__ == "__main__":
    main()
