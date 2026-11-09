from pystencils.backend.kernelcreation import (
    KernelCreationContext, FullIterationSpace, FreezeExpressions, Typifier)

f, g = ps.fields("f, g: float32[2D]", layout="fzyx")
ctx = KernelCreationContext(default_dtype=ps.create_type("float32"))
ctx.add_field(f, const=True)
ctx.add_field(g)
ispace = FullIterationSpace.create_with_ghost_layers(ctx, 1, archetype_field=g)
ctx.set_iteration_space(ispace)
