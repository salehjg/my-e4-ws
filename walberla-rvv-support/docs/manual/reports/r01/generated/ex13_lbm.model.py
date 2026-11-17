stencil = [(0, 0), (1, 0), (0, 1), (-1, 0), (0, -1), (1, 1), (-1, 1), (-1, -1), (1, -1)]
weights = [sp.Rational(4, 9)] + [sp.Rational(1, 9)] * 4 + [sp.Rational(1, 36)] * 4

src, dst = ps.fields("src(9), dst(9): double[2D]", layout="fzyx")
omega = sp.Symbol("omega")
rho, ux, uy = sp.symbols("rho, u_x, u_y")
