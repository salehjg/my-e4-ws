from pystencils.backend.kernelcreation import (
    KernelCreationContext, FullIterationSpace, AstFactory)
from pystencils.backend.ast.structural import PsBlock

ctx = KernelCreationContext()                      # default_dtype float64, index int64
ispace = FullIterationSpace.create_with_ghost_layers(ctx, 0, archetype_field=f)
ctx.set_iteration_space(ispace)

factory = AstFactory(ctx)
body = PsBlock([factory.parse_sympy(asm) for asm in assignments])  # freeze + typify
