# notes5: audit of the RVV work and of presentation4 (Opus 5.5, 2026-11-19/20)

- `audit-findings-opus5.5.md`: the findings F1-F21 (severity, repo/commit/file:line, evidence, affected slides,
  fix), the board experiments E1-E10, and the resolution status. Start with its summary table.
- `proposed-slide-changes-opus5.5.md`: concrete replacement text per slide and per file. Not applied.
- `board/`: the board scripts (`audit_e1.sh` ... `audit_e10.sh`, each documents its question and how to start it
  detached in `screen`) and the probe `stream_order.cpp`.
- `board-logs/`: the raw logs of E1-E10, copied from `/home/bananapi/saleh/notes5/` on the board.

The audit changed nothing in `docs/presentation4/`, `scripts/`, the forks or the board's presentation4 builds;
it only ran the verified presentation4 executables (sha256 checked) and its own probes.
