u = ps.fields("u: double[3D]")
v = ps.fields("v(2): double[2D]")

u.center            # u[0,0,0]   the current cell
u[1, 0, 0]          # east neighbour (x + 1)
u["N"], u["T"]      # compass names: N/S = y, E/W = x, T/B = z
u[1, -1, 0]         # south-east
v(1)                # index access in the centre: second component
v[1, 0](1)          # second component of the east neighbour
v.center_vector     # sympy Matrix of all components
