"""Build audit of one presentation6 build tree (presentation4's check_build.py on the machine profile of
machine.sh; presentation4 plan section "Build audit: -O3, flags, truly scalar").

Usage: VECTOR_MARCH=<-march=...> OBJDUMP=<disassembler> python check_build.py <tree> <scalar|vector> <gcc|clang> [target ...]
  VECTOR_MARCH: the vector trees' -march (machine.sh: -march=rv64gcv_zvl<VLEN>b; default -march=rv64gcv_zvl256b)
  OBJDUMP: llvm-objdump (default) or GNU objdump

Checks, each printed as PASS/FAIL (exit status 1 if any fails):
  1. Every compile command in <tree>/compile_commands.json (waLBerla's libraries and every app) has
     -O3 as its last -O option.
  2. On riscv64: the last -march of every command is -march=rv64gc in a scalar tree; in a vector
     tree it is VECTOR_MARCH, except for the scalar targets' own files (-march=rv64gc) and, with GCC
     and waLBerla's own flags (VLEN 256), C files without any -march: waLBerla's GNU.cmake adds -march
     to CMAKE_CXX_FLAGS only (Clang.cmake adds it to both), so GCC compiles C files (extern/sqlite3)
     with its default -march, which has no V. Such a file must not be linked into any of the given
     targets (checked in link.txt). (At other VLENs machine.sh sets -march for C files too.)
  3. -mtune: every command carries a -mtune= exactly when waLBerla's configure found that the
     compiler accepts the host's (WALBERLA_CXX_SUPPORTS_RISCV_HOST_TUNE in CMakeCache.txt; on the K1
     -mtune=spacemit-x60: Clang 18 accepts it, GCC 14 does not), and all carry the same one.
  4. The generated sources of the given targets contain no #pragma that can change the generated
     code: allowed are "#pragma once" and the warning controls "#pragma GCC/clang diagnostic ...";
     anything else (optimize, loop, unroll, ivdep, target, omp, ...) fails.
  5. RVV instructions (OBJDUMP, riscv64 only) in each given target's executable: in total, and
     in the generated kernel functions (demangled names containing "_kernels::" or "LBM_SPLIT").
     scalar targets: 0 in the whole executable. explicit targets: more than 0 in the kernels.
     autovec targets: reported only (whether the compiler vectorized the cell loop).
"""

import glob
import json
import os
import platform
import re
import shlex
import subprocess
import sys


def last(tokens, prefix):
    found = [t for t in tokens if t.startswith(prefix)]
    return found[-1] if found else None


