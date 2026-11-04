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
