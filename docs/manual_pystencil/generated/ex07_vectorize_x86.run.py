fn = avx.compile()
a = np.random.default_rng(3).random((30, 37))   # 35 inner points: not a multiple of 4
b = np.zeros_like(a)
fn(src=a, dst=b)
