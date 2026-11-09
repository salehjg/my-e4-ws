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
