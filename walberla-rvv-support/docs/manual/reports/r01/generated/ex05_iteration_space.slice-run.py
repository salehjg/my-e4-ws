h_arr = np.zeros((16, 32))
k_slice.compile()(h=h_arr)
assert h_arr.sum() == 8 * 26 and h_arr[1, 10] == 0.0 and h_arr[2, 3] == 1.0
