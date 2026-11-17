jacobi = kernel.compile()  # C++ -> Python extension module, loaded on the fly

rng = np.random.default_rng(seed=42)
src_arr = rng.random((64, 48))  # includes one ghost layer on each side
dst_arr = np.zeros_like(src_arr)

jacobi(src=src_arr, dst=dst_arr)  # keyword arguments = field names
