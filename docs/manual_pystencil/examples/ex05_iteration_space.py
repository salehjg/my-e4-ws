"""Chapter 4: iteration spaces -- ghost layers, slices, sparse index kernels."""

from _manual import save, save_c

import numpy as np
import pystencils as ps

f, g = ps.fields("f, g: double[2D]")
asm = ps.Assignment(g.center, 2 * f.center)

# [ghost-layers]
k_auto = ps.create_kernel(asm)                        # AUTO: inferred from accesses -> 0
k_gl2 = ps.create_kernel(asm, ghost_layers=2)         # 2 on every side
k_gl_sides = ps.create_kernel(asm, ghost_layers=[(1, 3), 0])  # (low, high) per axis
# [/ghost-layers]
save_c("gl-auto", k_auto.get_c_code())
save_c("gl-sides", k_gl_sides.get_c_code())
save("gl-metadata", "\n".join(
    f"{name:<12} metadata = {k.metadata}"
    for name, k in [("k_auto", k_auto), ("k_gl2", k_gl2), ("k_gl_sides", k_gl_sides)]))

# [slice]
h = ps.Field.create_fixed_size("h", (16, 32))        # fixed shape -> constant bounds
k_slice = ps.create_kernel(
    ps.Assignment(h.center, 1.0),
    iteration_slice=ps.make_slice[::2, 3:-3],         # every 2nd row, skip 3 columns
)
# [/slice]
save_c("slice", k_slice.get_c_code())

# [slice-run]
h_arr = np.zeros((16, 32))
k_slice.compile()(h=h_arr)
assert h_arr.sum() == 8 * 26 and h_arr[1, 10] == 0.0 and h_arr[2, 3] == 1.0
# [/slice-run]

# [triangle]
y = ps.DEFAULTS.spatial_counters[0]                   # ctr_0, the slow coordinate
k_tri = ps.create_kernel(asm, iteration_slice=ps.make_slice[:, y:])  # upper triangle
# [/triangle]
save_c("triangle", k_tri.get_c_code())

# [sparse]
cell = np.dtype([("x", np.int64), ("y", np.int64), ("value", np.float64)], align=True)
idx_arr = np.array([(0, 2, 3.0), (1, 3, 42.0), (2, 1, 5.0)], dtype=cell)

idx = ps.Field.create_from_numpy_array("idx", idx_arr, field_type=ps.FieldType.INDEXED)
dom = ps.fields("dom: double[2D]")

k_sparse = ps.create_kernel(
    ps.Assignment(dom.center, idx("value")),          # struct member access
    index_field=idx,
)
dom_arr = np.zeros((3, 4))
k_sparse.compile()(dom=dom_arr, idx=idx_arr)
# [/sparse]
assert dom_arr[1, 3] == 42.0 and dom_arr.sum() == 50.0
save_c("sparse", k_sparse.get_c_code())
save("sparse-out", dom_arr)
