# scripts/presentation5

Timing protocol of `docs/presentation5`. Nothing here builds: every script times the executables that
`scripts/presentation4/prepare.sh` built and verified, and refuses any whose sha256 is not in its verify log.

```bash
rsync -az --exclude __pycache__ scripts/presentation5/ bananapi:/home/bananapi/saleh/my-e4-ws/scripts/presentation5/
# on the board, in /home/bananapi/saleh/my-e4-ws, detached:
screen -dmS presentation5-matrix bash -c "bash scripts/presentation5/matrix.sh > ../presentation5/logs/matrix.log 2>&1"
```

- `run.sh <cc> <prec> <cores> <variant>...`: one experiment; 60 timed steps, variants interleaved, board state logged.
- `matrix.sh`: presentation4's matrix plus the fair scalar/RVV pair (about 1 h 45 min; slowest experiment ~5 min).
- `steps_check.sh` / `steps_table.py`, `thermal_check.sh`: why 60 steps are enough
  (`docs/presentation5/presentation5-progress-opus5.5.md`).

Do not use a full `push.to.sh` (the board would rebuild the verified executables); sync this folder only.
