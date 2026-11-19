# Papers: the code-generation stack between waLBerla and pystencils

The stack, bottom to top:

```
SymPy  ->  pystencils (kernel IR + backends, 2.0 in our submodule)
              |-- lbmpy (LBM methods -> pystencils assignments)
              |-- pystencils-sfg (C++ source-file generator, pystencils 2.0 only)
waLBerla glue:
   old path: python/pystencils_walberla + python/lbmpy_walberla (generate_sweep, CodeGeneration)
   new path: sweepgen/ (SweepGen, built on pystencils 2.0 + pystencils-sfg)  <- SweepgenLdcCPU uses this
```

There are no papers yet for pystencils 2.0, pystencils-sfg or SweepGen (searched Nov 2026).
For those, the references are the docs: pystencils 2.0 docs (https://pycodegen.pages.i10git.cs.fau.de/docs/pystencils/2.0/),
pystencils-sfg docs (https://pycodegen.pages.i10git.cs.fau.de/pystencils-sfg/), SweepGen manual
(`submodules/walberla/doc/sweepgen`, online at https://www.walberla.net/doxygen/sweepgen/).

```
papers/
├── diagrams.md   20 mermaid diagrams of the stack, drawn from these papers
├── download.sh   re-downloads every PDF into the folders below (./download.sh --help)
├── pystencils/   pystencils itself, its GPU performance model, Hennig's 2024 overview slides
├── lbmpy/        lbmpy papers + Holzer thesis (whose Ch. 4 also covers pystencils and the waLBerla glue)
├── walberla/     framework paper, MESA-PD, GPU communication, waLBerla-wind application
├── kerncraft/    Kerncraft (performance-model tool used by pystencils 1.x)
└── exastencils/  ExaStencils coupled to waLBerla (a different code generator, not pystencils)
```

`download.sh` gets 12 of the 14 PDFs by itself. The SC'19 pystencils paper (ACM) and the Risso
paper (SBC / IEEE) block scripted downloads; the script prints where to get them in a browser.
`walberla/walberla-a-block-structured.pdf` here is the Elsevier version; the script fetches the
arXiv preprint of it instead.

**Reading order:** `pystencils/pystencil.pdf` -> `lbmpy/lbmpy-jocs2021-...` -> `lbmpy/holzer-phd-thesis-2024.pdf` Ch. 4
-> `walberla/walberla-a-block-structured.pdf` §6 -> `diagrams.md` -> SweepGen manual (for the new path).

## pystencils/

| File | Paper | What it covers for us |
|---|---|---|
| `pystencil.pdf` | Bauer et al., *Code Generation for Massively Parallel Phase-Field Simulations*, SC'19, doi:10.1145/3295500.3356186 | **The pystencils paper** (the one the pystencils README asks you to cite): symbolic description -> IR -> loop transformations, CSE, vectorisation, CPU/GPU backends; Kerncraft/ECM performance checks. |
| `hennig-cecam2024-pystencils-lbmpy-slides.pdf` | F. Hennig, *Code Generation for Stencil-Based Methods using pystencils and lbmpy*, CECAM talk, Oct 2024 (slides) | Not a paper: a hands-on overview of pystencils (symbolic toolbox -> IR -> CPU/GPU kernel -> Python function or waLBerla sweep) by the current pystencils 2.0 / SweepGen developer. Its code uses the 1.x API and it does not cover SweepGen. |
| `pystencils-gpu-perfmodel-jpdc2023-arxiv2204.14242.pdf` | Ernst, Holzer, Hager, Knorr, Wellein, *Analytical performance estimation during code generation on modern GPUs*, JPDC 173 (2023) 152–167, doi:10.1016/j.jpdc.2022.11.003 | Second paper the pystencils README asks you to cite: picks GPU launch configs from generated address expressions (no autotuning). |

## lbmpy/

| File | Paper | What it covers for us |
|---|---|---|
| `lbmpy-jocs2021-arxiv2001.11806.pdf` | Bauer, Köstler, Rüde, *lbmpy: Automatic code generation for efficient parallel lattice Boltzmann methods*, J. Comput. Sci. 49 (2021) 101269, doi:10.1016/j.jocs.2020.101269 | **The lbmpy paper.** Layers from moment/cumulant method definition down to pystencils kernels; waLBerla integration; scaling on SuperMUC-NG. |
| `lbmpy-mrt-cumulant-sisc2023-arxiv2211.02435.pdf` | Hennig, Holzer, Rüde, *Advanced Automatic Code Generation for Multiple Relaxation-Time LBMs*, SIAM J. Sci. Comput. (2023), doi:10.1137/22M1531348 | How modern lbmpy derives MRT / central-moment / cumulant collision operators (Chimera transforms, zero-centred storage). This is the lbmpy that ships today. |
| `holzer-phd-thesis-2024.pdf` | M. Holzer, *Code generation in a lattice Boltzmann framework for exascale computing*, PhD thesis, FAU 2024 | **Best single read for the glue layer.** Ch. 4 "Software Stack": pystencils abstraction layers (4.2), lbmpy method/collision/update rules (4.3), waLBerla fields, sweeps, communication and **4.4.5 "Integration of the Code Generation"**. Ch. 5: generated grid-refinement code incl. GPU. |
| `lbmpy-multiphase-ijhpca2021-arxiv2012.06144.pdf` | Holzer, Bauer, Köstler, Rüde, *Highly efficient LB multiphase simulations ... on CPUs and GPUs through code generation*, IJHPCA 35(4) (2021), doi:10.1177/10943420211016525 | End-to-end lbmpy -> waLBerla app: generated CPU/GPU kernels, roofline analysis, communication hiding and GPUDirect MPI scaling. |
| `lbmpy-sparse-ijhpca2026-arxiv2408.06880.pdf` | Suffa, Holzer, Köstler, Rüde, *Architecture Specific Generation of Large Scale LBMs for Sparse Complex Geometries*, IJHPCA (2026), doi:10.1177/10943420261434639 | Extends the pipeline to indirect-addressing (sparse) LBM kernels for CPU, NVIDIA and AMD; integrated in waLBerla. |

## walberla/

| File | Paper | What it covers for us |
|---|---|---|
| `walberla-a-block-structured.pdf` | Bauer et al., *waLBerla: A block-structured high-performance framework for multiphysics simulations*, CAMWA 81 (2021) 478–501, doi:10.1016/j.camwa.2020.01.007 | The waLBerla framework paper (blocks, fields, sweeps, communication). §6.1 introduces pystencils + `pystencils_walberla`; §6.2 MESA-PD. |
| `Scalable_GPU_Communication_with_Code_Generation_on_Stencil_Applications.pdf` | Risso, Bauer, Carvalho, Rüde, Weingaertner, *Scalable GPU communication with code generation on stencil applications*, SBAC-PAD 2019, doi:10.1109/SBAC-PAD.2019.00026 | GPU communication and communication hiding in waLBerla, with generated code. |
| `mesapd-dem8-arxiv1906.10963.pdf` | Eibl, Rüde, *A Modular and Extensible Software Architecture for Particle Dynamics* (MESA-PD), DEM8, arXiv:1906.10963 | waLBerla's particle module: Jinja-template generation of particle data structures. A different mechanism from pystencils; only needed if particles matter. |
| `walberla-wind-preprint.pdf` | Schottenhamml et al., *waLBerla-wind*, arXiv:2402.13171 | Application; Fig. 1 is a clear picture of the lbmpy -> pystencils -> waLBerla workflow. |

## kerncraft/

| File | Paper | Note |
|---|---|---|
| `kerncraft-2017-arxiv1702.04653.pdf` | Hammer, Eitzinger, Hager, Wellein, *Kerncraft: A Tool for Analytic Performance Modeling of Loop Kernels*, Tools for HPC 2016 (Springer 2017) | Roofline/ECM + layer conditions. pystencils 1.x had a Kerncraft coupling (used in the SC'19 paper); **the pystencils 2.0b1 in our submodule no longer contains it**, so treat this as background. |

## exastencils/

| File | Paper | Note |
|---|---|---|
| `exastencils-walberla-octree-multigrid-arxiv2403.08063.pdf` | Angersbach, Kuckuk, Köstler, *Towards Code Generation for Octree-Based Multigrid Solvers*, arXiv:2403.08063 (2024) | Couples **ExaStencils** (its own external DSL, ExaSlang, compiled by a Scala source-to-source compiler) to waLBerla's octree block structure, with generated coarse-to-fine / fine-to-coarse interpolating communication. pystencils is only mentioned as background. |

## Optional background (not downloaded)

- Meurer et al., *SymPy: symbolic computing in Python*, PeerJ CS 3 (2017) e103, doi:10.7717/peerj-cs.103 (open access). The CAS under pystencils.
- Bauer et al., *A Python extension for the massively parallel multiphysics simulation framework waLBerla*, IJPEDS 31(6) (2016), doi:10.1080/17445760.2015.1118478. The runtime Python coupling (not codegen).
- Godenschwager et al., SC'13, doi:10.1145/2503210.2503273 and Schornbaum & Rüde, SISC 38(2) (2016), doi:10.1137/15M1035240. waLBerla core data structures / blockforest.
- Ernst et al., *Opening the Black Box: Performance Estimation during Code Generation for GPUs*, arXiv:2107.01143. Conference version of the JPDC paper above.
