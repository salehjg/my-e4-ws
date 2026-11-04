@ps.kernel
def smooth(s):                  # optional argument s: a SymbolCreator
    s.avg @= (f[1, 0] + f[-1, 0]) / 2   # plain symbol -> subexpression
    g[0, 0] @= s.avg * s.weight         # s.weight is free -> kernel parameter

dec = ps.create_kernel(smooth)
