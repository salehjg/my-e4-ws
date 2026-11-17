y = ps.DEFAULTS.spatial_counters[0]                   # ctr_0, the slow coordinate
k_tri = ps.create_kernel(asm, iteration_slice=ps.make_slice[:, y:])  # upper triangle
