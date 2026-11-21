"""Independent reference (oracle) for the SweepgenLdcCPU lid-driven cavity, in NumPy.

It computes, in double precision, the same discrete algorithm as the waLBerla app
(submodules/walberla/apps/benchmarks/SweepgenLdcCPU), without any of the code that the app's
variants are built from: no pystencils code generation, no sweepgen, no waLBerla. Only the
equilibrium formula is taken from lbmpy (symbolically, then evaluated with NumPy), because that
formula defines the method; everything else is written out here:

  storage     zero-centred PDFs g_i = f_i - w_i (lbmpy's default, as in the generated code)
  macros      rho = 1 + sum_i g_i,  u = sum_i c_i g_i / rho   (pre-collision, = the app's output)
  collision   g_i <- g_i + omega (geq_i(rho, u) - g_i)        (SRT; geq from lbmpy, also zero-centred)
  streaming   pull: the cell x reads direction i from x - c_i
  walls       after each step, for every link (x, d) from a fluid cell x into a cell x + c_d outside
              the domain, using the post-collision PDFs of x (all reads before any write):
                lid (x + c_d has y > Ny - 1):  g_inv(d)(x + c_d) = g_d(x) - 6 w_d rho(x) c_d.(u_lid, 0, 0)
                other walls (NoSlip):          g_inv(d)(x + c_d) = g_d(x)
              rho(x) = 1 + sum_i g_i(x) over the post-collision PDFs (lbmpy's UBB, compressible).
  start       g = 0 everywhere (rest, rho = 1), ghost layers included: this is what InitPdfs writes
              (and the zero-initialized field where it writes nothing). The walls act from the end
              of the first step on.

Self-check: before the wall update, all ghost values are set to NaN. A ghost value that the next
step reads but no wall link wrote would turn the result into NaN, so a finite result shows that
every link into a wall is handled.

Usage: python ldc_reference.py NX NY NZ STEPS OUT.npz [--omega 1.8] [--u-lid 0.05]
Writes rho, u (shape (3, NX, NY, NZ)), the link counts and the parameters to OUT.npz.
"""

import argparse
import sys

import numpy as np
import sympy as sp


def lbmpy_method():
    """The app's method: D3Q19, SRT, compressible, lbmpy defaults (zero-centred storage)."""
    from lbmpy import LBMConfig, LBStencil, Stencil, Method, create_lb_method

    cfg = LBMConfig(stencil=LBStencil(Stencil.D3Q19), method=Method.SRT, compressible=True,
                    relaxation_rate=sp.Symbol("omega"))
    return create_lb_method(lbm_config=cfg)


