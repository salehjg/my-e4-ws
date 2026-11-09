f, g = ps.fields("f, g: double[2D]", layout="fzyx")
c = sp.Symbol("c")
assignments = [ps.Assignment(g.center, c * f.center + 1)]
