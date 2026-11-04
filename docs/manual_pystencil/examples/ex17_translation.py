"""Chapter 8: iteration spaces, freeze and typify by hand."""

from _manual import save

import sympy as sp
import pystencils as ps

# [ispace]
from pystencils.backend.kernelcreation import (
    KernelCreationContext, FullIterationSpace, FreezeExpressions, Typifier)

f, g = ps.fields("f, g: float32[2D]", layout="fzyx")
ctx = KernelCreationContext(default_dtype=ps.create_type("float32"))
ctx.add_field(f, const=True)
ctx.add_field(g)
ispace = FullIterationSpace.create_with_ghost_layers(ctx, 1, archetype_field=g)
ctx.set_iteration_space(ispace)
# [/ispace]
save("ispace", "\n".join(
    [f"archetype field : {ispace.archetype_field}",
     f"loop order      : {ispace.loop_order}   (slowest first)"]
    + [f"dimension {i}     : counter {d.counter.name}, start {d.start}, "
       f"stop {d.stop}, step {d.step}" for i, d in enumerate(ispace.dimensions)]))

# [freeze]
x = sp.Symbol("x")
asm = ps.Assignment(g.center, f[1, 0] ** 3 - x / f.center + sp.Rational(1, 3)
                    + sp.sqrt(f[0, 1]) + sp.exp(-f.center))

frozen = FreezeExpressions(ctx)(asm)      # SymPy -> IR, mostly untyped
# [/freeze]
save("sympy", asm)
save("frozen", frozen)

# [typify]
typed = Typifier(ctx)(frozen)             # infer and check all types (in place)
# [/typify]
save("typed", typed)
