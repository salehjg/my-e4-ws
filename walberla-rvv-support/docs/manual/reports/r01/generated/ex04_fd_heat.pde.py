c, c_next = ps.fields("c, c_next: double[2D]")
D = sp.Symbol("D")

pde = ps.fd.transient(c) - ps.fd.diffusion(c, D)     # dc/dt = div(D grad c)
discretize = ps.fd.Discretization2ndOrder(dx=1, dt=sp.Rational(1, 10))
rhs = discretize(pde)                                 # explicit Euler + central FD

heat_step = ps.create_kernel(ps.Assignment(c_next.center, rhs)).compile()
