from pystencils.jit import CpuJit, no_jit
from pystencils.jit.cpu.compiler_info import ClangInfo, GccInfo

cfg.jit = CpuJit(ClangInfo(extra_cxxflags=["-g"]), objcache=None)  # custom compiler
cfg_export = cfg.copy()
cfg_export.jit = no_jit                    # code generation only (e.g. for C++ export)
