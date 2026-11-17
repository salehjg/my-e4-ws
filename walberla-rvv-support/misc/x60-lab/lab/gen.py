"""D3Q19 kernel lab: dump waLBerla's SweepgenLbmCPU StreamCollide kernel as standalone C++.

The update rule is built exactly like sweepgen's `LbmBulk` does it for
`apps/benchmarks/SweepgenLbmCPU` (D3Q19, SRT, compressible, relaxation rate `omega`,
`LBMOptimisation(simplification="auto", cse_global=..., field_layout="fzyx")`, pull streaming,
density and velocity written as outputs), and the kernel is created with ghost_layers=0, as
sweepgen does (the wrapper hands in pointers to the first interior cell).

Every kernel becomes two translation units, compiled separately so the strides stay runtime
values, as in waLBerla:
  NAME.cpp       generated kernel `kernel(...)` (C linkage), optionally post-processed
  NAME.wrap.cpp  `run_kernel(f, ftmp, rho, u, n0, n1, n2, sf1, sf2, sf3, sr1, sr2, su1, su2, su3, s0, omega)`
The pseudo-edit 'vf2' only labels the file (see emit()).
With the pseudo-edit 'aa' the update rule uses lbmpy's in-place AA streaming pattern instead of
pull: NAME.cpp holds `kernel_even` and `kernel_odd` (one PDF field), and the wrapper is
`run_kernel_aa(f, rho, u, n0, n1, n2, sf1, sf2, sf3, sr1, sr2, su1, su2, su3, parity, omega)`
(the lab driver calls it when AA=1).

Usage: python gen.py OUTDIR [variant ...]     (PYTHONPATH=submodules/pystencils/src, lbmpy installed)
Variants are dtype-target-flavour, e.g. f32-rvv-cse; see VARIANTS below and edits.py.
"""

import pathlib
import re
import sys

import sympy as sp
import pystencils as ps
from lbmpy import LBStencil, Stencil, LBMConfig, LBMOptimisation, Method, create_lb_update_rule
from lbmpy.advanced_streaming.utility import Timestep

sys.path.insert(0, str(pathlib.Path(__file__).parent))
import edits  # noqa: E402

DTYPES = {"f64": ("float64", "double"), "f32": ("float32", "float")}


def update_rule(dtype: str, cse_global: bool, timestep: Timestep | None = None):
    """Pull streaming (two fields) by default; `timestep` EVEN/ODD selects lbmpy's AA pattern."""
    stencil = LBStencil(Stencil.D3Q19)
    cfg = LBMConfig(stencil=stencil, method=Method.SRT, compressible=True, relaxation_rate=sp.Symbol("omega"))
    if timestep is not None:
        cfg.streaming_pattern = "aa"
        cfg.timestep = timestep
    opt = LBMOptimisation(simplification="auto", cse_global=cse_global, field_layout="fzyx")
    Q, D = stencil.Q, stencil.D
    opt.symbolic_field = ps.Field.create_generic("f", spatial_dimensions=D, index_shape=(Q,), layout="fzyx", dtype=dtype)
    opt.symbolic_temporary_field = ps.Field.create_generic(
        "f_tmp", spatial_dimensions=D, index_shape=(Q,), layout="fzyx", dtype=dtype
    )
    rho, u = ps.fields(f"rho, u({D}): {dtype}[{D}D]", layout="fzyx")
    return create_lb_update_rule(lbm_config=cfg, lbm_optimisation=opt, output={"density": rho, "velocity": u})


def kernel_config(target: str, dtype: str):
    if target == "rvv":
        cfg = ps.CreateKernelConfig(target=ps.Target.RISCV_RVV, default_dtype=dtype, ghost_layers=0)
        cfg.cpu.vectorize.enable = True
        cfg.cpu.vectorize.assume_inner_stride_one = True
    else:
        cfg = ps.CreateKernelConfig(target=ps.Target.GenericCPU, default_dtype=dtype, ghost_layers=0)
    return cfg


WRAP = {
    r"_data_f": "f", r"_data_f_tmp": "ftmp", r"_data_rho": "rho", r"_data_u": "u",
    r"_size_f_0": "n0", r"_size_f_1": "n1", r"_size_f_2": "n2",
    r"_stride_f_1": "sf1", r"_stride_f_2": "sf2", r"_stride_f_3": "sf3",
    r"_stride_f_tmp_1": "sf1", r"_stride_f_tmp_2": "sf2", r"_stride_f_tmp_3": "sf3",
    r"_stride_rho_1": "sr1", r"_stride_rho_2": "sr2",
    r"_stride_u_1": "su1", r"_stride_u_2": "su2", r"_stride_u_3": "su3",
    r"omega": "omega",
    #   inner strides (generic kernels only): a runtime 1, as in waLBerla's scalar sweeps
    r"_stride_f_0": "s0", r"_stride_f_tmp_0": "s0", r"_stride_rho_0": "s0", r"_stride_u_0": "s0",
}


