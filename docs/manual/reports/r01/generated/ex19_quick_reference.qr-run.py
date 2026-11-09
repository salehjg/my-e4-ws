fn = kernel.compile()                      # CpuJit: g++ -Ofast -march=native -fopenmp
f_arr = np.random.default_rng(1).random((32, 32))
g_arr = np.zeros_like(f_arr)
fn(f=f_arr, g=g_arr)                       # keyword arguments = field / symbol names

red_fn = ps.create_kernel(red).compile()
result = np.zeros(1)
red_fn(f=f_arr, total=result)              # reductions write into 1-element arrays
