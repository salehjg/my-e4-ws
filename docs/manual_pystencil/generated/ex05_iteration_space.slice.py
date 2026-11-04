h = ps.Field.create_fixed_size("h", (16, 32))        # fixed shape -> constant bounds
k_slice = ps.create_kernel(
    ps.Assignment(h.center, 1.0),
    iteration_slice=ps.make_slice[::2, 3:-3],         # every 2nd row, skip 3 columns
)
