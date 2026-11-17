step = heat.compile()
u_arr = np.random.default_rng(0).random((32, 32))
u_new_arr = np.zeros_like(u_arr)
step(u=u_arr, u_new=u_new_arr, alpha=0.1)   # scalar parameters are keywords too
