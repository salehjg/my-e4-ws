shape = (4, 5, 6, 19)  # x, y, z, 19 values per cell
soa = ps.Field.create_fixed_size("soa", shape, index_dimensions=1, layout="fzyx")
aos = ps.Field.create_fixed_size("aos", shape, index_dimensions=1, layout="zyxf")
c = ps.Field.create_fixed_size("c", shape, index_dimensions=1, layout="c")
