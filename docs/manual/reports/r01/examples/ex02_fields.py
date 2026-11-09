"""Chapter 3: fields, field accesses and memory layouts."""

from _manual import save

import numpy as np
import pystencils as ps

out = []


def show(label, value):
    out.append(f"{label:<44} -> {value!r}")


# [declare]
a, b = ps.fields("a, b")                  # no type given: float64, 2D
f = ps.fields("f: [2D]")                  # dynamic type (decided at codegen time)
g = ps.fields("g(2,3): float32[3D]")      # 3D, with a 2x3 tensor in every cell
h = ps.fields("h: int32[10,20]")          # fixed shape 10 x 20
pdfs = ps.fields("pdfs(19): float32[3D]", layout="fzyx")  # 19 values per cell
# [/declare]

for label, fld in [('fields("a, b")', [a, b]), ('fields("f: [2D]")', f),
                   ('fields("g(2,3): float32[3D]")', g), ('fields("h: int32[10,20]")', h),
                   ('fields("pdfs(19): float32[3D]", ...)', pdfs)]:
    show(label, fld)
show("g.spatial_dimensions, g.index_shape", (g.spatial_dimensions, g.index_shape))
show("pdfs.shape", pdfs.shape)
show("pdfs.strides", pdfs.strides)
save("declare-out", "\n".join(out))
out.clear()

# [access]
u = ps.fields("u: double[3D]")
v = ps.fields("v(2): double[2D]")

u.center            # u[0,0,0]   the current cell
u[1, 0, 0]          # east neighbour (x + 1)
u["N"], u["T"]      # compass names: N/S = y, E/W = x, T/B = z
u[1, -1, 0]         # south-east
v(1)                # index access in the centre: second component
v[1, 0](1)          # second component of the east neighbour
v.center_vector     # sympy Matrix of all components
# [/access]

show("u.center", u.center)
show("u[1, 0, 0]", u[1, 0, 0])
show('u["N"], u["T"]', (u["N"], u["T"]))
acc = u[1, -1, 0]
show("u[1, -1, 0].offsets", acc.offsets)
show("u[1, -1, 0].offset_name", acc.offset_name)
show("u[1, -1, 0].required_ghost_layers", acc.required_ghost_layers)
show("v(1)", v(1))
show("v[1, 0](1)", v[1, 0](1))
show("v.center_vector", v.center_vector)
show("isinstance(u[1,0,0], ps.TypedSymbol)", isinstance(u[1, 0, 0], ps.TypedSymbol))
show("type(u[1,0,0])", type(u[1, 0, 0]).__qualname__)
save("access-out", "\n".join(out))
out.clear()

# [layouts]
shape = (4, 5, 6, 19)  # x, y, z, 19 values per cell
soa = ps.Field.create_fixed_size("soa", shape, index_dimensions=1, layout="fzyx")
aos = ps.Field.create_fixed_size("aos", shape, index_dimensions=1, layout="zyxf")
c = ps.Field.create_fixed_size("c", shape, index_dimensions=1, layout="c")
# [/layouts]
show('fzyx (structure of arrays) strides', soa.strides)
show('zyxf (array of structures) strides', aos.strides)
show('"c" / "numpy" strides', c.strides)
save("layouts-out", "\n".join(out))
out.clear()

# [numpy]
arr = np.zeros((10, 20, 3), dtype=np.float32)
n = ps.Field.create_from_numpy_array("n", arr, index_dimensions=1)

s, w = ps.fields("s, w(3)", s=np.zeros((5, 6)), w=np.zeros((5, 6, 3)))
# [/numpy]
show("n", n)
show("n.shape, n.strides (in elements)", (n.shape, n.strides))
show("w", w)
show("w.strides", w.strides)
save("numpy-out", "\n".join(out))
