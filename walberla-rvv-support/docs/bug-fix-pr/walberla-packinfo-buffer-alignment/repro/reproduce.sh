#!/usr/bin/env bash
# Reproduce the misaligned buffer access of waLBerla's generated pack infos, then check the patch.
#
#   bash reproduce.sh [--ref v7.4] [--work DIR] [--jobs N] [--no-patch]
#   bash reproduce.sh --quick
#
# Without --quick: clones upstream waLBerla at --ref (default v7.4) into --work (default ./walberla-repro), makes a
# venv with pystencils 1.4 and lbmpy 1.4 (what waLBerla's legacy code generation uses), builds the test
# InterpolationNoSlip (UniformGeneratedPdfPackInfo) and runs it on 1 and on 2 MPI processes. Then it applies
# ../0001-align-generated-pack-info-buffers.patch, rebuilds and runs the same plus BufferTest.
#   x86_64:  built with -fsanitize=alignment; a misaligned access is a sanitizer report in the packing kernels
#            (the program itself does not fail: x86 tolerates misaligned accesses).
#   riscv64: built with -march=rv64gcv; on cores that trap on misaligned vector accesses (e.g. SpacemiT X60) the
#            2-process run dies with SIGBUS in the auto-vectorized packing kernel.
# --quick: only compiles and runs misaligned_pack.cpp (the same loop without waLBerla), seconds instead of a build.
#
# Needs: git, cmake (>= 3.24), a C++20 compiler, MPI (mpirun; set MPIRUN_FLAGS, e.g. --oversubscribe, if needed),
# Python 3.10 to 3.12 with venv (the newest of them is taken; PYTHON=... overrides) and internet access for pip.
# Exit code: 1 if the last stage shows the bug (with the patch, or as released with --no-patch or --quick), else 0.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
PATCH="$HERE/../0001-align-generated-pack-info-buffers.patch"
URL="${WALBERLA_URL:-https://github.com/lssfau/walberla.git}"   # mirror of https://i10git.cs.fau.de/walberla/walberla
PYTHON="${PYTHON:-$(command -v python3.12 || command -v python3.11 || command -v python3.10 || command -v python3)}"
REF=v7.4 WORK="$PWD/walberla-repro" JOBS="$(nproc)" PATCHED=1 QUICK=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --ref) REF="$2"; shift 2 ;;
        --work) WORK="$(realpath -m "$2")"; shift 2 ;;
        --jobs) JOBS="$2"; shift 2 ;;
        --no-patch) PATCHED=0; shift ;;
        --quick) QUICK=1; shift ;;
        *) sed -n '2,20p' "$0"; exit 2 ;;
    esac
done

case "$(uname -m)" in
    x86_64) MODE=sanitize; FLAGS="-fsanitize=alignment"; BUILD_TYPE=RelWithDebInfo ;;
    riscv64) MODE=native; FLAGS="-march=rv64gcv"; BUILD_TYPE=Release ;;
    *) MODE=sanitize; FLAGS="-fsanitize=alignment"; BUILD_TYPE=RelWithDebInfo ;;
esac
echo "mode: $MODE ($FLAGS)"

if [[ $QUICK == 1 ]]; then
    tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
    g++ -O3 $FLAGS -o "$tmp/pack" "$HERE/misaligned_pack.cpp"
    found=0
    for offset in 0 4 6; do
        status=0
        ( "$tmp/pack" "$offset" ) > "$tmp/out" 2>&1 || status=$?
        if [[ $status -gt 128 ]]; then
            msg="killed by signal $((status - 128))$([[ $status == 135 ]] && echo ' (SIGBUS: misaligned access)')"; found=1
        elif grep -q "runtime error" "$tmp/out"; then msg="$(grep -m1 -o 'runtime error: [^,]*' "$tmp/out")"; found=1
        else msg="$(tail -n 1 "$tmp/out")"; fi
        echo "header of $offset bytes: $msg"
    done
    exit $found
fi

