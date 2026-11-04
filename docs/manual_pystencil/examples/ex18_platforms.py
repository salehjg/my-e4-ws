"""Chapter 10: one kernel, every vector CPU platform (code generation only)."""

from _manual import save

import sympy as sp
import pystencils as ps

# [kernel]
f, g = ps.fields("f, g: double[1D]")
c = sp.Symbol("c")
asm = ps.Assignment(g.center, c * f.center + 1)


def vector_kernel(target, lanes=None):
    cfg = ps.CreateKernelConfig(target=target)
    cfg.cpu.vectorize.enable = True
    cfg.cpu.vectorize.assume_inner_stride_one = True
    if lanes is not None:
        cfg.cpu.vectorize.lanes = lanes      # required for ARM_SVE
    return ps.create_kernel(asm, cfg)
# [/kernel]


targets = [
    (ps.Target.X86_SSE, None), (ps.Target.X86_AVX, None), (ps.Target.X86_AVX512, None),
    (ps.Target.ARM_NEON, None), (ps.Target.ARM_SVE, 4), (ps.Target.RISCV_RVV, None),
]
blocks = []
for target, lanes in targets:
    k = vector_kernel(target, lanes)
    code = k.get_c_code()
    #   The single statement of the vectorized loop body: a vector store.
    stmt = next((ln.strip() for ln in code.splitlines() if "(&_data_g[ctr_0]" in ln
                 or "&_data_g[ctr_0]," in ln), None)
    assert stmt is not None, f"{target.name}:\n{code}"
    extra = ""
    if target == ps.Target.ARM_SVE:
        pred = next(ln.strip() for ln in code.splitlines() if "svwhilelt" in ln)
        extra = f"\n  predicate: {pred}"
    headers = [h for h in sorted(k.required_headers) if "runtime/" in h and "generic" not in h]
    blocks.append(f"{target.name}  (header {', '.join(headers)}){extra}\n  {stmt}")
save("comparison", "\n\n".join(blocks))

#   Feature matrix: which vectorized operations each platform can materialize.
f2, g2 = ps.fields("f2, g2: double[2D]")
w = ps.TypedSymbol("w", "double")
probes = {
    "sqrt": ps.Assignment(g2.center, sp.sqrt(f2.center)),
    "min": ps.Assignment(g2.center, sp.Min(f2.center, 1.0)),
    "floor": ps.Assignment(g2.center, sp.floor(f2.center)),
    "exp": ps.Assignment(g2.center, sp.exp(f2.center)),
    "sum": ps.AddReductionAssignment(w, f2.center),
    "strided": ps.Assignment(g2.center, f2.center),   # without assume_inner_stride_one
}
rows = [f"{'target':<12}" + "".join(f"{k:>9}" for k in probes)]
for target, lanes in targets:
    cells = []
    for name, probe in probes.items():
        cfg = ps.CreateKernelConfig(target=target, ghost_layers=0)
        cfg.cpu.vectorize.enable = True
        cfg.cpu.vectorize.assume_inner_stride_one = name != "strided"
        if lanes is not None:
            cfg.cpu.vectorize.lanes = lanes
        try:
            ps.create_kernel(probe, cfg)
            cells.append("yes")
        except Exception:  # noqa: BLE001
            cells.append("-")
    rows.append(f"{target.name:<12}" + "".join(f"{c:>9}" for c in cells))
save("matrix", "\n".join(rows))
