#!/usr/bin/env python3
"""Animations of the benchmarks' flows (README.md), apart from the timing: an animation run writes VTK files and is
never timed, and a timing run writes none (waLBerla-wind's app adds its VTK output only when asked to).

    python3 scripts-legacy/bench.py animate <experiment> [--variant V] [--steps N] [--every K] [--np N]
    python3 scripts-legacy/bench.py render <animation folder>

bench.py runs `render` as `<venv python> animation.py <folder>`, after installing pyvista and matplotlib into the
venv if they are missing. They need VTK, which has no riscv64 wheels: on the boards only `animate`, then
`remote.py fetch` and `render` on the laptop.
"""
from __future__ import annotations

import json
import platform
import secrets
import shutil
import subprocess
import sys
import time
from pathlib import Path

sys.dont_write_bytecode = True  # no __pycache__ next to the scripts
import bench
from experiments import App

# What a frame shows, per app: the VTK array, the slice through the middle of the domain (the normal axis) and the
# velocity component (None: the magnitude).
VIEWS = {
    App.WIND.value: ("velocity", "y", None),  # x-z: the boundary layer over the ground, flow from left to right
    App.UGC.value: ("vel", "y", 0),           # x-z: the shear flow, u_x > 0 in the upper half, < 0 in the lower
}


class Animation:
    """One animation folder, <work>/animations/<time>-<random>/: animation.json (what ran), app.log, vtk_out/ (the
    app's VTK files, one .pvd series), and after render frames/<n>.png and animation.gif."""

    def __init__(self, folder):
        self.folder = Path(folder).resolve()

    @classmethod
    def simulate(cls, machine, m, name, e, v, steps, every, n):
        """Configure, build the one variant, run it once (n processes, one cells^3 block each, no warmup) with VTK
        output every `every` steps. No time limit: on monte3 the slurm job's limit stops it."""
        b = e.build
        bench.configure(m, b)
        bench.build(m, b, [v])
        exe = bench.executable(m, b, v)
        if b.app is App.WIND:  # an Output.VTK block from the command line (waLBerla creates missing blocks)
            output = [f"-Output.VTK.writeFrequency={every}", "-Output.VTK.fields.velocity=1"]
        else:
            output = [f"-Parameters.vtkWriteFrequency={every}"]
        cmd = bench.app_command(m, b, e.cells, exe, n, 0, steps) + output
        self = cls(bench.folder(m.work) / "animations" / f"{time.strftime('%Y%m%d-%H%M%S')}-{secrets.token_hex(3)}")
        self.folder.mkdir(parents=True)
        info = dict(format=1, started=time.strftime("%Y-%m-%dT%H:%M:%S%z"), finished=None, machine=machine,
                    host=platform.node(), experiment=name, build=b.name, app=b.app.value, precision=b.precision,
                    variant=bench.label(v), steps=steps, every=every, processes=n, cells=e.cells, command=cmd,
                    returncode=None, **bench.describe_executable(exe), source=bench.source_info())
        self.save(info)
        print(f"{self.folder}\n+ {' '.join(cmd)}", flush=True)
        vtk = exe.parent / "vtk_out"  # both apps write it into their working directory
        shutil.rmtree(vtk, ignore_errors=True)
        with open(self.folder / "app.log", "w") as log:
            info["returncode"] = subprocess.run(cmd, cwd=exe.parent, stdout=log, stderr=subprocess.STDOUT).returncode
        if vtk.exists():
            shutil.move(vtk, self.folder / "vtk_out")
        info["finished"] = time.strftime("%Y-%m-%dT%H:%M:%S%z")
        self.save(info)
        if info["returncode"] != 0 or not (self.folder / "vtk_out").exists():
            sys.exit(f"the run failed (return code {info['returncode']}): {self.folder / 'app.log'}")
        print(f"VTK files in {self.folder / 'vtk_out'}; frames and GIF: bench.py render {self.folder}")
        return self

    def save(self, info):
        (self.folder / "animation.json").write_text(json.dumps(info, indent=2) + "\n")

    def render(self, seconds_per_frame=0.1):
        """One PNG per VTK frame (the slice of VIEWS, one colour scale for all frames) and a GIF of them."""
        import matplotlib
        matplotlib.use("Agg")  # files only, no window
        import matplotlib.pyplot as plt
        import numpy as np
        import pyvista as pv
        from PIL import Image

        info = json.loads((self.folder / "animation.json").read_text())
        array, normal, component = VIEWS[info["app"]]
        (pvd,) = (self.folder / "vtk_out").glob("*.pvd")
        reader = pv.get_reader(str(pvd))
        planes = []
        for t in reader.time_values:
            reader.set_active_time_value(t)
            mesh = reader.read()
            image = mesh[0] if isinstance(mesh, pv.MultiBlock) else mesh  # the .pvti joins the blocks' pieces
            nx, ny, nz = (d - 1 for d in image.dimensions)  # points -> cells
            u = image.cell_data[array].reshape(nz, ny, nx, 3)  # VTK order: x fastest
            plane = u[:, ny // 2] if normal == "y" else u[nz // 2]  # rows: z or y; columns: x
            planes.append(np.linalg.norm(plane, axis=-1) if component is None else plane[..., component])
        lo, hi = min(p.min() for p in planes), max(p.max() for p in planes)
        if component is not None:  # signed: white at zero
            lo, hi = -max(-lo, hi), max(-lo, hi)
        rows = "z" if normal == "y" else "y"
        quantity = "|u|" if component is None else f"u_{'xyz'[component]}"
        frames = self.folder / "frames"
        shutil.rmtree(frames, ignore_errors=True)
        frames.mkdir()
        height, width = planes[0].shape
        for i, (t, plane) in enumerate(zip(reader.time_values, planes)):
            fig, ax = plt.subplots(figsize=(7, 7 * height / width + 1.2))
            shown = ax.imshow(plane, origin="lower", vmin=lo, vmax=hi,
                              cmap="viridis" if component is None else "RdBu_r")
            ax.set(title=f"{info['experiment']}, {info['variant']}, {info['machine']}: step {int(t)}",
                   xlabel="x (cells)", ylabel=f"{rows} (cells)")
            fig.colorbar(shown, ax=ax, fraction=0.046 * height / width, pad=0.04,  # as tall as the image
                         label=f"{quantity} (lattice units), slice through the middle in {normal}")
            fig.savefig(frames / f"{i:04d}.png", dpi=100, bbox_inches="tight")
            plt.close(fig)
        images = [Image.open(p) for p in sorted(frames.glob("*.png"))]
        images[0].save(self.folder / "animation.gif", save_all=True, append_images=images[1:], loop=0,
                       duration=int(seconds_per_frame * 1000))
        print(f"{len(images)} frames: {frames}, {self.folder / 'animation.gif'}")


if __name__ == "__main__":  # bench.py render: here in the venv, which has pyvista
    Animation(sys.argv[1]).render()
