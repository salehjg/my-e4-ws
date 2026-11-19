# waLBerla, pystencils, lbmpy and friends, in diagrams

Diagrams drawn from the papers in this folder. Each section names the paper (path relative to
`docs/papers/`) the content comes from. Two things are **not** in any paper and come from our
submodules instead: pystencils-sfg and SweepGen (`submodules/walberla/doc/setup.md`,
`submodules/walberla/sweepgen/pyproject.toml`). They are marked where they appear.

Short definitions for the abbreviations are in the [glossary](#glossary) at the end.

Contents

1. [The whole stack: who feeds what](#1-the-whole-stack-who-feeds-what)
2. [Timeline of the papers](#2-timeline-of-the-papers)
3. [pystencils abstraction layers](#3-pystencils-abstraction-layers)
4. [What `create_kernel` does](#4-what-create_kernel-does)
5. [lbmpy abstraction layers](#5-lbmpy-abstraction-layers)
6. [lbmpy collision step in moment / cumulant space](#6-lbmpy-collision-step-in-moment--cumulant-space)
7. [How lbmpy cuts the FLOP count](#7-how-lbmpy-cuts-the-flop-count)
8. [Streaming patterns and memory traffic](#8-streaming-patterns-and-memory-traffic)
9. [waLBerla domain setup: from bounding box to time loop](#9-walberla-domain-setup-from-bounding-box-to-time-loop)
10. [waLBerla communication layers](#10-walberla-communication-layers)
11. [Build-time code generation in waLBerla (legacy path)](#11-build-time-code-generation-in-walberla-legacy-path)
12. [What the glue generates](#12-what-the-glue-generates)
13. [Old vs new LBM module in waLBerla](#13-old-vs-new-lbm-module-in-walberla)
14. [A time step with communication hiding](#14-a-time-step-with-communication-hiding)
15. [Kerncraft: CPU performance model](#15-kerncraft-cpu-performance-model)
16. [Warpspeed: GPU performance model inside pystencils](#16-warpspeed-gpu-performance-model-inside-pystencils)
17. [Sparse LBM data structure](#17-sparse-lbm-data-structure)
18. [MESA-PD: generated particle code](#18-mesa-pd-generated-particle-code)
19. [ExaStencils coupled to waLBerla](#19-exastencils-coupled-to-walberla)
20. [waLBerla-wind: an application on top of the stack](#20-walberla-wind-an-application-on-top-of-the-stack)

---

## 1. The whole stack: who feeds what

Solid arrows carry code or symbolic expressions from one tool to the next. Dotted arrows are
optional tools or separate generators.

Sources: `walberla/walberla-a-block-structured.pdf` §6, `lbmpy/holzer-phd-thesis-2024.pdf` Ch. 4,
`pystencils/hennig-cecam2024-pystencils-lbmpy-slides.pdf`; SweepGen / pystencils-sfg from the
waLBerla submodule.

```mermaid
flowchart LR
  sympy["SymPy<br/>computer algebra system"]

  subgraph PY["Python packages, run at build time"]
    direction TB
    script["Generation script<br/>(a .py file next to the app)"]
    lbmpy["lbmpy<br/>LB method → symbolic update rule"]
    ps["pystencils<br/>symbolic kernel → C / CUDA / HIP"]
    script -->|"method config"| lbmpy
    script -->|"assignments"| ps
    lbmpy -->|"update rule"| ps
  end

  subgraph GLUE["waLBerla glue (Python)"]
    direction TB
    legacy["Legacy: pystencils_walberla + lbmpy_walberla<br/>pystencils / lbmpy 1.3 + Jinja templates"]
    sg["New: SweepGen<br/>pystencils 2.0 + pystencils-sfg<br/>(not in the papers)"]
  end

  subgraph CPP["waLBerla C++, compiled and run"]
    direction TB
    gen["Generated .h / .cpp<br/>Sweeps, boundaries, PackInfos"]
    core["Hand-written waLBerla modules<br/>blockforest, field, communication,<br/>timeloop, gpu, lbm, mesa_pd"]
    app["Application executable<br/>MPI + OpenMP or CUDA / HIP"]
    gen --> app
    core --> app
  end

  sympy -.->|"both built on it"| lbmpy
  sympy -.-> ps
  ps -->|"kernel code"| legacy
  ps -->|"kernel code"| sg
  legacy -->|"Jinja"| gen
  sg -->|"pystencils-sfg"| gen

  subgraph TOOLS["Performance models"]
    kc["Kerncraft + LIKWID<br/>CPU, used with pystencils 1.x"]
    ws["Warpspeed<br/>GPU"]
  end
  ps -.->|"loop kernel"| kc
  ps -.->|"address expressions"| ws

  subgraph OTHER["Other generators in the waLBerla world"]
    mesa["MESA-PD generator<br/>Jinja, particle code"]
    exa["ExaStencils<br/>ExaSlang → C++ multigrid"]
  end
  mesa -.->|"generates the mesa_pd module"| core
  exa -.->|"generated solver coupled to blockforest"| app
```

---

## 2. Timeline of the papers

Everything in this folder, plus two context papers that are not downloaded (marked *context*).
The pystencils 2.0 dates are the git tags in our pystencils submodule.

```mermaid
timeline
    title Papers on the waLBerla code-generation stack
    2013 : waLBerla trillion-cell paper, SC 2013 (context)
    2015 : Kerncraft, first version (PMBS 2015)
    2016 : waLBerla Python extension (context)
    2017 : Kerncraft extended with layer conditions and a cache simulator
    2019 : SC 2019 phase-field paper, the main pystencils paper
         : Risso et al., generated GPU pack kernels and communication hiding in waLBerla
         : MESA-PD, Jinja-generated particle code
    2020 : waLBerla framework paper (CAMWA, online Jan 2020)
         : lbmpy paper on arXiv (J. Comput. Sci. 2021)
    2021 : lbmpy multiphase solver on CPUs and GPUs (IJHPCA)
    2022 : Ernst et al. GPU performance model on arXiv (JPDC 2023)
         : Hennig et al. MRT and cumulant lbmpy on arXiv (SISC 2023)
    2023 : waLBerla-wind on arXiv
    2024 : ExaStencils and waLBerla octree multigrid
         : Suffa et al. sparse LBM on arXiv (IJHPCA 2026)
         : pystencils 2.0.dev0 tag (July)
         : Hennig CECAM slides on pystencils and lbmpy
         : Holzer PhD thesis
    2026 : pystencils 2.0b1 tag (May), with pystencils-sfg and SweepGen in waLBerla, no paper yet
```

---

## 3. pystencils abstraction layers

Each layer is a SymPy-based representation; you can enter at any layer. The energy-functional
layer is only used for phase-field models (SC'19). The thesis lists the SIMD instruction sets
pystencils 1.x supports: SSE, AVX, AVX512, NEON, SVE, SME, RISC-V V and VSX.

Sources: `pystencils/pystencil.pdf` §3 (Fig. 1), `lbmpy/holzer-phd-thesis-2024.pdf` §4.2.2 (Fig. 4.1).

```mermaid
flowchart TB
  E["<b>Energy-functional layer</b><br/>free energy Ψ(φ, ∇φ, μ, T), phase-field only"]
  P["<b>PDE layer</b><br/>continuous PDEs built from transient, diffusion,<br/>advection terms and variational derivatives δΨ/δφ"]
  D["<b>Discretisation layer</b><br/>finite differences / finite volumes,<br/>fluxes at staggered positions, explicit Euler"]
  S["<b>Stencil layer</b> = AssignmentCollection<br/>relative Field accesses such as c[1,0], SSA form<br/>expand / factor, constant folding, global CSE,<br/>Philox counter-based random numbers for noise"]
  I["<b>Intermediate representation (IR)</b><br/>C types and casts, loop nest ordered by memory layout,<br/>ghost-layer width from access offsets, linear indices"]
  O["<b>Architecture-specific passes</b><br/>CPU: OpenMP, SIMD intrinsics, loop blocking, non-temporal stores<br/>GPU: thread indexing, register-pressure reordering,<br/>rematerialisation, evolutionary tuning of the pass sequence"]
  B["<b>Backends</b><br/>C for CPUs, CUDA for GPUs<br/>(1.x also had OpenCL and LLVM)"]
  J["JIT: compiled Python function<br/>on NumPy / CuPy arrays"]
  W["Source export<br/>→ waLBerla Sweep through the glue"]
  E -->|"variational derivative"| P
  P -->|"automatic discretisation"| D
  D --> S
  S -->|"create_kernel"| I
  I --> O
  O --> B
  B --> J
  B --> W
```

---

## 4. What `create_kernel` does

The step from the stencil layer to the IR, in the order the thesis describes it (pystencils 1.x).
Boundary conditions use the *indexed kernel* variant: one loop over a list of boundary cells
instead of a loop nest over the whole block.

Source: `lbmpy/holzer-phd-thesis-2024.pdf` §4.2.2.

```mermaid
flowchart TB
  in["List of Assignments in SSA form<br/>+ CreateKernelConfig: target, default data type,<br/>OpenMP and vectorisation settings"]
  c1["1 · Consistency check<br/>each symbol assigned once,<br/>independent array writes, thread safety"]
  c2["2 · Typing<br/>fields carry NumPy dtypes; free symbols get the default type;<br/>types are collated bottom-up and casts inserted"]
  c3["3 · Build the AST<br/>assignments go into a Block node;<br/>shape check: fixed shapes now, variable shapes as runtime asserts"]
  c4["4 · Loop nest<br/>innermost loop = contiguous memory dimension;<br/>loop bounds and ghost layers from the access offsets"]
  c5["5 · Resolve field accesses<br/>base pointer + linear index (strides × loop counters)"]
  c6["6 · Backend<br/>architecture passes → code printer → compile or write to file"]
  idx["Indexed-kernel variant<br/>single loop over an index vector,<br/>used for boundary conditions"]
  in --> c1 --> c2 --> c3 --> c4 --> c5 --> c6
  c3 -.-> idx -.-> c5
```

---

## 5. lbmpy abstraction layers

Up to the collision rule, lbmpy only uses SymPy and works on one cell. pystencils `Field`s enter at
the update rule, where the streaming pattern turns symbolic populations into neighbour accesses.

Sources: `lbmpy/holzer-phd-thesis-2024.pdf` §4.3 (Fig. 4.4),
`lbmpy/lbmpy-mrt-cumulant-sisc2023-arxiv2211.02435.pdf` §3–4 (Fig. 3.1),
`lbmpy/lbmpy-jocs2021-arxiv2001.11806.pdf` §II.

```mermaid
flowchart TB
  subgraph MD["1 · Method definition"]
    direction LR
    st["Stencil<br/>D2Q9, D3Q19, D3Q27, …"]
    zc["Storage<br/>absolute or zero-centred"]
    cs["Collision space<br/>populations, raw moments,<br/>central moments, cumulants"]
    bp["Basis polynomials + relaxation rates<br/>numbers, or symbols set at run time"]
    eq["Equilibrium, conserved quantities,<br/>force model: Simple, Guo, He, Shan-Chen, …"]
  end
  subgraph CR["2 · Collision rule (one cell, SymPy only)"]
    direction LR
    tr["Collision-space transform<br/>matrix, Chimera, binomial Chimera,<br/>fast central-moment transform"]
    si["Simplifications<br/>pre / post, CSE,<br/>conserved-quantity rewriting"]
    ca["Adaptions<br/>entropic, LES, non-Newtonian,<br/>4th-order correction, PSM"]
  end
  subgraph UR["3 · Update rule (pystencils Fields)"]
    sp["Streaming pattern<br/>two arrays: pull, push<br/>in place: AA, Esoteric Twist, Esoteric Pull / Push"]
  end
  K["pystencils create_kernel → C / CUDA kernel"]
  X["Also derived from the same method:<br/>macroscopic getters / setters, boundary kernels,<br/>pack / unpack kernels for MPI"]
  MD --> CR --> UR --> K
  UR -.-> X
```

---

## 6. lbmpy collision step in moment / cumulant space

How a cumulant collision is assembled. A raw-moment MRT method stops at raw moments; a
central-moment method stops at central moments. The Chimera transforms sum over z, then y, then x,
so each (population × velocity power) product is computed once. The back transform is split into
symmetric and antisymmetric parts, which roughly halves its operations.

Sources: `lbmpy/lbmpy-mrt-cumulant-sisc2023-arxiv2211.02435.pdf` §4.1–4.2,
`lbmpy/holzer-phd-thesis-2024.pdf` §4.3.3.

```mermaid
flowchart LR
  f["pre-collision<br/>populations fᵢ"]
  rm["monomial raw moments<br/>Chimera transform"]
  cm["central moments<br/>binomial Chimera transform"]
  cu["cumulants<br/>log relation; logs only in 0th order,<br/>removed symbolically"]
  rel["relax each quantity towards<br/>its equilibrium with its own rate ωᵢ"]
  back["back transform<br/>cumulants → central → raw moments,<br/>then f* = M⁻¹ m*"]
  fs["post-collision<br/>populations fᵢ*"]
  f --> rm --> cm --> cu --> rel --> back --> fs
  zc["Zero-centred storage: store δf = f − f(ρ₀=1)<br/>instead of f, which improves round-off accuracy"] -.-> f
```

---

## 7. How lbmpy cuts the FLOP count

D3Q19 BGK (single relaxation time), compressible, counts from Table I of the lbmpy paper.
Generic SymPy CSE alone reaches 261; lbmpy's own sequence reaches 193, below the best
hand-optimised kernel (204).

Source: `lbmpy/lbmpy-jocs2021-arxiv2001.11806.pdf` §IV-A, Table I.

```mermaid
flowchart LR
  a["automatic derivation<br/><b>1263</b> FLOPs"]
  b["SymPy CSE only<br/><b>261</b>"]
  c1["expand<br/>599"]
  c2["quadratic velocity products<br/>653"]
  c3["expand<br/>605"]
  c4["factor ω<br/>487"]
  c5["common quadratic term<br/>295"]
  c6["substitute existing subexpressions<br/>241"]
  c7["SymPy CSE<br/><b>193</b> FLOPs"]
  ref["hand-optimised reference<br/>204 FLOPs"]
  a -->|"generic"| b
  a -->|"lbmpy pipeline"| c1 --> c2 --> c3 --> c4 --> c5 --> c6 --> c7
  c7 -.-|"beats"| ref
```

---

## 8. Streaming patterns and memory traffic

Q is the number of populations per cell (19 for D3Q19). With normal stores a CPU first reads the
cache line it is about to overwrite ("write-allocate"), so a two-array kernel moves 3Q values per
cell; non-temporal stores skip that read and bring it to 2Q. In-place patterns write back to lines
they just read, so they move 2Q with half the memory. Working out which values an in-place pattern
must send to a neighbour process by hand is error-prone, which is why lbmpy generates the pack
kernels too.

Sources: `lbmpy/lbmpy-jocs2021-arxiv2001.11806.pdf` §IV-B/C (Figs. 2–4),
`lbmpy/lbmpy-mrt-cumulant-sisc2023-arxiv2211.02435.pdf` §4.4.

```mermaid
flowchart TB
  subgraph TWO["Two arrays, pull or push · memory 2 arrays · traffic 3Q, or 2Q with NT stores"]
    direction LR
    t1["read fᵢ from neighbour x − cᵢ<br/>in the source array"] --> t2["collide"] --> t3["write all Q values<br/>at x in the destination array"] --> t4["swap source and<br/>destination pointers"]
  end
  subgraph AA["AA pattern, in place · memory 1 array · traffic 2Q"]
    direction LR
    a1["even-step kernel<br/>read own cell, collide,<br/>write back to own cell in opposite slots"] --> a2["odd-step kernel<br/>pull from neighbours, collide,<br/>push to neighbours"]
    a2 --> a1
  end
  subgraph ET["Esoteric Twist, in place · memory 1 array · traffic 2Q"]
    direction LR
    e1["designed for one kernel + pointer swapping<br/>(needs one array per direction)"] --> e2["lbmpy keeps one population array,<br/>so it also generates an even-step<br/>and an odd-step kernel"]
  end
  TWO ~~~ AA ~~~ ET
```

---

## 9. waLBerla domain setup: from bounding box to time loop

The setup phase uses lightweight blocks (no simulation data) so refinement and load balancing stay
cheap. Only after the blocks are distributed do processes allocate the heavy data.

Sources: `walberla/walberla-a-block-structured.pdf` §3, `lbmpy/holzer-phd-thesis-2024.pdf` §4.4.2–4.4.3.

```mermaid
flowchart TB
  a["Domain bounding box<br/>split into equal root blocks"]
  b["SetupBlockForest<br/>lightweight blocks: AABB, ID, target rank"]
  c["Refinement callback marks blocks → octree per root block<br/>2:1 size ratio between neighbours;<br/>blocks fully inside obstacles can be dropped"]
  d["Static load balancing<br/>space-filling curves (Morton, Hilbert) or ParMETIS;<br/>level-wise for LBM because fine levels step more often"]
  s{"save setup<br/>to file?"}
  f["setup file<br/>reloaded by the production run"]
  g["BlockForest, distributed<br/>each process knows only its blocks and their neighbours"]
  h["BlockDataHandling allocates data per block<br/>Fields: cells + ghost layers; GPUFields; flag fields"]
  i["Sweeps<br/>callables taking a Block*, data looked up by BlockDataID"]
  j["Timeloop<br/>runs sweeps and communication every time step"]
  amr["Dynamic repartitioning (AMR)<br/>mark → proxy forest → balance proxies → migrate data"]
  a --> b --> c --> d --> s
  s -->|"yes"| f --> g
  s -->|"no"| g
  g --> h --> i --> j
  g -.-> amr -.-> g
```

---

## 10. waLBerla communication layers

Bottom to top: only the top layer knows about blocks. A *PackInfo* says **what** to exchange for one
block and one neighbour direction; a *communication scheme* says **how** (all at once, or
start/wait to overlap with computation).

Sources: `walberla/walberla-a-block-structured.pdf` §3.3 (Fig. 3), `lbmpy/holzer-phd-thesis-2024.pdf` §4.4.4,
`walberla/Scalable_GPU_Communication_with_Code_Generation_on_Stencil_Applications.pdf` §IV,
`pystencils/pystencil.pdf` §4.3.

```mermaid
flowchart BT
  mpi["MPI"]
  thin["Thin C++ MPI layer<br/>STL containers, broadcast of small input files"]
  buf["Buffered MPI<br/>SendBuffer / RecvBuffer serialisation,<br/>BufferSystem: per-partner buffers reused every step"]
  subgraph BLK["Block-to-block layer"]
    direction LR
    pack["PackInfo<br/>packData · unpackData · communicateLocal<br/>per block and neighbour direction"]
    scheme["Communication scheme<br/>synchronous, or start() / wait()"]
    direct["Direct variant<br/>MPI datatypes describing ghost slices"]
  end
  mpi --> thin --> buf
  buf --> pack
  buf --> scheme
  mpi --> direct
  gen["Generated PackInfos<br/>per-direction kernels, only the values needed,<br/>several fields in one buffer, CPU or GPU"] -.-> pack
  gpu["GPU path<br/>pack kernels on the device, one CUDA stream per neighbour,<br/>GPUDirect RDMA or staging through host memory"] -.-> scheme
```

---

## 11. Build-time code generation in waLBerla (legacy path)

What happens when you build an app that uses `pystencils_walberla` / `lbmpy_walberla`. Nothing
extra runs on the compute nodes: the generated files are ordinary C++ by then. (The SC'19 paper also
describes an interactive mode where kernels are compiled into Python extension modules and waLBerla
is driven from Python.)

Sources: `lbmpy/holzer-phd-thesis-2024.pdf` §4.4.5 (Fig. 4.7, Listing 4.7), `pystencils/pystencil.pdf` §4.2.
Function names checked against `submodules/walberla/python/`.

```mermaid
sequenceDiagram
  participant CM as CMake<br/>waLBerla_generate_target_from_python
  participant Py as generation script (.py)
  participant Ctx as CodeGeneration context
  participant PS as pystencils / lbmpy
  participant J as Jinja templates
  participant CC as C++ / CUDA compiler
  CM->>Py: run, passing the build config (GPU? OpenMP? float or double?)
  Py->>PS: build symbolic assignments (ps.fd, lbmpy method)
  Py->>Ctx: with CodeGeneration() as ctx
  Py->>Ctx: generate_sweep / generate_boundary /<br/>generate_pack_info_from_kernel / generate_lbm_package
  Ctx->>PS: create_kernel(target chosen from ctx)
  PS-->>Ctx: kernel AST printed as C or CUDA
  Ctx->>J: fill Sweep, Boundary, PackInfo class templates
  J-->>CM: .h / .cpp files in the build tree
  CM->>CC: compile into a library target
  CC-->>CM: link into the application executable
```

---

## 12. What the glue generates

One generation script produces several C++ classes. The same symbolic description drives all of
them, so kernels, boundaries and communication always agree on which values are read.

Sources: `lbmpy/holzer-phd-thesis-2024.pdf` §4.4.5–4.4.6, `lbmpy/lbmpy-jocs2021-arxiv2001.11806.pdf` §IV-D,
`lbmpy/lbmpy-multiphase-ijhpca2021-arxiv2012.06144.pdf` (Fig. 2).

```mermaid
flowchart LR
  s["symbolic description<br/>pystencils assignments or lbmpy method"]
  sw["<b>Sweep class</b> (generate_sweep)<br/>operator()(Block*): fetch Field pointers by BlockDataID,<br/>pass shapes and strides, call the kernel;<br/>field swaps for two-array schemes"]
  bc["<b>Boundary class</b> (generate_boundary)<br/>setup: scan the flag field, store boundary cells in an index vector,<br/>copy it to the GPU once<br/>run: indexed kernel loops over that vector"]
  pi["<b>PackInfo class</b> (generate_pack_info_from_kernel)<br/>pack / unpack kernels derived from the kernel's field accesses,<br/>only the values each direction needs"]
  lbm["<b>LBM package</b> (generate_lbm_package)<br/>storage specification, sweep collection,<br/>boundary collection, PDF pack kernels"]
  s --> sw
  s --> bc
  s --> pi
  s --> lbm
```

---

## 13. Old vs new LBM module in waLBerla

The old `lbm` module is hand-written C++ templates (static polymorphism): the lattice model is a
template parameter of the PDF field, only pull streaming is supported, and GPUs are not. The new
module (from the Holzer thesis) generates a *storage specification* that describes the method,
including its streaming pattern and pack kernels, and keeps the algorithms in a separate sweep
collection, so a GPU field can use the same description.

Source: `lbmpy/holzer-phd-thesis-2024.pdf` §4.4.6 (Figs. 4.8, 4.9).

```mermaid
classDiagram
  direction LR
  class LatticeModel~CM_FM~ {
    <<old, hand-written template>>
    +stencil
    +weights
    +collision model CM
    +force model FM
    +configure(block)
  }
  class OldPdfField~LatticeModel~ {
    <<old>>
    +setToEquilibrium(u, rho)
    +getDensity(cell)
    +getVelocity(cell)
  }
  class LatticeStorageSpecification {
    <<new, generated>>
    +stencil
    +inplace
    +weights
    +Accessor
    +pack(pdfs, buffer)
    +unpack(pdfs, buffer)
  }
  class PdfField~LSS~ {
    <<new>>
    +get(cell, f)
  }
  class GPUPdfField~LSS~ {
    <<new>>
  }
  class SweepCollection {
    <<new, generated>>
    +streamCollide(block)
    +streamCollide(block, cellInterval)
    +stream(block)
    +initialise(block)
  }
  OldPdfField --> LatticeModel : template parameter
  PdfField --> LatticeStorageSpecification : template parameter
  GPUPdfField --> LatticeStorageSpecification : template parameter
  SweepCollection --> PdfField : updates
```

---

## 14. A time step with communication hiding

Left: communicate, then compute everything. Right: compute the outer frame (cells next to the ghost
layers) first, send it while the inner region is computed on a separate stream, and synchronise at
the end. The multiphase paper uses the same frame / interior split; on a V100 a frame width of
(32, 8, 8) cells worked best.

Sources: `walberla/Scalable_GPU_Communication_with_Code_Generation_on_Stencil_Applications.pdf` (Fig. 2),
`lbmpy/lbmpy-multiphase-ijhpca2021-arxiv2012.06144.pdf` (Fig. 3), `pystencils/pystencil.pdf` §4.3.

```mermaid
flowchart LR
  subgraph NO["1 · No overlap"]
    direction TB
    n1["start send + receive"] --> n2["boundary handling"] --> n3["LBM kernel on the whole block"] --> n4["next step"]
  end
  subgraph YES["2 · Overlap"]
    direction TB
    y1["boundary handling"] --> y2["LBM on the outer frame"]
    y2 --> y3["pack on a GPU stream,<br/>MPI Isend / Irecv"]
    y2 --> y4["LBM on the inner region<br/>(separate CUDA stream)"]
    y3 --> y5["wait + unpack"]
    y4 --> y5
    y5 --> y6["next step"]
  end
```

---

## 15. Kerncraft: CPU performance model

Kerncraft predicts how fast a loop kernel runs from its source and a description of the machine.
In SC'19 the pystencils IR was handed to Kerncraft to pick between kernel variants (for example
split vs fused kernels) and blocking sizes. The pystencils 2.0b1 in our submodule no longer
contains this coupling.

Sources: `kerncraft/kerncraft-2017-arxiv1702.04653.pdf` §2 (Fig. 2), `pystencils/pystencil.pdf` §3.6.

```mermaid
flowchart LR
  k["Loop kernel in C<br/>+ constants such as N, M"]
  m["Machine description (YAML)<br/>clock, cache sizes, bandwidths"]
  ast["pycparser AST<br/>→ array access offsets"]
  bin["compile and mark the loop<br/>for the in-core analyser"]
  cache["Data traffic per cache level<br/>layer conditions (analytic)<br/>or pycachesim (simulation)"]
  core["In-core time<br/>IACA (Intel)"]
  model["Roofline or ECM model"]
  pred["Prediction<br/>cycles per cache line, multicore scaling,<br/>saturation point"]
  bench["Benchmark mode<br/>run and measure with LIKWID"]
  ps["pystencils 1.x IR (SC'19)"]
  ps -.-> k
  k --> ast --> cache
  k --> bin --> core
  m --> cache
  m --> core
  cache --> model
  core --> model
  model --> pred
  k --> bench
  pred -.->|"choose variant / blocking"| ps
```

---

## 16. Warpspeed: GPU performance model inside pystencils

Ranks GPU code-generation options (mainly thread-block size) without running them. It needs grid
sizes at generation time and cannot handle indirect addressing.

Sources: `pystencils/pystencils-gpu-perfmodel-jpdc2023-arxiv2204.14242.pdf` §1–4 (Fig. 1),
`lbmpy/holzer-phd-thesis-2024.pdf` (Fig. 4.3).

```mermaid
flowchart LR
  ps["pystencils GPU kernel"] --> ae["address expressions<br/>index arithmetic per thread"]
  lc["launch configuration<br/>thread-block size, thread folding"]
  fs["field sizes and alignment"]
  hw["hardware data<br/>V100 / A100 caches and bandwidths"]
  est["Metric estimator<br/>L1 load cycles, L2→L1 volume,<br/>DRAM→L2 volume incl. capacity misses"]
  pm["Performance model<br/>roofline + L1 and L2 cache limiters"]
  rank["estimate per configuration<br/>→ ranking, no GPU run needed"]
  ae --> est
  lc --> est
  fs --> est
  hw --> est
  est --> pm
  hw --> pm
  pm --> rank
  rank -.->|"pick the best"| lc
```

---

## 17. Sparse LBM data structure

For porous media most cells are solid. The sparse layout stores only fluid cells and replaces
neighbour index arithmetic with a list of where each population pulls from. On an A100 with
D3Q19 SRT, sparse beats dense below about 80 % fluid (porosity 0.8), for both speed and memory;
a hybrid setup picks per block.

Source: `lbmpy/lbmpy-sparse-ijhpca2026-arxiv2408.06880.pdf` (Figs. 1, 2, 4).

```mermaid
flowchart TB
  subgraph DENSE["Dense block (standard waLBerla field)"]
    d1["every cell stored: fluid, solid, ghost<br/>neighbour found by index arithmetic"]
  end
  subgraph SPARSE["Sparse block"]
    s1["PDF-list<br/>fluid cells only, structure of arrays,<br/>N_fluid × Q values"]
    s2["index-list<br/>for each population: the PDF-list<br/>position it pulls from"]
    s3["appended entries<br/>boundary populations (e.g. velocity bounce-back)<br/>and MPI ghost-layer populations"]
    s3 --> s1
    s2 --- s1
  end
  gen["lbmpy generates kernels for both layouts<br/>any stencil and collision operator,<br/>CPU, NVIDIA and AMD GPUs, in-place streaming"]
  hyb{"hybrid: porosity<br/>of each block"}
  gen --> DENSE
  gen --> SPARSE
  hyb -->|"≥ 0.8"| DENSE
  hyb -->|"< 0.8"| SPARSE
```

---

## 18. MESA-PD: generated particle code

waLBerla's particle module. It uses the same Jinja mechanism as the pystencils glue, but generates
data structures and their support code rather than stencil kernels. Kernels read and write particle
data only through an *accessor*, so the data layout can change without touching them.

Sources: `walberla/mesapd-dem8-arxiv1906.10963.pdf` §3–6 (Fig. 1), `walberla/walberla-a-block-structured.pdf` §6.2.

```mermaid
flowchart LR
  spec["Python spec<br/>addProperty(name, datatype, default, syncMode)<br/>syncMode: NEVER · COPY · MIGRATION · ALWAYS"]
  lib["MESA-PD Python library<br/>collects the spec once"]
  jinja["Jinja engine<br/>+ annotated C++ templates"]
  out["Generated mesa_pd sources<br/>particle storage, accessors,<br/>ghost-particle sync, VTK output, serialisation"]
  kern["Interaction kernels<br/>access data only through accessors"]
  app["compiled with the waLBerla app"]
  spec --> lib --> jinja --> out --> app
  kern --> app
  out -.->|"accessor interface"| kern
```

---

## 19. ExaStencils coupled to waLBerla

A different code generator: ExaStencils compiles its own external language (ExaSlang) to whole C++
multigrid programs. This work lets the generated solver run on waLBerla's refined block
structure, with generated communication that interpolates between refinement levels
(quadratic coarse-to-fine, linear fine-to-coarse). pystencils is only mentioned as background.

Source: `exastencils/exastencils-walberla-octree-multigrid-arxiv2403.08063.pdf` §1–3.

```mermaid
flowchart LR
  ex["ExaSlang<br/>4-layer external DSL"]
  sc["ExaStencils compiler<br/>Scala, source to source"]
  gen["Generated C++<br/>multigrid solver + communication kernels<br/>coarse-to-fine: quadratic, fine-to-coarse: linear"]
  wb["waLBerla BlockForest<br/>octree, 2:1 refinement"]
  cpl["Coupling<br/>generated code reads waLBerla's<br/>blocks and neighbourhood information"]
  run["Multigrid on locally refined grids<br/>benchmarked on SuperMUC-NG"]
  ex --> sc --> gen --> cpl
  wb --> cpl
  cpl --> run
```

---

## 20. waLBerla-wind: an application on top of the stack

The LBM part is generated with lbmpy (Guo forcing); wind turbines are actuator lines, i.e. forces
on blade elements instead of a resolved blade geometry. Forces are spread with the discrete delta
kernel of Roma et al., whose weights sum to 1, so total force is conserved.

Source: `walberla/walberla-wind-preprint.pdf` (Fig. 1 and the actuator-line section).

```mermaid
flowchart LR
  lbm["lbmpy-generated LBM step<br/>with Guo forcing"]
  interp["sample the flow velocity<br/>at each blade element"]
  bem["blade-element forces<br/>lift and drag from airfoil data"]
  spread["spread forces onto the grid<br/>discrete delta kernel (Roma et al.)"]
  lbm -->|"velocity field"| interp --> bem --> spread -->|"force field"| lbm
```

---

## Glossary

| Term | Meaning |
|---|---|
| AABB | axis-aligned bounding box |
| AA pattern, Esoteric Twist | in-place LBM streaming schemes that keep one population array instead of two |
| AMR | adaptive mesh refinement: refining / coarsening blocks while the simulation runs |
| AST / IR | abstract syntax tree / intermediate representation: the tree pystencils transforms before printing code |
| BlockForest | waLBerla's distributed set of blocks (one octree per root block) |
| Chimera transform | moment transform that sums over one velocity axis at a time; intermediates are half populations, half moments |
| CSE | common subexpression elimination: compute repeated terms once |
| DdQq | lattice with d dimensions and q populations per cell (e.g. D3Q19) |
| ECM | execution-cache-memory model: predicts loop runtime from in-core time plus per-cache-level transfer times |
| FLOP | floating-point operation |
| ghost layer | extra cells around a block that hold copies of neighbour data |
| Jinja | Python template engine used to wrap generated kernels in C++ classes |
| JIT | just-in-time compilation: compile the generated code while the Python program runs |
| layer condition | rule for whether stencil rows / planes stay in a cache, used to predict memory traffic |
| LBM, PDF | lattice Boltzmann method; particle distribution function (one "population" value) |
| MRT / SRT (BGK) / TRT | multiple / single / two relaxation-time collision operators |
| NT store | non-temporal (streaming) store: writes past the cache, avoiding the write-allocate read |
| PackInfo | waLBerla interface that packs / unpacks one block's data for one neighbour direction |
| porosity | fraction of fluid cells in the domain |
| roofline | model bounding performance by peak compute and memory bandwidth |
| SIMD | single instruction, multiple data: vector instructions (AVX, NEON, SVE, RISC-V V, …) |
| SSA | static single assignment: each symbol is assigned exactly once |
| Sweep | waLBerla callable that runs an algorithm on one block |
| UBB | velocity bounce-back boundary condition |
| zero-centred storage | storing the deviation of each population from its rest-state value instead of the value itself |