class Reference:
    def __init__(self, nx, ny, nz, omega, u_lid):
        m = lbmpy_method()
        self.shape = (nx, ny, nz)
        self.omega = float(omega)
        self.u_lid = float(u_lid)
        self.c = np.array(m.stencil, dtype=np.int64)            # (Q, 3)
        self.q = len(self.c)
        self.w = np.array([float(x) for x in m.weights])
        self.inv = np.array([int(np.flatnonzero((self.c == -ci).all(axis=1))[0]) for ci in self.c])

        cqc = m.conserved_quantity_computation
        drho, rho = cqc.density_deviation_symbol, cqc.density_symbol
        u = cqc.velocity_symbols
        eq = m.get_equilibrium_terms()
        free = set().union(*(e.free_symbols for e in eq))
        if not free <= {drho, rho, *u}:
            raise RuntimeError(f"unexpected symbols in the equilibrium: {free}")
        self.geq = [sp.lambdify((drho, rho, *u), e, "numpy") for e in eq]
        # The terms must be zero-centred (0 at rest), as the generated code stores them
        at_rest = [float(f(0.0, 1.0, 0.0, 0.0, 0.0)) for f in self.geq]
        if max(abs(v) for v in at_rest) != 0.0:
            raise RuntimeError(f"equilibrium is not zero-centred: {at_rest}")

        # g with one ghost layer: g[i, x+1, y+1, z+1]
        self.g = np.zeros((self.q, nx + 2, ny + 2, nz + 2))
        self.links = self._links()

    def _links(self):
        """[(d, fluid cell indices (3 arrays), is_lid)] for all links into the walls"""
        nx, ny, nz = self.shape
        xs, ys, zs = np.meshgrid(np.arange(nx), np.arange(ny), np.arange(nz), indexing="ij")
        out = []
        for d in range(1, self.q):
            cx, cy, cz = self.c[d]
            wx, wy, wz = xs + cx, ys + cy, zs + cz
            outside = (wx < 0) | (wx >= nx) | (wy < 0) | (wy >= ny) | (wz < 0) | (wz >= nz)
            lid = outside & (wy > ny - 1)
            noslip = outside & ~lid
            for mask, is_lid in ((lid, True), (noslip, False)):
                idx = np.nonzero(mask)
                if len(idx[0]):
                    out.append((d, idx, is_lid))
        return out

    def link_counts(self):
        lid = sum(len(i[0]) for d, i, l in self.links if l)
        noslip = sum(len(i[0]) for d, i, l in self.links if not l)
        return noslip, lid

    def interior(self, i_or_slice=slice(None)):
        return self.g[i_or_slice, 1:-1, 1:-1, 1:-1]

    def step(self):
        nx, ny, nz = self.shape
        # Pull: pre-collision g_i(x) = g_i(x - c_i)
        pre = np.empty((self.q, nx, ny, nz))
        for i, (cx, cy, cz) in enumerate(self.c):
            pre[i] = self.g[i, 1 - cx:1 - cx + nx, 1 - cy:1 - cy + ny, 1 - cz:1 - cz + nz]
        drho = pre.sum(axis=0)
        rho = 1.0 + drho
        u = np.einsum("id,ixyz->dxyz", self.c.astype(float), pre) / rho
        post = np.empty_like(pre)
        for i in range(self.q):
            geq = self.geq[i](drho, rho, u[0], u[1], u[2])
            post[i] = pre[i] + self.omega * (geq - pre[i])
        # New field: interior = post-collision, ghosts = NaN until the walls write them
        g = np.full_like(self.g, np.nan)
        g[:, 1:-1, 1:-1, 1:-1] = post
        rho_post = 1.0 + post.sum(axis=0)
        for d, (x, y, z), is_lid in self.links:
            cx, cy, cz = self.c[d]
            val = post[d][x, y, z]
            if is_lid:
                val = val - 6.0 * self.w[d] * rho_post[x, y, z] * (cx * self.u_lid)
            g[self.inv[d], x + cx + 1, y + cy + 1, z + cz + 1] = val
        self.g = g
        return rho, u


def run(nx, ny, nz, steps, omega=1.8, u_lid=0.05):
    ref = Reference(nx, ny, nz, omega, u_lid)
    rho = u = None
    for _ in range(steps):
        rho, u = ref.step()
    return ref, rho, u


def main(argv=None):
    p = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    p.add_argument("nx", type=int)
    p.add_argument("ny", type=int)
    p.add_argument("nz", type=int)
    p.add_argument("steps", type=int)
    p.add_argument("out")
    p.add_argument("--omega", type=float, default=1.8)
    p.add_argument("--u-lid", type=float, default=0.05)
    a = p.parse_args(argv)
    ref, rho, u = run(a.nx, a.ny, a.nz, a.steps, a.omega, a.u_lid)
    finite = bool(np.isfinite(rho).all() and np.isfinite(u).all())
    noslip, lid = ref.link_counts()
    np.savez(a.out, rho=rho, u=u, links_noslip=noslip, links_ubb=lid, steps=a.steps,
             omega=a.omega, u_lid=a.u_lid, shape=np.array(ref.shape))
    energy = float((u * u).sum())
    print(f"ldc_reference domain={a.nx}x{a.ny}x{a.nz} steps={a.steps} omega={a.omega} u_lid={a.u_lid} "
          f"finite={finite} links_noslip={noslip} links_ubb={lid} energy={energy!r} mass={float(rho.sum())!r}")
    return 0 if finite else 1


if __name__ == "__main__":
    sys.exit(main())
