from pystencils.codegen.driver import KernelFactory
from pystencils.jit import no_jit

kernel = KernelFactory(ctx).create_generic_kernel(
    platform, kernel_ast, "manual_kernel", ps.Target.X86_AVX, no_jit)
