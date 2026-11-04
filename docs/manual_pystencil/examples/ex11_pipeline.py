"""Chapter 9: running the backend pipeline by hand (abridged DefaultKernelCreationDriver).

Modelled on docs/source/backend/backend_walkthrough.md of pystencils, but with a small
2D kernel and the x86 AVX platform, printing the IR after every stage.
"""

from _manual import save, save_c

import sympy as sp
import pystencils as ps

# [kernel]
f, g = ps.fields("f, g: double[2D]", layout="fzyx")
c = sp.Symbol("c")
assignments = [ps.Assignment(g.center, c * f.center + 1)]
# [/kernel]

# [context]
from pystencils.backend.kernelcreation import (
    KernelCreationContext, FullIterationSpace, AstFactory)
from pystencils.backend.ast.structural import PsBlock

ctx = KernelCreationContext()                      # default_dtype float64, index int64
ispace = FullIterationSpace.create_with_ghost_layers(ctx, 0, archetype_field=f)
ctx.set_iteration_space(ispace)

factory = AstFactory(ctx)
body = PsBlock([factory.parse_sympy(asm) for asm in assignments])  # freeze + typify
# [/context]

# [unit-stride]
from pystencils.backend.constants import PsConstant

inner = ispace.loop_order[-1]          # fastest coordinate (ctr_0 for fzyx)
for fld in (f, g):                     # what cpu.vectorize.assume_inner_stride_one does
    buf = ctx.get_buffer(fld)
    buf.strides[inner] = PsConstant(1, buf.index_type)
# [/unit-stride]
save("s1-parsed", body)

# [axes]
from pystencils.backend.transformations import (
    CanonicalizeSymbols, AxisExpansion, HoistIterationInvariantDeclarations)

cube = factory.cube_from_ispace(ispace, body)      # the whole space as an axes cube
canonicalize = CanonicalizeSymbols(ctx)
cube = canonicalize(cube)
# [/axes]
save("s2-cube", cube.clone())

# [expand]
ae = AxisExpansion(ctx)
strategy = ae.create_strategy([
    ae.parallel_loop(),                            # ctr_1 (slow): OpenMP loop
    ae.peel_for_divisibility(4),                   # ctr_0 (fast): split off remainder
    [ae.block_loop(4, assume_divisible=True), ae.simd(4)],   # ... 4-wide SIMD body
    [ae.loop()],                                   # ... scalar remainder loop
])
kernel_ast = strategy(cube)
kernel_ast = HoistIterationInvariantDeclarations(ctx)(kernel_ast)
# [/expand]
save("s3-axes", kernel_ast)

# [materialize]
from pystencils.backend.transformations import (
    MaterializeAxes, ReductionsToMemory, EliminateConstants)

kernel_ast = MaterializeAxes(ctx)(kernel_ast)      # loops, pragmas, vectorized body
kernel_ast = ReductionsToMemory(ctx, ctx.reduction_data.values())(kernel_ast)
kernel_ast = canonicalize(kernel_ast)
kernel_ast = EliminateConstants(ctx, extract_constant_exprs=True)(kernel_ast)
# [/materialize]
save("s4-materialized", kernel_ast)

# [lowering]
from pystencils.backend.platforms import X86VectorCpu, X86VectorArch
from pystencils.backend.transformations import LowerToC, SelectFunctions

platform = X86VectorCpu(ctx, X86VectorArch.AVX)
kernel_ast = platform.get_intrinsic_selector()(kernel_ast)  # vector ops -> intrinsics
kernel_ast = LowerToC(ctx)(kernel_ast)                      # buffer accesses -> pointers
kernel_ast = SelectFunctions(platform)(kernel_ast)          # IR functions -> C functions
# [/lowering]
save("s5-lowered", kernel_ast)

# [finalize]
from pystencils.codegen.driver import KernelFactory
from pystencils.jit import no_jit

kernel = KernelFactory(ctx).create_generic_kernel(
    platform, kernel_ast, "manual_kernel", ps.Target.X86_AVX, no_jit)
# [/finalize]
save_c("final", kernel.get_c_code())

#   For comparison: the same through create_kernel() with an equivalent config.
cfg = ps.CreateKernelConfig(target=ps.Target.X86_AVX, ghost_layers=0)
cfg.cpu.openmp.enable = True
cfg.cpu.vectorize.enable = True
cfg.cpu.vectorize.assume_inner_stride_one = True
auto = ps.create_kernel(assignments, cfg)
save_c("driver", auto.get_c_code())
