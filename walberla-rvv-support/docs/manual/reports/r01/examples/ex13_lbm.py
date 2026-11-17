"""Chapter 12: worked example -- a fused D2Q9 lattice Boltzmann stream-collide kernel."""

from _manual import save, save_c

import numpy as np
import sympy as sp
import pystencils as ps
from pystencils.field import create_numpy_array_with_layout

# [model]
stencil = [(0, 0), (1, 0), (0, 1), (-1, 0), (0, -1), (1, 1), (-1, 1), (-1, -1), (1, -1)]
weights = [sp.Rational(4, 9)] + [sp.Rational(1, 9)] * 4 + [sp.Rational(1, 36)] * 4

src, dst = ps.fields("src(9), dst(9): double[2D]", layout="fzyx")
omega = sp.Symbol("omega")
rho, ux, uy = sp.symbols("rho, u_x, u_y")
# [/model]

# [rules]
#   Pull streaming: population q arrives from the neighbour at x - c_q.
f = [src[-cx, -cy](q) for q, (cx, cy) in enumerate(stencil)]

subexpressions = [
    ps.Assignment(rho, sum(f)),
    ps.Assignment(ux, sum(c[0] * fq for c, fq in zip(stencil, f)) / rho),
    ps.Assignment(uy, sum(c[1] * fq for c, fq in zip(stencil, f)) / rho),
]
main = []
for q, ((cx, cy), w) in enumerate(zip(stencil, weights)):
    cu = cx * ux + cy * uy
    feq = w * rho * (1 + 3 * cu + sp.Rational(9, 2) * cu**2
                     - sp.Rational(3, 2) * (ux**2 + uy**2))
    main.append(ps.Assignment(dst(q), f[q] - omega * (f[q] - feq)))

update = ps.simp.sympy_cse(ps.AssignmentCollection(main, subexpressions))
# [/rules]
ops = update.operation_count
save("ac-size", f"{len(update.subexpressions)} subexpressions, "
     f"{len(update.main_assignments)} main assignments; "
     f"{ops['adds']} adds, {ops['muls']} muls, {ops['divs']} div(s)")

# [kernels]
scalar = ps.create_kernel(update)

cfg = ps.CreateKernelConfig(target=ps.Target.auto_cpu())
if cfg.target.is_vector_cpu():
    cfg.cpu.vectorize.enable = True
    cfg.cpu.vectorize.assume_inner_stride_one = True   # needs x-fastest arrays (fzyx)
simd = ps.create_kernel(update, cfg)
# [/kernels]
code = simd.get_c_code()
save_c("scalar", scalar.get_c_code())
save("stats", "\n".join([
    f"target of the vectorized kernel: {simd.target.name}",
    f"generic kernel:    {len(scalar.get_c_code().splitlines())} lines of C",
    f"vectorized kernel: {len(code.splitlines())} lines of C",
]))

# [run]
nx, ny = 34, 21
shape = (nx + 2, ny + 2, 9)                         # one ghost layer per side
a = create_numpy_array_with_layout(shape, layout=(2, 1, 0))   # q slowest, x fastest
a[...] = np.random.default_rng(5).random(shape) * 0.1 + 1.0
b_scalar, b_simd = np.zeros_like(a), np.zeros_like(a)

scalar.compile()(src=a, dst=b_scalar, omega=1.6)
simd.compile()(src=a, dst=b_simd, omega=1.6)
# [/run]


#   NumPy reference implementation of the same step.
def numpy_step(arr, om):
    c = np.array(stencil)
    w = np.array([float(x) for x in weights])
    fpull = np.stack([np.roll(arr[..., q], shift=(c[q, 0], c[q, 1]), axis=(0, 1))
                      for q in range(9)], axis=-1)
    r = fpull.sum(-1)
    u = np.einsum("xyq,qd->xyd", fpull, c) / r[..., None]
    cu = np.einsum("xyd,qd->xyq", u, c)
    usq = (u**2).sum(-1)[..., None]
    feq = w * r[..., None] * (1 + 3 * cu + 4.5 * cu**2 - 1.5 * usq)
    return fpull - om * (fpull - feq)


ref = numpy_step(a, 1.6)
assert np.allclose(b_scalar[1:-1, 1:-1], ref[1:-1, 1:-1])
assert np.allclose(b_simd[1:-1, 1:-1], ref[1:-1, 1:-1])
save("check", "generic and vectorized kernels match the NumPy reference: OK")
