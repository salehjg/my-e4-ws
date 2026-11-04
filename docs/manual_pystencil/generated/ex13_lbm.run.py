nx, ny = 34, 21
shape = (nx + 2, ny + 2, 9)                         # one ghost layer per side
a = create_numpy_array_with_layout(shape, layout=(2, 1, 0))   # q slowest, x fastest
a[...] = np.random.default_rng(5).random(shape) * 0.1 + 1.0
b_scalar, b_simd = np.zeros_like(a), np.zeros_like(a)

scalar.compile()(src=a, dst=b_scalar, omega=1.6)
simd.compile()(src=a, dst=b_simd, omega=1.6)
