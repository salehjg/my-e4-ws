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
    """The vector backend (README.md, Names): <isa>.lgcy is pystencils 1.4's own, <isa>.our<N> our experimental
    backend N. A new backend of ours gets the next number; a name is never changed or reused."""
    NONE = "none"          # no explicit vectors (the compiler may still auto-vectorize)
    RVV_LGCY = "rvv.lgcy"  # pystencils 1.4's own RVV backend (pystencils calls it rvv)
    RVV_OUR1 = "rvv.our1"  # ours: rvv.lgcy plus the options of Variant (pystencils' riscv_our1_instruction_sets.py)


class Compiler(Enum):
    GCC = ("gcc", "g++")
    CLANG = ("clang", "clang++")


@dataclass(frozen=True)
class Variant:
    """How the LBM kernels of one executable are generated."""
    streaming: Streaming = Streaming.PULL
    vectors: Vectors = Vectors.NONE
    # rvv.our1 options: the same names and defaults as riscv_our1_instruction_sets.parse_options
    vlen: int | None = None      # None: any VLEN (vector-length agnostic, like rvv.lgcy); 128 or 256: fixed
    lmul: int = 1                # register group size: 1, 2 or 4
    vf: bool = False             # vector-scalar instructions (.vf) instead of splats
    fma: bool = False            # fused multiply-add
    prefetch: int | None = None  # prefetch this many bytes ahead

    def options(self) -> dict:
        return {k: v for k, v in asdict(self).items() if k not in ("streaming", "vectors")}

    def __post_init__(self):
        if self.vectors is not Vectors.RVV_OUR1 and any((self.vlen, self.lmul != 1, self.vf, self.fma, self.prefetch)):
            raise ValueError(f"{self}: the options are for Vectors.RVV_OUR1 only")
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
    jobs: int | None        # parallel compile jobs; None: one per core, at most one per 2 GB of memory
    cxx_flags: str          # architecture flags of every file (CMAKE_CXX_FLAGS)
    work: str               # build trees; {repo} = walberla-rvv-support, {base} = its parent (the git root)
    venv: str = "{base}/.venv-legacy"  # Python of the code generation (bench.py setup)
    vlen: int | None = None            # RISC-V vector length in bits: variants with a fixed VLEN must match it
    pin_cpu: int = 2                   # core of the single-process runs (taskset)
    mpirun: tuple[str, ...] = ("mpirun", "--bind-to", "core", "--map-by", "core")
    modules: tuple[str, ...] = ()      # environment modules bench.py loads first, in this order
    link_flags: str = ""               # extra linker flags (CMAKE_EXE_LINKER_FLAGS)


MILKV_MPI = "/opt/share/milkv/openmpi-5.0.6"  # monte3's module openmpi-5.0.6

MACHINES = {
    # x86, for trying the scripts: only Vectors.NONE builds
    "laptop": Machine(cores=(1, 4), jobs=8, cxx_flags="-march=native", work="{repo}/build/legacy"),
    # Banana Pi BPI-F3, SpacemiT K1: 8 X60 cores (2 clusters of 4), VLEN 256, 3.8 GB (about 2 GB per compile job).
    # The flags waLBerla's GNU.cmake gives GCC there (GCC 14.2 rejects -mtune=spacemit-x60; Clang would take it).
    # Builds and venv outside the pushed repository, of which remote.py push keeps an exact mirror.
    "bananapi": Machine(cores=(1, 4, 8), jobs=2, cxx_flags="-march=rv64gcv_zvl256b", vlen=256,
                        work="/home/bananapi/saleh/legacy", venv="/home/bananapi/saleh/.venv-legacy"),
    # Monte Cimone, slurm partition "peak": one Sophgo SG2044 node (mc-peak-2), 64 cores, VLEN 128. bench.py runs
    # there in slurm jobs (remote.py start). Ask the user before anything runs there. As notes7 found
    # (scripts/notes7/monte3.sh): the milkv Open MPI 5.0.6, loaded after GCC 14.2, not the system's Open MPI 4.1.5
    # (its helper thread spins); the module's linker needs to be told where libmpi's dependencies are.
    "monte3": Machine(cores=(1, 4, 8, 16, 32, 64), jobs=None, cxx_flags="-march=rv64gcv_zvl128b", vlen=128,
                      work="/home/sjamaligolzar/02_ws/legacy", venv="/home/sjamaligolzar/02_ws/legacy/venv",
                      mpirun=(f"{MILKV_MPI}/bin/mpirun", "--bind-to", "core", "--map-by", "core"),
                      modules=("gcc-14.2.0", "openmpi-5.0.6"),
                      link_flags=f"-Wl,-rpath-link,{MILKV_MPI}/lib:/usr/lib64 -Wl,-rpath,{MILKV_MPI}/lib"),
}

# Largest relative checksum difference to REFERENCE that counts as rounding (docs/notes8 progress log). float32:
# scalar pull vs AA differ by about 2e-9; pystencils' vector kernels drift from the scalar one by about 5e-8 per
# step, the same with AVX and RVV (wind, 70 steps: 3.3e-6, AVX and RVV agree to 1e-9); a wrong kernel: 1e-3 or more.
TOLERANCE = {32: 1e-5, 64: 1e-10}

PULL, AA = Streaming.PULL, Streaming.AA
NONE, RVV_LGCY, RVV_OUR1 = Vectors.NONE, Vectors.RVV_LGCY, Vectors.RVV_OUR1

SCALAR = (Variant(PULL), Variant(AA))
ANY_VLEN = SCALAR + (
    Variant(PULL, RVV_LGCY), Variant(AA, RVV_LGCY),  # pystencils' own
    Variant(AA, RVV_OUR1, vf=True),                  # ours: one option at a time ...
    Variant(AA, RVV_OUR1, fma=True),
    Variant(AA, RVV_OUR1, vf=True, fma=True),
    Variant(AA, RVV_OUR1, vf=True, fma=True, prefetch=128),
)
VLEN256 = ANY_VLEN + (Variant(AA, RVV_OUR1, vlen=256, vf=True, fma=True, prefetch=128),)  # ... and fixed: K1
VLEN128 = ANY_VLEN + (Variant(AA, RVV_OUR1, vlen=128, vf=True, fma=True, prefetch=128),)  # monte3

EXPERIMENTS = {
    "wind": Experiment(Build("wind-f32", App.WIND, VLEN256)),
    "ugc": Experiment(Build("ugc-d3q19-srt-f64", App.UGC, VLEN256, precision=64)),
    "wind-vlen128": Experiment(Build("wind-f32-vlen128", App.WIND, VLEN128)),
    "ugc-vlen128": Experiment(Build("ugc-d3q19-srt-f64-vlen128", App.UGC, VLEN128, precision=64)),
    "wind-x86": Experiment(Build("wind-f32-x86", App.WIND, SCALAR)),
    "ugc-x86": Experiment(Build("ugc-d3q19-srt-f64-x86", App.UGC, SCALAR, precision=64)),
}
