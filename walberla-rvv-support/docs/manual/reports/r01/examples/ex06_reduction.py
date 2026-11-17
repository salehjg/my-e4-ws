"""Chapter 3/4: reductions, with OpenMP."""

from _manual import save, save_c

import numpy as np
import pystencils as ps

# [reduction]
x = ps.fields("x: double[1D]")
total = ps.TypedSymbol("total", "double")
peak = ps.TypedSymbol("peak", "double")

asms = [
    ps.AddReductionAssignment(total, x.center),
    ps.MaxReductionAssignment(peak, x.center),
]

cfg = ps.CreateKernelConfig()
cfg.cpu.openmp.enable = True
red = ps.create_kernel(asms, cfg)
# [/reduction]
save_c("code", red.get_c_code())

# [reduction-run]
red_fn = red.compile()
x_arr = np.random.default_rng(7).random(1000)
total_arr = np.zeros(1)              # results are passed as 1-element arrays ...
peak_arr = np.full(1, -np.inf)       # ... whose initial value is folded in
red_fn(x=x_arr, total=total_arr, peak=peak_arr)
# [/reduction-run]
assert np.isclose(total_arr[0], x_arr.sum()) and peak_arr[0] == x_arr.max()
save("check", f"total = {total_arr[0]:.6f} (NumPy {x_arr.sum():.6f}); "
     f"peak = {peak_arr[0]:.6f} (NumPy {x_arr.max():.6f})")
