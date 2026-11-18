"""The flow of the benchmark as frames, a video and a GIF, for docs/presentation4 (slide "The flow we compute").

Usage: python3 scripts/presentation4/cavity_movie.py [--exe EXE] [--jobs N] [--work DIR] [--out DIR] [--log FILE]
                                                  [--render-only]

It runs the benchmark program itself, once per frame, each run from rest to N steps (warm-up 0),
with SWEEPGEN_LDC_DUMP set (the app writes rho and u of every cell after the run), N jobs at a time.
Default program: build/presentation4-x86-upstream/gcc-f64/.../SweepgenLdcCPU_explicit_cse_aa, the x86 build
generated with upstream pystencils (build_x86.sh with PYSTENCILS=upstream, as laptop.sh does): pystencils' x86
AVX path, which our fork does not change (same kernel code as with the fork, bit-identical fields). After
210 steps its energy agrees with the board's f64 runs to about 1e-15. 64^3 cells, lid u = (0.05, 0, 0),
omega 1.8: the benchmark's setup.

Frames: steps 16000 * (k/40)^2 for k = 0..40 (the flow changes fastest at the start), plus step 210
(the end of a timed benchmark run: 10 warm-up + 200 timed steps). Each frame shows the middle plane
of the box (the mean of the cell layers z = 31 and z = 32; the flow is mirror-symmetric in z): colour =
in-plane speed / lid speed, white lines = streamlines of the in-plane velocity.

Outputs: <out>/frame-00.png ... (in step order), <out>/cavity.avi (the video the slide plays with
pdfpc: Motion-JPEG in AVI, 8 frames per second, the last frame held 1.5 s; made by ffmpeg from the
full-colour frames; GStreamer plays it with gst-plugins-good alone), <out>/cavity.gif (for sharing),
and <log>: one line per frame with the app's result line (steps, energy, mass, field hash), so every
frame is tied to a run.
The middle planes are cached in <work>/slices.npz (default under build/, ignored), with the program's path
and result lines: --render-only redraws the frames from it without running the program again. Frames are
stored as 128-colour PNGs. On the board: cavity_movie_board.sh (same parameters, the verified RISC-V build).
"""

import argparse
import concurrent.futures as cf
import os
import pathlib
import subprocess
import sys

import numpy as np

HERE = pathlib.Path(__file__).resolve().parent
REPO = HERE.parent.parent
sys.path.insert(0, str(HERE))
from compare_fields import load_dump  # noqa: E402  (same folder; reads the app's dump format)

U_LID = 0.05
CELLS = 64


def frame_steps():
    s = sorted({round(16000 * (k / 40) ** 2) for k in range(41)} | {210})
    return s


