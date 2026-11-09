"""Chapter 3: from a PDE to a kernel with pystencils.fd (explicit heat equation)."""

from _manual import save, save_c

import numpy as np
import sympy as sp
import pystencils as ps

# [pde]
c, c_next = ps.fields("c, c_next: double[2D]")
D = sp.Symbol("D")

pde = ps.fd.transient(c) - ps.fd.diffusion(c, D)     # dc/dt = div(D grad c)
discretize = ps.fd.Discretization2ndOrder(dx=1, dt=sp.Rational(1, 10))
rhs = discretize(pde)                                 # explicit Euler + central FD

heat_step = ps.create_kernel(ps.Assignment(c_next.center, rhs)).compile()
# [/pde]
save("pde", pde)
save("rhs", sp.simplify(rhs))

# [loop]
c_arr = np.zeros((40, 40))
c_arr[18:22, 18:22] = 1.0
c_tmp = np.zeros_like(c_arr)
for _ in range(50):
    heat_step(c=c_arr, c_next=c_tmp, D=1.0)
    c_arr, c_tmp = c_tmp, c_arr
# [/loop]

#   NumPy reference for the same scheme (ghost layer kept at zero).
ref = np.zeros((40, 40))
ref[18:22, 18:22] = 1.0
for _ in range(50):
    new = np.zeros_like(ref)
    new[1:-1, 1:-1] = ref[1:-1, 1:-1] + 0.1 * (
        ref[2:, 1:-1] + ref[:-2, 1:-1] + ref[1:-1, 2:] + ref[1:-1, :-2]
        - 4 * ref[1:-1, 1:-1])
    ref = new
assert np.allclose(c_arr, ref)
save("check", f"total heat after 50 steps: {c_arr.sum():.6f} (NumPy reference: {ref.sum():.6f})")
