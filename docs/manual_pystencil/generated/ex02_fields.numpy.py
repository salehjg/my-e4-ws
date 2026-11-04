arr = np.zeros((10, 20, 3), dtype=np.float32)
n = ps.Field.create_from_numpy_array("n", arr, index_dimensions=1)

s, w = ps.fields("s, w(3)", s=np.zeros((5, 6)), w=np.zeros((5, 6, 3)))