def run_one(exe, work, n):
    prefix = work / f"s{n:06d}"
    env = dict(os.environ, SWEEPGEN_LDC_DUMP=str(prefix), OMPI_MCA_mpi_warn_on_fork="0")
    out = subprocess.run([str(exe), str(CELLS), str(n), "0"], env=env, capture_output=True, text=True, check=True)
    line = next(l for l in out.stdout.splitlines() if l.startswith("SweepgenLdcCPU variant="))
    rho, u, _ = load_dump(str(prefix))
    for f in work.glob(f"s{n:06d}.rank*.bin"):
        f.unlink()
    #   middle plane between the cell layers z = 31 and z = 32; u[component, x, y, z]
    mid = 0.5 * (u[:, :, :, CELLS // 2 - 1] + u[:, :, :, CELLS // 2])
    return n, line, mid[0], mid[1]   # f64: the cache keeps full precision (compare_movies.py)


def render(frames, outdir):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    from matplotlib.colors import PowerNorm

    outdir.mkdir(parents=True, exist_ok=True)
    for old in outdir.glob("frame-*.png"):
        old.unlink()
    x = np.arange(CELLS) + 0.5
    pngs = []
    for i, (n, ux, uy) in enumerate(frames):
        ux, uy = ux.astype(np.float32), uy.astype(np.float32)   # drawn from float32, as since the first film
        speed = np.hypot(ux, uy) / U_LID
        fig, ax = plt.subplots(figsize=(3.4, 3.2), dpi=150)
        im = ax.imshow(speed.T, origin="lower", extent=(0, CELLS, 0, CELLS), cmap="magma",
                       norm=PowerNorm(gamma=0.5, vmin=0.0, vmax=1.0), interpolation="bilinear")
        if speed.max() > 1e-6:
            ax.streamplot(x, x, ux.T, uy.T, density=1.1, color=(1, 1, 1, 0.75), linewidth=0.6, arrowsize=0.6)
        ax.set_xlim(0, CELLS)
        ax.set_ylim(0, CELLS)
        ax.set_xticks([])
        ax.set_yticks([])
        ax.annotate("", xy=(44, CELLS + 2.5), xytext=(20, CELLS + 2.5), annotation_clip=False,
                    arrowprops=dict(arrowstyle="-|>", color="0.25", lw=1.2))
        ax.text(CELLS / 2, CELLS + 4.0, "moving lid", ha="center", va="bottom", fontsize=7, color="0.25")
        ax.text(1.5, 1.5, f"step {n}", ha="left", va="bottom", fontsize=8, color="white")
        cb = fig.colorbar(im, ax=ax, fraction=0.046, pad=0.03, ticks=[0, 0.1, 0.25, 0.5, 1.0])
        cb.ax.tick_params(labelsize=6)
        cb.set_label("speed / lid speed", fontsize=7)
        fig.subplots_adjust(left=0.03, right=0.86, bottom=0.03, top=0.9)
        p = outdir / f"frame-{i:02d}.png"
        fig.savefig(p)
        plt.close(fig)
        pngs.append(p)
    return pngs


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--exe", default=str(REPO / "build/presentation4-x86-upstream/gcc-f64/apps/benchmarks/SweepgenLdcCPU/"
                                         "SweepgenLdcCPU_explicit_cse_aa"))
    ap.add_argument("--jobs", type=int, default=16)
    ap.add_argument("--work", default=str(REPO / "build/presentation4-x86-upstream/cavity-movie-work"))
    ap.add_argument("--out", default=str(REPO / "docs/presentation4/figures/cavity-movie"))
    ap.add_argument("--log", default=str(REPO / "docs/presentation4/board-logs/x86/cavity-movie.log"))
    ap.add_argument("--render-only", action="store_true",
                    help="no runs: render from <work>/slices.npz, written by an earlier full run")
    a = ap.parse_args()
    exe, work, out = pathlib.Path(a.exe), pathlib.Path(a.work), pathlib.Path(a.out)
    work.mkdir(parents=True, exist_ok=True)
    steps = frame_steps()
    cache = work / "slices.npz"
    if a.render_only:
        d = np.load(cache, allow_pickle=False)
        results = {int(n): (str(l), ux, uy) for n, l, ux, uy in zip(d["steps"], d["lines"], d["ux"], d["uy"])}
        if "exe" in d.files:   # the program that made the cached runs (caches from before this field: --exe)
            exe = pathlib.Path(str(d["exe"]))
    else:
        results = {}
        #   longest runs first, so the pool finishes together
        with cf.ThreadPoolExecutor(max_workers=a.jobs) as pool:
            futs = [pool.submit(run_one, exe, work, n) for n in sorted(steps, reverse=True)]
            for f in cf.as_completed(futs):
                n, line, ux, uy = f.result()
                results[n] = (line, ux, uy)
                print(f"done step {n}", flush=True)
        np.savez(cache, exe=np.array(str(exe)), steps=np.array(steps), lines=np.array([results[n][0] for n in steps]),
                 ux=np.array([results[n][1] for n in steps]), uy=np.array([results[n][2] for n in steps]))
    frames = [(n, results[n][1], results[n][2]) for n in steps]
    pngs = render(frames, out)
    #   the video, from the full-colour frames (before they are reduced below)
    subprocess.run(["ffmpeg", "-y", "-loglevel", "error", "-framerate", "8", "-i", str(out / "frame-%02d.png"),
                    "-vf", "tpad=stop_mode=clone:stop_duration=1.5,format=yuvj420p", "-c:v", "mjpeg", "-q:v", "2",
                    str(out / "cavity.avi")], check=True)
    #   128-colour palette: a quarter of the size, visually the same (PSNR about 39 dB against full colour)
    from PIL import Image
    imgs = []
    for p in pngs:
        q = Image.open(p).convert("RGB").quantize(colors=128, method=Image.Quantize.MEDIANCUT,
                                                   dither=Image.Dither.NONE)
        q.save(p, optimize=True)
        imgs.append(q)
    durations = [120] * len(imgs)
    durations[-1] = 1500   # hold the developed flow
    imgs[0].save(out / "cavity.gif", save_all=True, append_images=imgs[1:], duration=durations, loop=0,
                 optimize=True)
    with open(a.log, "w") as fh:
        fh.write(f"# scripts/presentation4/cavity_movie.py, program {exe}\n")
        fh.write(f"# frame index: steps, then the app's result line (64^3, warm-up 0)\n")
        for i, n in enumerate(steps):
            fh.write(f"frame-{i:02d} steps={n} {results[n][0]}\n")
    print(f"{len(pngs)} frames in {out}, video {out / 'cavity.avi'}, GIF {out / 'cavity.gif'}, log {a.log}")


if __name__ == "__main__":
    main()
