"""Appendix: quick reference -- every line here is executed by the listing generator."""

from _manual import save

import numpy as np
import sympy as sp

# [qr-fields]
import pystencils as ps

f, g = ps.fields("f, g: float64[2D]")                  # generic 2D fields
v = ps.fields("v(3): float32[3D]", layout="fzyx")      # 3 values per cell, SoA layout
h = ps.fields("h: double[64, 64]")                     # fixed shape
a = ps.Field.create_from_numpy_array("a", np.zeros((8, 8)))

f.center, f[1, 0], f["N"], f[-1, -1]                   # centre, east, north, south-west
v(2), v[0, -1, 0](1)                                   # component 2; component 1 of a neighbour
# [/qr-fields]

# [qr-rules]
rule = ps.Assignment(g.center, (f[1, 0] + f[-1, 0]) / 2)
t = sp.Symbol("t")                                     # untyped: default_dtype
w = ps.TypedSymbol("w", "float64")                     # explicitly typed
ac = ps.AssignmentCollection(
    main_assignments=[ps.Assignment(g.center, w * t)],
    subexpressions=[ps.Assignment(t, f[1, 0] - f[-1, 0])],
)
ac = ps.simp.sympy_cse(ac)                             # common subexpressions
cast = ps.tcast(ps.x_, "float64")                      # explicit cast of the x counter
total = ps.TypedSymbol("total", "float64")
red = ps.AddReductionAssignment(total, f.center)       # also Mul/Min/Max/Sub
# [/qr-rules]

# [qr-config]
cfg = ps.CreateKernelConfig(target=ps.Target.CurrentCPU, default_dtype="float64")
cfg.ghost_layers = 1                       # or: cfg.iteration_slice = ps.make_slice[1:-1, ::2]
cfg.cpu.openmp.enable = True
cfg.cpu.vectorize.enable = cfg.get_target().is_vector_cpu()
cfg.cpu.vectorize.assume_inner_stride_one = True
gpu_cfg = ps.CreateKernelConfig(target=ps.Target.CUDA)
gpu_cfg.gpu.indexing_scheme = "blockwise4d"
# [/qr-config]

# [qr-generate]
kernel = ps.create_kernel(rule, cfg)       # -> Kernel (GpuKernel for CUDA/HIP)
code = kernel.get_c_code()                 # C/C++ text; ps.inspect(kernel, show_cpp=True)
ir = kernel.get_ir_code()                  # typed IR
params = [(p.name, str(p.dtype)) for p in kernel.parameters]
headers = kernel.required_headers          # #include list
gl = kernel.metadata["ghost_layers"]
# [/qr-generate]

# [qr-run]
fn = kernel.compile()                      # CpuJit: g++ -Ofast -march=native -fopenmp
f_arr = np.random.default_rng(1).random((32, 32))
g_arr = np.zeros_like(f_arr)
fn(f=f_arr, g=g_arr)                       # keyword arguments = field / symbol names

red_fn = ps.create_kernel(red).compile()
result = np.zeros(1)
red_fn(f=f_arr, total=result)              # reductions write into 1-element arrays
# [/qr-run]
assert np.allclose(g_arr[1:-1, 1:-1], (f_arr[2:, 1:-1] + f_arr[:-2, 1:-1]) / 2)
assert np.isclose(result[0], f_arr.sum())

# [qr-jit]
from pystencils.jit import CpuJit, no_jit
from pystencils.jit.cpu.compiler_info import ClangInfo, GccInfo

cfg.jit = CpuJit(ClangInfo(extra_cxxflags=["-g"]), objcache=None)  # custom compiler
cfg_export = cfg.copy()
cfg_export.jit = no_jit                    # code generation only (e.g. for C++ export)
# [/qr-jit]
ps.create_kernel(rule, cfg).compile()(f=f_arr, g=g_arr)
save("qr-check", "quick reference executed: OK")
