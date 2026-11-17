f, g = ps.fields("f, g: double[2D]")
x, y = sp.symbols("x, y")


@ps.flow.block
def compute(_eq):
    _eq.let[x] = 2 * f.center           # private to this block
    _eq.export[y] = x + 1               # visible to successor blocks


@ps.flow.cases(preds=[compute])
def store(cs):
    @cs.case(y > 0)
    def positive(_eq):
        _eq.store[g.center] = y

    @cs.case(True)                      # default case
    def other(_eq):
        _eq.store[g.center] = 0


graph = ps.flow.tie(store, name="clamp")
k_flow = ps.create_kernel(graph)
