a, b = ps.fields("a, b")                  # no type given: float64, 2D
f = ps.fields("f: [2D]")                  # dynamic type (decided at codegen time)
g = ps.fields("g(2,3): float32[3D]")      # 3D, with a 2x3 tensor in every cell
h = ps.fields("h: int32[10,20]")          # fixed shape 10 x 20
pdfs = ps.fields("pdfs(19): float32[3D]", layout="fzyx")  # 19 values per cell
