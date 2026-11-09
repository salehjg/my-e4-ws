rng = ps.random.Philox("rng", "float32", seed=0xCAFE)
t = ps.TypedSymbol("t", ps.DynamicType.INDEX_TYPE)   # e.g. the time step
r, r_asm = rng.get_random_vector(t)                   # 4 x float32 per call

noise = ps.fields("noise: float32[2D]")
k_rng = ps.create_kernel([r_asm, ps.Assignment(noise.center, r[0] - 0.5)])

arr = np.zeros((16, 16), dtype=np.float32)
k_rng.compile()(noise=arr, t=0)