def main():
    if len(sys.argv) < 4 or sys.argv[2] not in ("scalar", "vector") or sys.argv[3] not in ("gcc", "clang"):
        sys.exit(__doc__)
    tree, kind, compiler, targets = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4:]
    riscv = platform.machine() == "riscv64"
    vector_march = os.environ.get("VECTOR_MARCH", "-march=rv64gcv_zvl256b")
    objdump = os.environ.get("OBJDUMP", "llvm-objdump")
    ok = True

    def report(passed, what):
        nonlocal ok
        ok &= passed
        print(("PASS " if passed else "FAIL ") + what)

    cache = open(os.path.join(tree, "CMakeCache.txt")).read()
    m = re.search(r"^WALBERLA_CXX_SUPPORTS_RISCV_HOST_TUNE:INTERNAL=(.*)$", cache, re.M)
    tune_supported = bool(m and m.group(1).strip() in ("1", "ON", "TRUE"))
    m = re.search(r"^CMAKE_CXX_COMPILER:\w+=(.*)$", cache, re.M)
    print(f"== {tree}: {kind} tree, {compiler} ({m.group(1) if m else '?'}), riscv64={riscv}, "
          f"host tune flag accepted={tune_supported}, vector -march {vector_march}, objdump {objdump}")

    entries = json.load(open(os.path.join(tree, "compile_commands.json")))
    bad_o, bad_march, bad_tune, marches, gcc_c_files, tunes = [], [], [], {}, [], set()
    for e in entries:
        tokens = shlex.split(e.get("command") or " ".join(e["arguments"]))
        where = e.get("output", e["file"])
        o = last(tokens, "-O")
        if o != "-O3":
            bad_o.append(f"{o} {where}")
        if riscv:
            march = last(tokens, "-march=")
            scalar_file = kind == "scalar" or re.search(r"Sweepgen(Ldc|Lbm)CPU_scalar", where)
            expected = "-march=rv64gc" if scalar_file else vector_march
            if kind == "vector" and compiler == "gcc" and e["file"].endswith(".c") and march is None:
                expected = None
                gcc_c_files.append(where)
            marches[march] = marches.get(march, 0) + 1
            if march != expected:
                bad_march.append(f"{march} (expected {expected}) {where}")
            tune = last(tokens, "-mtune=")
            tunes.add(tune)
            if (tune is not None) != tune_supported:
                bad_tune.append(f"tune={tune} {where}")
    report(not bad_o, f"-O3 is the last -O option in all {len(entries)} compile commands"
           + "".join(f"\n     {b}" for b in bad_o[:10]))
    if riscv:
        report(not bad_march, f"-march as expected in all commands (last -march counts: {marches})"
               + "".join(f"\n     {b}" for b in bad_march[:10]))
        if gcc_c_files:
            # The library of each such file (the "<name>.dir" of its object) must not be linked into a given target
            appdir_ = os.path.join(tree, "apps", "benchmarks", "SweepgenLdcCPU")
            libs = {m.group(1) for w in gcc_c_files for m in [re.search(r"/([^/]+)\.dir/", w)] if m}
            unresolved = [w for w in gcc_c_files if not re.search(r"/([^/]+)\.dir/", w)]
            linked = [f"no library found for {w}" for w in unresolved]
            for t in targets:
                link = open(os.path.join(appdir_, "CMakeFiles", f"{t}.dir", "link.txt")).read()
                linked += [f"{t} links lib{lib}" for lib in libs if re.search(rf"lib{re.escape(lib)}\.(a|so)\b", link)]
            report(not linked, f"GCC C files without -march (waLBerla's default for C): {len(gcc_c_files)} "
                   f"(libraries {sorted(libs)}), linked into none of the {len(targets)} given targets"
                   + "".join(f"\n     {x}" for x in linked))
        report(not bad_tune and len(tunes) == 1, f"-mtune present in all commands = {tune_supported}, one value: "
               f"{sorted(map(str, tunes))} (waLBerla's configure check for {compiler})"
               + "".join(f"\n     {b}" for b in bad_tune[:10]))

    appdir = os.path.join(tree, "apps", "benchmarks", "SweepgenLdcCPU")
    for t in targets:
        gen = glob.glob(os.path.join(appdir, "_gen", t, "gen", "*.[ch]pp"))
        pragmas, harmless = [], 0
        for f in gen:
            for n, line in enumerate(open(f), 1):
                s = line.strip()
                if not s.startswith("#pragma") or s == "#pragma once":
                    continue
                if re.match(r"#pragma\s+(GCC|clang)\s+diagnostic\s", s):
                    harmless += 1
                else:
                    pragmas.append(f"{os.path.basename(f)}:{n}: {s}")
        report(bool(gen) and not pragmas, f"{t}: {len(gen)} generated files, no code-changing #pragma "
               f"({harmless} warning-control pragmas)" + "".join(f"\n     {p}" for p in pragmas[:10]))

        if not riscv:
            continue
        exe = os.path.join(appdir, t)
        if not os.path.exists(exe):
            report(False, f"{t}: executable missing")
            continue
        dis = subprocess.run([objdump, "-d", "-C", "--no-show-raw-insn", exe],
                             capture_output=True, text=True, check=True).stdout
        total, per_func, func = 0, {}, None
        for line in dis.splitlines():
            mf = re.match(r"^[0-9a-f]+ <(.*)>:$", line)
            if mf:
                func = mf.group(1)
                continue
            parts = line.split()
            if len(parts) >= 2 and re.match(r"^v[a-z]", parts[1]):
                total += 1
                if func and ("_kernels::" in func or "LBM_SPLIT" in func):
                    per_func[func] = per_func.get(func, 0) + 1
        in_kernels = sum(per_func.values())
        detail = "".join(f"\n     {n:6d} {f[:110]}" for f, n in sorted(per_func.items(), key=lambda x: -x[1]))
        family = t.replace("SweepgenLdcCPU_", "").split("_")[0]
        if family == "scalar":
            report(total == 0, f"{t}: {total} RVV instructions in the whole executable (must be 0)")
        elif family == "explicit":
            report(in_kernels > 0, f"{t}: {total} RVV instructions in total, {in_kernels} in the kernels{detail}")
        else:
            print(f"INFO {t}: {total} RVV instructions in total, {in_kernels} in the kernels{detail}")

    print("CHECK_BUILD", "PASS" if ok else "FAIL")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
