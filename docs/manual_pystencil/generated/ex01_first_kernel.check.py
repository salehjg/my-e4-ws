expected = (
    src_arr[2:, 1:-1] + src_arr[:-2, 1:-1] + src_arr[1:-1, 2:] + src_arr[1:-1, :-2]
) / 4
assert np.allclose(dst_arr[1:-1, 1:-1], expected)
assert np.all(dst_arr[0, :] == 0.0)  # ghost layers are not written
