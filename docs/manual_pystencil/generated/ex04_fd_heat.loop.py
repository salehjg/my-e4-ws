c_arr = np.zeros((40, 40))
c_arr[18:22, 18:22] = 1.0
c_tmp = np.zeros_like(c_arr)
for _ in range(50):
    heat_step(c=c_arr, c_next=c_tmp, D=1.0)
    c_arr, c_tmp = c_tmp, c_arr
