p = ps.fields("p(4): double[2D]")
q = ps.fields("q(4): double[2D]")
rho = sum(p(k) for k in range(4))
rules = ps.AssignmentCollection(
    [ps.Assignment(q(k), p(k) / rho + (p(k) - rho) ** 2) for k in range(4)]
)
before = rules.operation_count
rules_cse = ps.simp.sympy_cse(rules)
after = rules_cse.operation_count
