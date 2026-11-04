u, u_new = ps.fields("u, u_new: double[2D]")
alpha = sp.Symbol("alpha")                      # untyped: becomes a kernel parameter
lap = sp.Symbol("lap")                          # bound by a subexpression

ac = ps.AssignmentCollection(
    main_assignments=[ps.Assignment(u_new.center, u.center + alpha * lap)],
    subexpressions=[
        ps.Assignment(lap, u[1, 0] + u[-1, 0] + u[0, 1] + u[0, -1] - 4 * u.center)
    ],
)
heat = ps.create_kernel(ac)
