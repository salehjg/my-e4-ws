import pystencils as ps

f, g = ps.fields("f, g: float64[2D]")                  # generic 2D fields
v = ps.fields("v(3): float32[3D]", layout="fzyx")      # 3 values per cell, SoA layout
h = ps.fields("h: double[64, 64]")                     # fixed shape
a = ps.Field.create_from_numpy_array("a", np.zeros((8, 8)))

f.center, f[1, 0], f["N"], f[-1, -1]                   # centre, east, north, south-west
v(2), v[0, -1, 0](1)                                   # component 2; component 1 of a neighbour
