from pystencils.backend.kernelcreation import KernelCreationContext, AstFactory

ctx = KernelCreationContext(default_dtype=Fp(64), index_dtype=SInt(64))

x = ctx.get_symbol("x", Fp(64))            # find or create a symbol
x2 = ctx.duplicate_symbol(x)               # fresh symbol "x__0" of the same type

f = ps.fields("f(3): float32[2D]")
buf = ctx.get_buffer(f)                    # the memory buffer behind the field
