"""Chapter 5: the CPU JIT -- compilers, flags, the generated extension module, errors."""

from _manual import save, format_c

import numpy as np
import pystencils as ps
from pystencils.jit.cpu.compiler_info import CompilerInfo

f, g = ps.fields("f, g: double[2D]")
kernel = ps.create_kernel(ps.Assignment(g.center, 2 * f.center))

# [custom-jit]
from pystencils.jit import CpuJit
from pystencils.jit.cpu.compiler_info import ClangInfo, GccInfo

gcc = GccInfo()                                    # the default on Linux
clang = ClangInfo(optlevel="3", extra_cxxflags=["-Wall"])
jit = CpuJit(compiler_info=clang, objcache=None)   # None: no persistent cache

fn = jit.compile(kernel)                           # or: cfg.jit = jit
# [/custom-jit]
a = np.ones((8, 8))
b = np.zeros_like(a)
fn(f=a, g=b)
assert np.all(b == 2.0)

save("flags", "\n".join([
    f"CompilerInfo.get_default()     -> {type(CompilerInfo.get_default()).__name__}",
    f"GccInfo().cxx(), cxxflags()    -> {gcc.cxx()!r}, {gcc.cxxflags()}",
    f"ClangInfo(...).cxx(), cxxflags() -> {clang.cxx()!r}, {clang.cxxflags()}",
    f"GccInfo(target=X86_AVX512)     -> {GccInfo(target=ps.Target.X86_AVX512).cxxflags()[-1]}",
    f"GccInfo(target=ARM_SVE)        -> {GccInfo(target=ps.Target.ARM_SVE).cxxflags()[-1]}",
]))

#   The C++ extension module the default module builder renders around the kernel.
from pystencils.jit.cpu.default_module_builder import DefaultExtensionModuleBuilder  # noqa

module = DefaultExtensionModuleBuilder(gcc).render_module(kernel, "kernel_jit")
lines = module.splitlines()
start = next(i for i, ln in enumerate(lines) if ln.startswith("struct KernelArgs_kernel"))
stop = next(i for i, ln in enumerate(lines) if "static PyMethodDef" in ln)
save("module-glue", format_c("\n".join(lines[start:stop]).rstrip().rstrip("{").rstrip()
                             + "\n"), "cpp")
head = [ln for ln in lines[: lines.index("namespace internal {") + 1] if ln.strip()]
save("module-head", "\n".join(head), "cpp")
save("module-size", f"{len(lines)} lines of C++ in the rendered extension module")

#   What the argument checks report.
errors = []
calls = [
    ("fn(f=a)", lambda: fn(f=a)),
    ("fn(f=a, g=b.astype(np.float32))", lambda: fn(f=a, g=b.astype(np.float32))),
    ("fn(f=a, g=np.zeros((8, 9)))", lambda: fn(f=a, g=np.zeros((8, 9)))),
    ("fn(f=[[1.0]], g=b)", lambda: fn(f=[[1.0]], g=b)),
]
for label, call in calls:
    try:
        call()
        errors.append(f"{label:<34} -> (no error)")
    except Exception as e:  # noqa: BLE001
        msg = str(e).strip().splitlines()[0]
        errors.append(f"{label:<34} -> {type(e).__name__}: {msg}")
save("call-errors", "\n".join(errors))
