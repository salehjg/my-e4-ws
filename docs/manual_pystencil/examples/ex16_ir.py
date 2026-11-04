"""Chapter 7: the type system, symbols, buffers and a hand-built AST."""

from _manual import save

import numpy as np
import sympy as sp
import pystencils as ps

# [types]
from pystencils.types import create_type, PsVectorType, constify, deconstify
from pystencils.types.quick import Fp, SInt, UInt, Ptr

t_double = create_type("double")           # -> PsIeeeFloatType(64)
t_ptr = create_type("float * restrict")    # -> PsPointerType(float, restrict=True)
t_vec = PsVectorType(Fp(64), 4)            # SIMD type: 4 x float64
assert create_type("float64") is Fp(64)    # types are interned (cached instances)
assert constify(Fp(64)) == create_type("const double")
# [/types]

rows = []
for spec in ["double", "float32", "half", "int64_t", "uint8", "bool",
             "const float", "double * restrict", int, np.float32]:
    t = create_type(spec)
    rows.append(f"{spec!r:<25} {type(t).__name__:<22} {str(t):<18} {t.c_string()}")
rows.append(f"{'PsVectorType(Fp(64), 4)':<25} {type(t_vec).__name__:<22} {str(t_vec):<18} "
            "(none: lowered to intrinsics)")
save("types-table", "\n".join(rows))
save("literals", "\n".join(
    f"{str(t):<8} 3 -> {t.create_literal(t.create_constant(3))}"
    for t in [Fp(64), Fp(32), Fp(16), SInt(64), SInt(32), SInt(16), UInt(64)]))

# [context]
from pystencils.backend.kernelcreation import KernelCreationContext, AstFactory

ctx = KernelCreationContext(default_dtype=Fp(64), index_dtype=SInt(64))

x = ctx.get_symbol("x", Fp(64))            # find or create a symbol
x2 = ctx.duplicate_symbol(x)               # fresh symbol "x__0" of the same type

f = ps.fields("f(3): float32[2D]")
buf = ctx.get_buffer(f)                    # the memory buffer behind the field
# [/context]
save("context", "\n".join([
    f"x              : {x.name}: {x.dtype}",
    f"duplicate of x : {x2.name}: {x2.dtype}",
    f"buffer         : {buf.name}, element type {buf.element_type}, dim {buf.dim}",
    f"base pointer   : {buf.base_pointer.name}: {buf.base_pointer.dtype}",
    f"  properties   : {[type(p).__name__ for p in buf.base_pointer.properties]}",
    f"shape          : {[str(s) for s in buf.shape]}",
    f"strides        : {[str(s) for s in buf.strides]}",
]))

# [ast]
from pystencils.backend.ast.structural import PsBlock
from pystencils.backend.emission import emit_code, emit_ir
from pystencils.sympyextensions import mem_acc

factory = AstFactory(ctx)
a, b, c = sp.symbols("a, b, c")
inp = ps.TypedSymbol("inp", "const double *")            # a raw pointer parameter
i = ps.TypedSymbol("i", "int64")
body = PsBlock([
    factory.parse_sympy(ps.Assignment(a, 2 * b + 1)),    # freeze + typify
    factory.parse_sympy(ps.Assignment(c, a * mem_acc(inp, i) + ps.tcast(i, "double"))),
])
loop = factory.loop("i", slice(0, 16, 2), body)          # for(i = 0; i < 16; i += 2)
# [/ast]
save("ast-ir", emit_ir(loop))
save("ast-c", emit_code(loop))

# [tree]
def show_tree(node, depth=0, out=None):
    out = [] if out is None else out
    dtype = getattr(node, "dtype", None)
    out.append("  " * depth + type(node).__name__ + (f"  : {dtype}" if dtype else ""))
    for child in node.children:
        show_tree(child, depth + 1, out)
    return out
# [/tree]
save("tree", "\n".join(show_tree(body.statements[0])))
