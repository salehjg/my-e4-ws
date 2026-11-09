"""Chapter 3: random numbers (Philox) and the experimental flowgraph language."""

from _manual import save, save_c

import numpy as np
import sympy as sp
import pystencils as ps

# [philox]
rng = ps.random.Philox("rng", "float32", seed=0xCAFE)
t = ps.TypedSymbol("t", ps.DynamicType.INDEX_TYPE)   # e.g. the time step
r, r_asm = rng.get_random_vector(t)                   # 4 x float32 per call

noise = ps.fields("noise: float32[2D]")
k_rng = ps.create_kernel([r_asm, ps.Assignment(noise.center, r[0] - 0.5)])

arr = np.zeros((16, 16), dtype=np.float32)
k_rng.compile()(noise=arr, t=0)
# [/philox]
assert -0.5 <= arr.min() and arr.max() < 0.5 and arr.std() > 0.1
save_c("philox", k_rng.get_c_code())
save("philox-out", f"mean = {arr.mean():+.4f}, min = {arr.min():+.4f}, max = {arr.max():+.4f}")

# [flow]
f, g = ps.fields("f, g: double[2D]")
x, y = sp.symbols("x, y")


@ps.flow.block
def compute(_eq):
    _eq.let[x] = 2 * f.center           # private to this block
    _eq.export[y] = x + 1               # visible to successor blocks


@ps.flow.cases(preds=[compute])
def store(cs):
    @cs.case(y > 0)
    def positive(_eq):
        _eq.store[g.center] = y

    @cs.case(True)                      # default case
    def other(_eq):
        _eq.store[g.center] = 0


graph = ps.flow.tie(store, name="clamp")
k_flow = ps.create_kernel(graph)
# [/flow]
save_c("flow", k_flow.get_c_code())
fa = np.linspace(-1, 1, 30).reshape(5, 6)
ga = np.zeros_like(fa)
k_flow.compile()(f=fa, g=ga)
assert np.allclose(ga, np.where(2 * fa + 1 > 0, 2 * fa + 1, 0))
