#!/usr/bin/env bash
# notes5 audit, board check E5 (findings F16, F17): no timing, runs after the timing jobs.
#   1. What the board's compilers make of __builtin_prefetch (slide 11: "our -march lacks Zicbop, so GCC drops
#      __builtin_prefetch"; checked so far only with the laptop's GCC 16 cross compiler).
#   2. The RISC-V ELF attributes (Tag_RISCV_arch) of the scalar executables and of the system libraries, and
#      the RVV-instruction count with and without --mattr=+v (check_build.py/run.sh count without it; llvm-objdump
#      then decodes V only if the attributes declare V), plus "<unknown>" lines.
# Start detached:
#   screen -dmS notes5-e5 bash -c "bash /home/bananapi/saleh/notes5/audit_e5.sh > /home/bananapi/saleh/notes5/e5.log 2>&1"
set -u
OUT=/home/bananapi/saleh/notes5
P4=/home/bananapi/saleh/presentation4
while screen -ls 2>/dev/null | grep -q -E "notes5-e[1234]"; do sleep 20; done
echo "== start $(date)"
T="$(mktemp -d)"
printf 'void f(const float *p) { __builtin_prefetch(p, 0, 3); __builtin_prefetch(p + 64, 1, 3); }\n' > "${T}/p.c"
for cc in gcc clang; do
    for march in rv64gcv_zvl256b rv64gcv_zvl256b_zicbop; do
        echo "== ${cc} $(${cc} --version | head -1) -O3 -march=${march}"
        ${cc} -O3 -march=${march} -S -o - "${T}/p.c" 2>&1 | grep -v -E '^\s*\.|^f:|^\s*$' | sed 's/^/   /'
    done
done
exes=( "${P4}/build-gcc-f32-scalar/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_scalar"
       "${P4}/build-clang-f32-scalar/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_scalar"
       "${P4}/build-gcc-f32/apps/benchmarks/SweepgenLdcCPU/SweepgenLdcCPU_explicit_cse_aa_pf" )
libs=( $(ldd "${exes[0]}" | awk '/=>/ {print $3}') )
for f in "${exes[@]}" "${libs[@]}"; do
    f="$(readlink -f "${f}")"
    arch="$(llvm-readelf --arch-specific "${f}" 2>/dev/null | grep -m1 -E 'Value: rv64' | sed 's/.*Value: //')"
    plain="$(llvm-objdump -d --no-show-raw-insn "${f}" 2>/dev/null | awk '$2 ~ /^v[a-z]/ {n++} END {print n+0}')"
    unk="$(llvm-objdump -d --no-show-raw-insn "${f}" 2>/dev/null | grep -c '<unknown>')"
    withv="$(llvm-objdump -d --no-show-raw-insn --mattr=+v "${f}" 2>/dev/null | awk '$2 ~ /^v[a-z]/ {n++} END {print n+0}')"
    echo "elf ${f} arch=${arch:-none} rvv_plain=${plain} unknown_plain=${unk} rvv_mattr_v=${withv}"
done
rm -rf "${T}"
echo "== E5 DONE $(date)"