def emit(dt_key: str, target: str, flavour: str) -> tuple[str, str, dict]:
    """flavour: 'cse' or 'nocse', optionally followed by '+edit1+edit2' (see edits.py).

    The pseudo-edit 'bpf=D' is not a text edit: it sets the pystencils option
    `cpu.vectorize.prefetch_distance = D` (the backend implementation of edits.py's 'pf').
    """
    base, *edit_names = flavour.split("+")
    dtype, ctype = DTYPES[dt_key]
    aa = "aa" in edit_names
    #   'vf2' is a label only: kernels generated after the RVV selector learned .vf operands and
    #   fused multiply-adds (docs/notes3 Loop 10), kept apart from the older files for A/B runs.
    #   'cg' likewise: generated after pystencils learned row pointers and constants in registers
    #   (Loop 12: HoistRowPointers, rvv::in_register)
    edit_names = [e for e in edit_names if e not in ("aa", "vf2", "cg")]
    if aa:
        rules = [("kernel_even", update_rule(dtype, base == "cse", Timestep.EVEN)),
                 ("kernel_odd", update_rule(dtype, base == "cse", Timestep.ODD))]
    else:
        rules = [("kernel", update_rule(dtype, base == "cse"))]
    bpf = [int(e.split("=")[1]) for e in edit_names if e.startswith("bpf=")]
    edit_names = [e for e in edit_names if not e.startswith("bpf=")]
    stats = {}
    codes, headers, protos, calls = [], set(), [], {}
    for fname, rule in rules:
        cfg = kernel_config(target, dtype)
        cfg.function_name = fname
        for d in bpf:
            cfg.cpu.vectorize.prefetch_distance = d
        kernel = ps.create_kernel(rule, cfg)
        code = kernel.get_c_code()
        for e in edit_names:
            code, st = edits.apply(e, code, target=target, ctype=ctype)
            stats[e] = st
        codes.append(code)
        headers |= set(kernel.required_headers)
        params, args = [], []
        for p in kernel.parameters:
            if p.name.startswith("_data_"):
                params.append(f"{ctype} * {p.name}")
            elif p.name == "omega":
                params.append(f"{ctype} omega")
            else:
                params.append(f"int64_t {p.name}")
            if p.name not in WRAP:
                raise ValueError(f"unexpected parameter {p.name}")
            args.append(WRAP[p.name])
        protos.append(f'extern "C" void {fname}({", ".join(params)});')
        calls[fname] = f"{fname}({', '.join(args)});"
    header = f"// generated by misc/x60-lab/lab/gen.py: {dt_key}-{target}-{flavour} edits={stats}"
    kernel_tu = "\n".join(
        [header]
        + [f"#include {h}" for h in sorted(headers)]
        + ["#define RESTRICT __restrict__", "", 'extern "C" {', *codes, '}  // extern "C"', ""]
    )
    if aa:
        signature = [
            f'extern "C" void run_kernel_aa({ctype} * f, {ctype} * rho, {ctype} * u, int64_t n0, int64_t n1,',
            "    int64_t n2, int64_t sf1, int64_t sf2, int64_t sf3, int64_t sr1, int64_t sr2, int64_t su1, int64_t su2,",
            f"    int64_t su3, int parity, {ctype} omega)",
            "{",
            "   const int64_t s0 = 1;",
            "   (void)s0;",
            f"   if (parity == 0) {calls['kernel_even']}",
            f"   else {calls['kernel_odd']}",
            "}",
        ]
    else:
        signature = [
            f'extern "C" void run_kernel({ctype} * f, {ctype} * ftmp, {ctype} * rho, {ctype} * u, int64_t n0, int64_t n1,',
            "    int64_t n2, int64_t sf1, int64_t sf2, int64_t sf3, int64_t sr1, int64_t sr2, int64_t su1, int64_t su2,",
            f"    int64_t su3, int64_t s0, {ctype} omega)",
            "{",
            f"   {calls['kernel']}",
            "}",
        ]
    wrapper_tu = "\n".join([header + " (wrapper)", "#include <cstdint>", *protos, *signature, ""])
    return kernel_tu, wrapper_tu, stats


def main():
    out = pathlib.Path(sys.argv[1])
    out.mkdir(parents=True, exist_ok=True)
    for name in sys.argv[2:]:
        dt_key, target, flavour = name.split("-", 2)
        k, w, stats = emit(dt_key, target, flavour)
        (out / f"{name}.cpp").write_text(k)
        (out / f"{name}.wrap.cpp").write_text(w)
        print(f"wrote {name} {stats}")


if __name__ == "__main__":
    main()
