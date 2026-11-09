red_fn = red.compile()
x_arr = np.random.default_rng(7).random(1000)
total_arr = np.zeros(1)              # results are passed as 1-element arrays ...
peak_arr = np.full(1, -np.inf)       # ... whose initial value is folded in
red_fn(x=x_arr, total=total_arr, peak=peak_arr)
