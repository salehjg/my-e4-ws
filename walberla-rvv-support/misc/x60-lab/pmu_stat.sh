#!/usr/bin/env bash
# Vendor-PMU counter campaign on the X60 for one command, with startup subtracted.
#
# Usage (on the board):  bash pmu_stat.sh OUT.tsv CELLS STEPS -- BINARY
#   Runs BINARY CELLS STEPS 0 once per event group (taskset -c ${CPU:-2}), and once more
#   with 0 steps for every group, so the per-cell numbers exclude init/teardown:
#       per_cell(e) = (count(e, STEPS) - count(e, 0)) / (CELLS^3 * STEPS)
#   Each group has at most 6 events, so no counter multiplexing.
set -euo pipefail
OUT=$1; CELLS=$2; STEPS=$3; shift 4
BIN=("$@")
CPU=${CPU:-2}
GROUPS_=(
  "cycles,instructions,u_mode_cycle,stalled_cycle_backend,stalled_cycle_frontend"
  "l1d_load_access,l1d_load_miss,l1d_store_access,l1d_store_miss,l1d_prefetch_hit,l1d_prefetch_refill"
  "l2_access,l2_load_access,l2_store_access,l2_miss,l2_load_stall,l2_store_stall"
  "vector_inst,vector_load_inst,vector_store_inst,vector_div_inst,vpu_vlsu_stall_pipe0,vpu_vlsu_stall_pipe1"
  "lsu_load_commit_stall,lsu_store_commit_stall,eu_lsu_load_full,eu_lsu_store_full,rf_raw_stall,eu_vfpu_full"
  "vidu_vec0_depend_stall,vidu_vec1_depend_stall,vpu_stall_pipe0,vpu_stall_pipe1,vidu_vec0_struct_hazard_stall,vpu_hazard_stall_pipe0"
  "dtlb_load_miss,dtlb_store_miss,jtlb_miss,l1d_excl_evict,l1d_miss,issued_inst"
)
: > "$OUT"
for g in "${GROUPS_[@]}"; do
  for s in "$STEPS" 0; do
    taskset -c "$CPU" perf stat -x, -e "$g" -o "$OUT.tmp" "${BIN[@]}" "$CELLS" "$s" 0 > "$OUT.app" 2>&1 || true
    grep -v '^#' "$OUT.tmp" | grep -v '^$' | awk -F, -v s="$s" '{print s"\t"$3"\t"$1}' >> "$OUT"
    [[ "$s" != 0 ]] && grep -o 'mlups=[0-9.]*' "$OUT.app" | sed "s/^/$s\tmlups\t/;s/mlups=//" >> "$OUT" || true
  done
done
rm -f "$OUT.tmp" "$OUT.app"
