"""LBM kernels of pystencils 1.4 / lbmpy 1.4, vectorized for RVV, run under QEMU and compared with the host.

Each kernel is generated once per instruction set (upstream `rvv` and options of our `rvv_ext`), cross-compiled
with `riscv64-linux-gnu-g++ -static`, run under `qemu-riscv64 -cpu rv64,v=true,vlen=<N>`, and its output arrays are
compared with the same kernel generated without vectors and run through the host JIT. The fields have fixed shapes
(an odd x extent, so the last vector of a row is a partial one), so the kernels take only data pointers and scalars.

Kernels: d3q19_srt (pull, aa_even, aa_odd) and wind: waLBerla-wind's D3Q27 cumulant + Guo + QR kernel
(apps/GeneratedApp_cpu_uniform/LBMGeneration.py), pull.

Usage (laptop, from walberla-rvv-support, venv of docs/notes8):
  PYTHONPATH=submodules/pystencils/src ../.venv-legacy/bin/python scripts/notes8/lbm_qemu_check.py \
      [--kernels d3q19_srt,wind] [--dtype float64|float32] [--isa rvv,rvv_ext-vf-fma] [--vlen 128,256]
Prints one line per (kernel, instruction set, VLEN) and PASS or FAIL at the end.
"""

import argparse
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

import numpy as np
import sympy as sp

import pystencils as ps
from pystencils.backends.cbackend import get_headers
from pystencils.include import get_pystencils_include_path
from lbmpy import LBMConfig, LBMOptimisation, LBStencil, Method, Stencil, ForceModel, create_lb_update_rule
from lbmpy.advanced_streaming import Timestep
from lbmpy.turbulence_models import SubgridScaleModel

SHAPE = (13, 6, 5)  # x, y, z, ghost layers included
SENTINEL = -7.0  # initial value of output arrays: cells a kernel must not write keep it
OMEGA = 1.6


def update_rules(name, dtype):
    """name -> (variant -> update rule, lb method)"""
    if name == "d3q19_srt":
        stencil = LBStencil(Stencil.D3Q19)
    else:
        stencil = LBStencil(Stencil.D3Q27)
    q = stencil.Q
    pdfs, pdfs_tmp = ps.fields(f"pdfs({q}), pdfs_tmp({q}): {dtype}[{SHAPE[0]}, {SHAPE[1]}, {SHAPE[2]}]",
                               layout="fzyx")
    rho = ps.fields(f"density: {dtype}[{SHAPE[0]}, {SHAPE[1]}, {SHAPE[2]}]", layout="fzyx")
    u = ps.fields(f"velocity(3): {dtype}[{SHAPE[0]}, {SHAPE[1]}, {SHAPE[2]}]", layout="fzyx")
    output = {"density": rho, "velocity": u}
    omega = sp.Symbol("omega")

    if name == "d3q19_srt":
        def config(pattern, timestep=Timestep.BOTH):
            return LBMConfig(stencil=stencil, method=Method.SRT, relaxation_rate=omega, compressible=True,
                             streaming_pattern=pattern, timestep=timestep, output=output)
        variants = {"pull": config("pull"), "aa_even": config("aa", Timestep.EVEN),
                    "aa_odd": config("aa", Timestep.ODD)}
    else:
        force = ps.fields(f"force(3): {dtype}[{SHAPE[0]}, {SHAPE[1]}, {SHAPE[2]}]", layout="fzyx")
        omega_out = ps.fields(f"omega_out: {dtype}[{SHAPE[0]}, {SHAPE[1]}, {SHAPE[2]}]", layout="fzyx")
        nut = ps.fields(f"eddy_viscosity: {dtype}[{SHAPE[0]}, {SHAPE[1]}, {SHAPE[2]}]", layout="fzyx")
        variants = {"pull": LBMConfig(
            stencil=stencil, streaming_pattern="pull", method=Method.CUMULANT, relaxation_rate=omega,
            galilean_correction=True, fourth_order_correction=0.1, force_model=ForceModel.GUO,
            force=force.center_vector, subgrid_scale_model=SubgridScaleModel.QR, compressible=True,
            zero_centered=True, omega_output_field=omega_out, eddy_viscosity_field=nut, output=output)}

    rules = {}
    for variant, cfg in variants.items():
        temporary = pdfs_tmp if variant == "pull" else None
        opt = LBMOptimisation(field_layout="fzyx", symbolic_field=pdfs, symbolic_temporary_field=temporary,
                              cse_global=True)
        rules[variant] = create_lb_update_rule(lbm_config=cfg, lbm_optimisation=opt)
    return rules


def create(rule, dtype, instruction_set, function_name):
    vec = None if instruction_set is None else {"instruction_set": instruction_set, "assume_inner_stride_one": True}
    config = ps.CreateKernelConfig(data_type=dtype, default_number_float=dtype, cpu_vectorize_info=vec,
                                   function_name=function_name)
    return ps.create_kernel(rule, config=config)


def initial_arrays(ast, method, dtype):
    """Raw arrays (index slowest, x fastest, as fzyx memory) of every field parameter, by parameter name."""
    rng = np.random.default_rng(3)
    weights = np.array([float(w) for w in method.weights])
    arrays = {}
    for p in ast.get_parameters():
        if not p.is_field_pointer:
            continue
        field = p.fields[0]
        raw_shape = tuple(field.index_shape) + tuple(field.spatial_shape)[::-1]
        if field.name == "pdfs":
            noise = 1 + 0.05 * rng.uniform(-1, 1, raw_shape)
            arr = weights.reshape((-1, 1, 1, 1)) * noise
        elif field.name == "force":
            arr = 1e-4 * rng.uniform(-1, 1, raw_shape)
        else:
            arr = np.full(raw_shape, SENTINEL)
        arrays[p.symbol.name] = arr.astype(dtype)
    return arrays


