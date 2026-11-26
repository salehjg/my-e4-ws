"""What bench.py builds and times: machines, builds (one CMake tree each) and experiments.

Data only; edit this file to add a variant, a build or an experiment. Nothing here is a string to decode:
bench.py turns a Variant into the name that waLBerla's code generation hands to the app's generator script
(bench.codegen_config is the only place that knows that format).
"""
from __future__ import annotations

from dataclasses import asdict, dataclass
from enum import Enum


class App(Enum):
    WIND = "wind"  # waLBerla-wind, apps/BenchmarkApp_cpu_uniform: D3Q27 cumulant, Guo force, QR model
    UGC = "ugc"    # waLBerla, apps/benchmarks/UniformGridCPU: periodic shear flow (uniform_grid_cpu.prm)


class Streaming(Enum):
    PULL = "pull"
    AA = "aa"


class Vectors(Enum):
    NONE = "none"        # no explicit vectors (the compiler may still auto-vectorize)
    RVV = "rvv"          # pystencils 1.4's own RVV instruction set
    RVV_EXT = "rvv_ext"  # ours (pystencils/backends/riscv_ext_instruction_sets.py), with the options of Variant


class Compiler(Enum):
    GCC = ("gcc", "g++")
    CLANG = ("clang", "clang++")


@dataclass(frozen=True)
class Variant:
    """How the LBM kernels of one executable are generated."""
    streaming: Streaming = Streaming.PULL
    vectors: Vectors = Vectors.NONE
    # rvv_ext options: the same names and defaults as riscv_ext_instruction_sets.parse_options
    vlen: int | None = None      # None: any VLEN (vector-length agnostic, like rvv); 128 or 256: fixed
    lmul: int = 1                # register group size: 1, 2 or 4
    vf: bool = False             # vector-scalar instructions (.vf) instead of splats
    fma: bool = False            # fused multiply-add
    prefetch: int | None = None  # prefetch this many bytes ahead

    def options(self) -> dict:
        return {k: v for k, v in asdict(self).items() if k not in ("streaming", "vectors")}

    def __post_init__(self):
        if self.vectors is not Vectors.RVV_EXT and any((self.vlen, self.lmul != 1, self.vf, self.fma, self.prefetch)):
            raise ValueError(f"{self}: the options are for Vectors.RVV_EXT only")
        if self.vlen not in (None, 128, 256) or self.lmul not in (1, 2, 4) or (self.prefetch or 1) <= 0:
            raise ValueError(f"{self}: vlen None/128/256, lmul 1/2/4, prefetch None or > 0")


REFERENCE = Variant()  # scalar pull: the code waLBerla-wind ships; every checksum is compared with it


@dataclass(frozen=True)
class Build:
    """One CMake tree: an app, a precision, a compiler, and the variants built in it."""
    name: str  # folder name of the tree
    app: App
    variants: tuple[Variant, ...]
    precision: int = 32  # 32 or 64 bits
    compiler: Compiler = Compiler.GCC
    stencil: str = "d3q19"   # UniformGridCPU only: upstream's names (apps/benchmarks/UniformGridCPU/CMakeLists.txt)
    collision: str = "srt"

    def __post_init__(self):
        if self.precision not in (32, 64) or REFERENCE not in self.variants:
            raise ValueError(f"{self.name}: precision 32 or 64, and the variants must contain REFERENCE")


@dataclass(frozen=True)
class Experiment:
    """What `bench.py run` times. Every process gets its own cells^3 block."""
    build: Build
    cores: tuple[int, ...] | None = None  # process counts; None: the machine's
    cells: int = 64
    warmup: int = 10  # untimed steps first
    steps: int = 60   # timed steps
    rounds: int = 3   # every variant once per round, in turn (the presentation5 protocol)


@dataclass(frozen=True)
class Machine:
    cores: tuple[int, ...]  # process counts of the timing runs
    jobs: int               # parallel compile jobs
    cxx_flags: str          # architecture flags of every file (CMAKE_CXX_FLAGS)
    work: str               # build trees; {repo} = walberla-rvv-support, {base} = its parent (the git root)
    venv: str = "{base}/.venv-legacy"  # Python of the code generation (bench.py setup)
    pin_cpu: int = 2                   # core of the single-process runs (taskset)
    mpirun: tuple[str, ...] = ("mpirun", "--bind-to", "core", "--map-by", "core")


MACHINES = {
    # x86, for trying the scripts: only Vectors.NONE builds
    "laptop": Machine(cores=(1, 4), jobs=8, cxx_flags="-march=native", work="{repo}/build/legacy"),
    # Banana Pi BPI-F3, SpacemiT K1: 8 X60 cores (2 clusters of 4), VLEN 256, 3.8 GB (about 2 GB per compile job).
    # The flags waLBerla's GNU.cmake gives GCC there (GCC 14.2 rejects -mtune=spacemit-x60; Clang would take it).
    # Builds and venv outside the pushed repository (remote.py push), which push.to.sh keeps an exact mirror.
    "bananapi": Machine(cores=(1, 4, 8), jobs=2, cxx_flags="-march=rv64gcv_zvl256b",
                        work="/home/bananapi/saleh/legacy", venv="/home/bananapi/saleh/.venv-legacy"),
}

# Largest relative checksum difference to REFERENCE that counts as rounding. Measured on x86, float32, 100 steps:
# pull vs AA differ by about 2e-9 (docs/notes8 progress log, step 6); a wrong kernel differs by 1e-3 or more.
TOLERANCE = {32: 1e-6, 64: 1e-10}

PULL, AA = Streaming.PULL, Streaming.AA
NONE, RVV, RVV_EXT = Vectors.NONE, Vectors.RVV, Vectors.RVV_EXT

SCALAR = (Variant(PULL), Variant(AA))
RISCV = SCALAR + (
    Variant(PULL, RVV), Variant(AA, RVV),           # upstream
    Variant(AA, RVV_EXT, vf=True),                  # ours: one option at a time ...
    Variant(AA, RVV_EXT, fma=True),
    Variant(AA, RVV_EXT, vf=True, fma=True),
    Variant(AA, RVV_EXT, vf=True, fma=True, prefetch=128),
    Variant(AA, RVV_EXT, vlen=256, vf=True, fma=True, prefetch=128),  # ... and fixed VLEN 256 (K1 only)
)

EXPERIMENTS = {
    "wind": Experiment(Build("wind-f32", App.WIND, RISCV)),
    "ugc": Experiment(Build("ugc-d3q19-srt-f64", App.UGC, RISCV, precision=64)),
    "wind-x86": Experiment(Build("wind-f32-x86", App.WIND, SCALAR)),
    "ugc-x86": Experiment(Build("ugc-d3q19-srt-f64-x86", App.UGC, SCALAR, precision=64)),
}
