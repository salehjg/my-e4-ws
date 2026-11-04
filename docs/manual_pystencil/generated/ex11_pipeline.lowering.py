from pystencils.backend.platforms import X86VectorCpu, X86VectorArch
from pystencils.backend.transformations import LowerToC, SelectFunctions

platform = X86VectorCpu(ctx, X86VectorArch.AVX)
kernel_ast = platform.get_intrinsic_selector()(kernel_ast)  # vector ops -> intrinsics
kernel_ast = LowerToC(ctx)(kernel_ast)                      # buffer accesses -> pointers
kernel_ast = SelectFunctions(platform)(kernel_ast)          # IR functions -> C functions
