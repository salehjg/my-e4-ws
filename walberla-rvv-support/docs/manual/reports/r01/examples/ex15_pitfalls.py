"""Appendix C: re-checks every pitfall listed in the manual against this checkout."""

from _manual import save

import contextlib
import io
import sys

import numpy as np
import sympy as sp
import pystencils as ps

f, g = ps.fields("f, g: double[2D]")
asm = ps.Assignment(g.center, 2 * f.center)
results = []


def record(name, outcome):
    results.append(f"[{name}]\n    {outcome}")


def outcome_of(fn):
    try:
        val = fn()
        return f"ok: {val}"
    except Exception as e:  # noqa: BLE001
        return f"{type(e).__name__}: {' '.join(str(e).split())[:120]}"


# 1. star import
def star_import():
    ns = {}
    exec("from pystencils import *", ns)
    return "imported"


record("from pystencils import *", outcome_of(star_import))

# 2. show_code prints IR, not C
buf = io.StringIO()
with contextlib.redirect_stdout(buf), __import__("warnings").catch_warnings():
    __import__("warnings").simplefilter("ignore")
    ps.show_code(ps.create_kernel(asm))
printed = buf.getvalue()
record("ps.show_code(kernel)", "prints IR (typed constants like '[0: int64]')"
       if "int64]" in printed else "prints C code")

# 3. deprecated cpu_openmp=True
with __import__("warnings").catch_warnings():
    __import__("warnings").simplefilter("ignore")
    cfg = ps.CreateKernelConfig(cpu_openmp=True)
record("CreateKernelConfig(cpu_openmp=True)",
       f"cfg.cpu.openmp.enable == {cfg.cpu.openmp.get_option('enable')}")

# 4. create_fixed_size ignores memory_strides
fx = ps.Field.create_fixed_size("fx", (4, 5), memory_strides=(10, 1))
record("Field.create_fixed_size((4,5), memory_strides=(10,1))", f"strides == {fx.strides}")

# 5. staggered kernels
record("ps.create_staggered_kernel(...)",
       outcome_of(lambda: ps.create_staggered_kernel([asm])))

# 6. kernel decorator with a conditional expression (Python >= 3.14)
def decorated():
    @ps.kernel
    def k():
        g[0, 0] @= f[0, 0] if f[0, 0] > 0 else 0.0
    return "ok"


record(f"@ps.kernel with 'a if c else b' (Python {sys.version_info.major}."
       f"{sys.version_info.minor})", outcome_of(decorated))

# 7. keyword arguments of create_kernel must be top-level config fields
record("ps.create_kernel(asm, openmp=True)",
       outcome_of(lambda: ps.create_kernel(asm, openmp=True)))

# 8. the default JIT does not follow the kernel's target
from pystencils.jit.cpu.compiler_info import CompilerInfo  # noqa: E402

ci = CompilerInfo.get_default()
record("default CompilerInfo for a Target.X86_SSE kernel",
       f"{type(ci).__name__}(target={ci.target.name}) -> {ci.cxxflags()[-1]}")

# 9. assume_inner_stride_one is not checked at run time
cfg = ps.CreateKernelConfig(target=ps.Target.X86_AVX, ghost_layers=0)
cfg.cpu.vectorize.enable = True
cfg.cpu.vectorize.assume_inner_stride_one = True
if ps.Target.X86_AVX in ps.Target.available_targets():
    k = ps.create_kernel(asm, cfg).compile()
    big = np.arange(8 * 16, dtype=np.float64).reshape(8, 16)
    view = big[:, ::2]                                   # inner stride 2
    out = np.zeros((8, 8))
    k(f=view, g=out)
    record("AVX kernel (assume_inner_stride_one) called with a strided view",
           "no error raised; result correct: " + str(bool(np.allclose(out, 2 * view))))

# 10. CUDA warp-level reductions need an explicit warp size
x = ps.fields("x: double[1D]")
tot = ps.TypedSymbol("tot", "double")
c1 = ps.CreateKernelConfig(target=ps.Target.CUDA)
c1.gpu.assume_warp_aligned_block_size = True
code1 = ps.create_kernel(ps.AddReductionAssignment(tot, x.center), c1).get_c_code()
c2 = c1.copy()
c2.gpu.warp_size = 32
code2 = ps.create_kernel(ps.AddReductionAssignment(tot, x.center), c2).get_c_code()
record("CUDA reduction, assume_warp_aligned_block_size only / + warp_size=32",
       f"__shfl_xor_sync emitted: {'__shfl_xor_sync' in code1} / {'__shfl_xor_sync' in code2}")

# 11. order-dependent loop-independence check
record("ps.create_kernel(Assignment(f[0,0], f[1,0]))  (in-place stencil)",
       outcome_of(lambda: type(ps.create_kernel(ps.Assignment(f.center, f[1, 0]))).__name__))

# 12. the name of Target.GenericCPU
record("repr(ps.Target.GenericCPU)", repr(ps.Target.GenericCPU))

# 13. simplification factory
from pystencils.simplificationfactory import create_simplification_strategy  # noqa: E402

record("simplificationfactory.create_simplification_strategy()",
       f"returns {create_simplification_strategy()!r}")

# 14. block_size on a dynamic (default) GPU launch configuration
src, dst = ps.fields("src, dst: double[2D]")
kc = ps.create_kernel(ps.Assignment(dst.center, src.center), target=ps.Target.CUDA)
lc = kc.get_launch_configuration()
lc.block_size = (64, 2, 1)
blk, _ = lc.evaluate(_size_dst_0=66, _size_dst_1=66)
record("DynamicBlockSizeLaunchConfiguration.block_size = (64, 2, 1)",
       f"no error; evaluate() still uses block {blk}")

save("results", "\n".join(results))
