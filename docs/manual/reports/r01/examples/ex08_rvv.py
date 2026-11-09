"""Chapter 11: the RISC-V RVV backend (fork-only), VLS with VLEN = 256."""

from _manual import save, save_c

import platform
import shutil
import subprocess

import pystencils as ps
from pystencils.include import get_pystencils_include_path

# [config]
cfg = ps.CreateKernelConfig(target=ps.Target.RISCV_RVV, default_dtype="float32")
cfg.cpu.vectorize.enable = True
cfg.cpu.vectorize.assume_inner_stride_one = True
cfg.cpu.openmp.enable = True

src, dst = ps.fields("src, dst: float32[2D]")
update = ps.Assignment(dst.center, (src[1, 0] + src[-1, 0] + src[0, 1] + src[0, -1]) / 4)
rvv_jacobi = ps.create_kernel(update, cfg)
# [/config]
save_c("jacobi", rvv_jacobi.get_c_code())
save("headers", "\n".join(sorted(rvv_jacobi.required_headers)))

# [reduction]
x = ps.fields("x: float64[1D]")
w = ps.TypedSymbol("w", "float64")
cfg64 = cfg.copy()
cfg64.default_dtype = "float64"
rvv_sum = ps.create_kernel(ps.AddReductionAssignment(w, x.center), cfg64)
# [/reduction]
save_c("reduction", rvv_sum.get_c_code())

# [strided]
s = ps.fields("s: float64[2D]", layout="c")      # vectorize along a strided axis
cfg_strided = ps.CreateKernelConfig(target=ps.Target.RISCV_RVV)
cfg_strided.cpu.vectorize.enable = True          # no assume_inner_stride_one here
strided = ps.create_kernel(ps.Assignment(s.center, 3 * s.center), cfg_strided)
# [/strided]
save_c("strided", strided.get_c_code())

#   JIT flags the default CPU JIT would use for this target.
from pystencils.jit.cpu.compiler_info import GccInfo, ClangInfo  # noqa: E402

save("flags", "\n".join([
    f"GccInfo(target=RISCV_RVV).cxxflags()   = {GccInfo(target=ps.Target.RISCV_RVV).cxxflags()}",
    f"ClangInfo(target=RISCV_RVV).cxxflags() = {ClangInfo(target=ps.Target.RISCV_RVV).cxxflags()}",
]))


#   Syntax-check the generated code with a RISC-V cross compiler (if installed), the
#   same way tests/nbackend/test_rvv_codegen.py does.
def riscv_cxx():
    if platform.machine() == "riscv64":
        return shutil.which("g++")
    return shutil.which("riscv64-linux-gnu-g++")


cxx = riscv_cxx()
if cxx is not None:
    results = []
    for name, ker in [("jacobi", rvv_jacobi), ("reduction", rvv_sum), ("strided", strided)]:
        source = "\n".join(
            [f"#include {h}" for h in sorted(ker.required_headers)]
            + ["#define RESTRICT __restrict__", ker.get_c_code()]
        )
        cmd = [cxx, "-std=c++17", "-fopenmp", "-fsyntax-only", "-march=rv64gcv_zvl256b",
               f"-I{get_pystencils_include_path()}", "-x", "c++", "-"]
        res = subprocess.run(cmd, input=source, capture_output=True, text=True)
        assert res.returncode == 0, res.stderr
        results.append(f"{name}: OK")
    save("syntax-check", f"{shutil.os.path.basename(cxx)} -fsyntax-only -march=rv64gcv_zvl256b: "
         + ", ".join(results))
