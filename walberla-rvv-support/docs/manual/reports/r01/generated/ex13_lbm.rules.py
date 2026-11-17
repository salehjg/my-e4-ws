#   Pull streaming: population q arrives from the neighbour at x - c_q.
f = [src[-cx, -cy](q) for q, (cx, cy) in enumerate(stencil)]

subexpressions = [
    ps.Assignment(rho, sum(f)),
    ps.Assignment(ux, sum(c[0] * fq for c, fq in zip(stencil, f)) / rho),
    ps.Assignment(uy, sum(c[1] * fq for c, fq in zip(stencil, f)) / rho),
]
main = []
for q, ((cx, cy), w) in enumerate(zip(stencil, weights)):
    cu = cx * ux + cy * uy
    feq = w * rho * (1 + 3 * cu + sp.Rational(9, 2) * cu**2
                     - sp.Rational(3, 2) * (ux**2 + uy**2))
    main.append(ps.Assignment(dst(q), f[q] - omega * (f[q] - feq)))

update = ps.simp.sympy_cse(ps.AssignmentCollection(main, subexpressions))
