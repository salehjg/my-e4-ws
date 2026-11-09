x = sp.Symbol("x")
asm = ps.Assignment(g.center, f[1, 0] ** 3 - x / f.center + sp.Rational(1, 3)
                    + sp.sqrt(f[0, 1]) + sp.exp(-f.center))

frozen = FreezeExpressions(ctx)(asm)      # SymPy -> IR, mostly untyped