def host_run(ast, arrays):
    arrays = {n: a.copy() for n, a in arrays.items()}
    kwargs = {n.removeprefix("_data_"): a.transpose(tuple(range(a.ndim))[::-1]) for n, a in arrays.items()}
    kwargs["omega"] = OMEGA
    ast.compile()(**kwargs)
    return arrays


def program(asts, arrays_of):
    """C++ program: runs every kernel once, prints its arrays in hex."""
    headers, functions, main = set(), [], []
    for name, ast in asts.items():
        headers |= get_headers(ast)
        functions.append(ps.get_code_str(ast))
        args = []
        for p in ast.get_parameters():
            if not p.is_field_pointer:
                args.append(repr(OMEGA))
                continue
            arr = arrays_of[name][p.symbol.name]
            ctype = "double" if arr.dtype == np.float64 else "float"
            values = ", ".join(float(x).hex() for x in arr.ravel())
            main.append(f"static {ctype} {name}{p.symbol.name}[{arr.size}] = {{{values}}};")
            args.append(name + p.symbol.name)
        main.append(f"{name}({', '.join(args)});")
        for p in ast.get_parameters():
            if p.is_field_pointer:
                n = arrays_of[name][p.symbol.name].size
                main.append(f'for (int i = 0; i < {n}; ++i) printf("{name} {p.symbol.name} %d %a\\n", i, '
                            f'(double) {name}{p.symbol.name}[i]);')
    lines = ["#include <cstdint>", "#include <cstddef>", "#include <cstdio>", "#include <cmath>"]
    lines += [f"#include {h}" for h in sorted(headers)]
    lines += ["#define RESTRICT __restrict__", "#define FUNC_PREFIX static"]
    return "\n".join(lines + functions + ["int main()", "{"] + main + ["return 0;", "}"])


def run_under_qemu(source, march, vlen, workdir):
    exe = workdir / "kernels"
    cmd = ["riscv64-linux-gnu-g++", "-std=c++17", "-O2", "-static", march, f"-I{get_pystencils_include_path()}",
           "-x", "c++", "-", "-o", str(exe)]
    built = subprocess.run(cmd, input=source, capture_output=True, text=True)
    if built.returncode != 0:
        raise RuntimeError(built.stderr[-3000:])
    ran = subprocess.run(["qemu-riscv64", "-cpu", f"rv64,v=true,vlen={vlen}", str(exe)],
                         capture_output=True, text=True, timeout=600)
    if ran.returncode != 0:
        raise RuntimeError(ran.stderr[-3000:])
    values = {}
    for line in ran.stdout.splitlines():
        name, param, idx, val = line.split()
        values.setdefault((name, param), []).append(float.fromhex(val))
    return values


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--kernels", default="d3q19_srt,wind")
    parser.add_argument("--dtype", default="float64", choices=["float64", "float32"])
    parser.add_argument("--isa", default="rvv,rvv_ext-vf-fma,rvv_ext-vf-fma-pf128,rvv_ext-vls128-vf-fma-pf128")
    parser.add_argument("--vlen", default="128,256")
    args = parser.parse_args()
    for tool in ("riscv64-linux-gnu-g++", "qemu-riscv64"):
        if shutil.which(tool) is None:
            sys.exit(f"needs {tool}")

    dtype = args.dtype
    rtol, atol = (1e-10, 1e-13) if dtype == "float64" else (2e-4, 1e-6)
    failures = 0
    for kernel in args.kernels.split(","):
        rules = update_rules(kernel, dtype)
        method = next(iter(rules.values())).method
        reference, inputs = {}, {}
        for variant, rule in rules.items():
            ast = create(rule, dtype, None, variant)
            inputs[variant] = initial_arrays(ast, method, dtype)
            reference[variant] = host_run(ast, inputs[variant])
        for isa in args.isa.split(","):
            asts = {variant: create(rule, dtype, isa, variant) for variant, rule in rules.items()}
            vls = [int(t[3:]) for t in isa.split("-") if t.startswith("vls")]
            march = f"-march=rv64gcv_zvl{vls[0]}b" if vls else "-march=rv64gcv"
            source = program(asts, inputs)
            for vlen in (int(v) for v in args.vlen.split(",")):
                if vls and vlen < vls[0]:
                    continue
                with tempfile.TemporaryDirectory() as tmp:
                    got = run_under_qemu(source, march, vlen, Path(tmp))
                for variant, expected_arrays in reference.items():
                    worst = 0.0
                    ok = True
                    for param, expected in expected_arrays.items():
                        actual = np.array(got[(variant, param)], dtype=expected.dtype).reshape(expected.shape)
                        same_cells = np.array_equal(actual == SENTINEL, expected == SENTINEL)
                        close = np.allclose(actual, expected, rtol=rtol, atol=atol)
                        ok = ok and same_cells and close
                        #   error relative to the array's scale: velocities are close to 0, so a per-value ratio
                        #   would only show float rounding near zero
                        written = expected != SENTINEL
                        scale = max(float(np.max(np.abs(expected[written]))), 1e-30)
                        worst = max(worst, float(np.max(np.abs(actual - expected)[written])) / scale)
                    failures += not ok
                    print(f"{kernel:10s} {variant:8s} {isa:32s} VLEN {vlen:4d}  max diff / array max {worst:.2e}  "
                          f"{'ok' if ok else 'WRONG'}", flush=True)
    print("PASS" if failures == 0 else f"FAIL ({failures} wrong)")
    sys.exit(1 if failures else 0)


if __name__ == "__main__":
    main()
