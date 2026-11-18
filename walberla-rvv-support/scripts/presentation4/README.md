# scripts/presentation4

Reproduces every number, plot and the film of `docs/presentation4`. Each figure file names its source in
its header. Full record: `docs/presentation4/presentation4-progress-opus5.5.md`.

## Board

```bash
bash push.to.sh bananapi       # laptop, once. Not again after prepare.sh: it would make the board rebuild.

# on the board, in /home/bananapi/saleh/my-e4-ws, detached:
screen -dmS presentation4-prepare bash -c "bash scripts/presentation4/prepare.sh f64 > ../presentation4/logs/prepare-f64.log 2>&1"
#   then the same with f32; both must end with PREPARE PASS (about 7 h in all)
screen -dmS presentation4-all bash -c "bash scripts/presentation4/all.sh > ../presentation4/logs/all.log 2>&1"
```

`all.sh` runs everything else, about 11 h: the timing matrix, the stream test, the second-session speedups,
the method checks, and the film (last; all 8 cores). `PARTS="streams movie"` runs only some parts;
`DRY_RUN=1` lists what it would run.

## Laptop

```bash
bash scripts/presentation4/laptop.sh
```

Makes the x86 film (built with upstream pystencils: the x86 AVX path we did not change), copies the board's
logs and film (sha256-checked; the two films compared frame by frame), runs `check_figures.py` and builds the
slides. `PARTS="x86film slides"` runs only some parts. Show with `pdfpc docs/presentation4/build/slides.pdf`.

If the board numbers change: `slide_numbers.py --tex` and `streams_table.py --tex` (on
`docs/presentation4/board-logs/board`) print the new figure coordinates; copy them into `figures/*.tex`, then
`check_figures.py` must pass.

## Good to know

- Compare timings only within one session or interleaved: the scalar baseline varied by up to 10 % between sessions.
- Board builds use 2 jobs (`JOBS=2`): 3.8 GB of RAM, no swap.