mkdir -p "$WORK"
cd "$WORK"
[[ -d src ]] || git -c advice.detachedHead=false clone --quiet --depth 1 --branch "$REF" "$URL" src
if [[ ! -x venv/bin/python ]]; then
    # PyPI has no NumPy wheels for riscv64: take the system's NumPy there
    "$PYTHON" -m venv $([[ $(uname -m) == riscv64 ]] && echo --system-site-packages) venv
    venv/bin/pip install --quiet --disable-pip-version-check "pystencils==1.4" "lbmpy==1.4" jinja2
fi
PRM="$WORK/src/tests/lbm_generated/InterpolationNoSlip.prm"
BIN="$WORK/build/tests/lbm_generated/InterpolationNoSlip"
found=0

build() {   # build <targets...>
    cmake -S src -B build -DCMAKE_BUILD_TYPE=$BUILD_TYPE -DCMAKE_CXX_FLAGS="$FLAGS" \
        -DCMAKE_EXE_LINKER_FLAGS="$([[ $MODE == sanitize ]] && echo "$FLAGS")" \
        -DPython_EXECUTABLE="$WORK/venv/bin/python" -DWALBERLA_BUILD_WITH_CODEGEN=ON -DWALBERLA_BUILD_TESTS=ON \
        -DWALBERLA_BUILD_WITH_MPI=ON -DWALBERLA_BUILD_WITH_PYTHON=OFF -DWALBERLA_BUILD_WITH_OPENMP=OFF \
        -DWALBERLA_OPTIMIZE_FOR_LOCALHOST=OFF > cmake.log 2>&1 || { tail -n 30 cmake.log; exit 2; }
    echo "building $* (log: $WORK/build.log) ..."
    cmake --build build -j "$JOBS" --target "$@" > build.log 2>&1 || { tail -n 30 build.log; exit 2; }
}

run() {   # run <label> <processes> [config overrides...]
    local label=$1 np=$2; shift 2
    local log="$WORK/$label.log" status=0
    UBSAN_OPTIONS=print_stacktrace=0 ${MPIRUN:-mpirun} ${MPIRUN_FLAGS:-} -np "$np" "$BIN" "$PRM" "$@" > "$log" 2>&1 \
        || status=$?
    local reports
    reports=$(grep -c "StorageSpecification.cpp.*runtime error: .*misaligned" "$log" || true)
    local verdict="ok"
    if [[ $reports -gt 0 ]]; then verdict="BUG: $reports misaligned accesses in the generated packing kernels"; found=1
    elif grep -q "Bus error\|signal 7" "$log"; then verdict="BUG: bus error (SIGBUS)"; found=1
    elif [[ $status -ne 0 ]]; then verdict="failed for another reason, see $log"; fi
    printf "  %-22s exit %-3s %s\n" "$label" "$status" "$verdict"
}

runs() {   # runs <stage>
    run "$1-1-process" 1
    run "$1-2-processes" 2 "-DomainSetup.blocks=<2,1,1>" "-DomainSetup.cellsPerBlock=<25,25,25>"
}

echo "== waLBerla $REF as released"
git -C src apply -R --check "$PATCH" 2>/dev/null && git -C src apply -R "$PATCH"   # rerun after a patched run
build InterpolationNoSlip
runs unpatched
unpatched_found=$found

if [[ $PATCHED == 1 ]]; then
    echo "== waLBerla $REF with the patch"
    git -C src apply "$PATCH"
    found=0
    build InterpolationNoSlip BufferTest
    if build/tests/core/BufferTest > BufferTest.log 2>&1; then echo "  BufferTest             ok"
    else echo "  BufferTest             FAILED, see $WORK/BufferTest.log"; found=1; fi
    runs patched
    echo "== result: as released $([[ $unpatched_found == 1 ]] && echo 'shows the bug' || echo 'shows no misaligned access'),"\
         "with the patch $([[ $found == 1 ]] && echo 'STILL shows it' || echo 'clean')"
    exit $found
fi
exit $unpatched_found
