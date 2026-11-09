from pystencils.jit import CpuJit
from pystencils.jit.cpu.compiler_info import ClangInfo, GccInfo

gcc = GccInfo()                                    # the default on Linux
clang = ClangInfo(optlevel="3", extra_cxxflags=["-Wall"])
jit = CpuJit(compiler_info=clang, objcache=None)   # None: no persistent cache

fn = jit.compile(kernel)                           # or: cfg.jit = jit
