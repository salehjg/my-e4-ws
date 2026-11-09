# Plan: pystencils manual in LaTeX (`docs/manual_pystencil/`)

> **Copied (2026-11-09):** this manual is now also report r01 of `docs/manual/` (`docs/manual/reports/r01/`),
> built with `docs/manual/build.sh`. Paths below refer to the original copy in `docs/manual_pystencil/`.

## Context
The user wants one comprehensive LaTeX tutorial/manual about the `submodules/pystencils` submodule.
That submodule is on branch `rvv-support`: pystencils `2.0b1+4.g9a989e16`, i.e. upstream 2.0 plus our
RISC-V RVV VLS-256 backend. The manual should explain:
- what pystencils tries to achieve, and its core idea;
- how a programmer uses it: inputs, outputs, the programming interface;
- its internal structure and its backends.

It needs a simple multi-file `.tex` layout, a bash script that builds into `build/`, and a `.gitignore`.

Decisions so far:
- Location (fixed by the user): `docs/manual_pystencil/`.
- The RVV backend gets a full chapter, clearly marked fork-only.
- Listings are **real captured output** from running pystencils.
- Target length is about **50–70 pages**.
- No commits, following the standing preference in memory.
- Step 0: copy this plan to `docs/manual_pystencil/plan-opus5.5.md`, following the memory rule that plans go into the repo with a model suffix.

Toolchain (checked):
- TeX Live 2026: latexmk, pdflatex, biber, listings, tcolorbox, tikz, KOMA `scrreprt`, booktabs, tabularx, cleveref, dirtree, inconsolata.
- `clang-format`, `pdfinfo` and `pdftoppm` are in `/usr/bin`.
- pystencils imports with `PYTHONPATH=submodules/pystencils/src .venv-rvv/bin/python` (it is not pip-installed). The venv has no cupy, IPython or scipy.
- On this x86 host it can run x86 and generic kernels. CUDA and RVV code can be generated but not run.

## Directory layout (new files only; submodule untouched)
```
docs/manual_pystencil/
├── main.tex              # scrreprt; \input{preamble}; \include chapters in 2 parts + appendices
├── preamble.tex          # packages, colors, listings styles (python/cpp/ir/bash), tcolorbox
│                         #   envs (note, pitfall, forkonly), macros (\ps, \code, \file, \cls)
├── references.bib        # pystencils (from CITATION.cff), lbmpy, waLBerla, pystencils-sfg, RVV spec
├── build.sh              # ./build.sh [pdf|clean|listings|watch]
├── .gitignore            # build/, LaTeX aux files, __pycache__/
├── chapters/             # one .tex per chapter (01-…tex … 12-…tex)
├── appendices/           # a-config-reference, b-source-map, c-pitfalls, d-glossary
├── figures/              # TikZ figures as standalone \input-able .tex
│                         #   (big-picture, pipeline, type-hierarchy, axes-lowering, platform-classes)
├── examples/             # runnable user-style .py scripts shown in the manual
└── generated/            # COMMITTED captured outputs (*.c, *.txt) written by tools/
    tools/gen_listings.py # runs examples/ and writes generated/; reformats C with clang-format
```
- **Build:** `build.sh` runs `latexmk -pdf -interaction=nonstopmode -halt-on-error -outdir=build main.tex` from the script's directory. `\include` of subdirectories under `-outdir` needs `mkdir -p build/{chapters,appendices}` first, so the script creates them. The PDF is copied to `build/pystencils-manual.pdf`.
- **Python is optional for the build:** `generated/` is committed, so building needs only TeX. `./build.sh listings` regenerates `generated/` with `PYTHONPATH=../../submodules/pystencils/src ../../.venv-rvv/bin/python -B tools/gen_listings.py`. The venv path can be overridden with the `PYTHON` env var.
- **Snippets:** example scripts mark regions with comments such as `# [jacobi-setup]`. The manual pulls those regions in with `\lstinputlisting[linerange=...]`.
- **Generator:**
  - It imports each example, collects `get_c_code()`, `get_ir_code()`, parameter dumps and stdout, and writes one file per artifact.
  - CPU kernels are compiled through `CpuJit(objcache=None)` (a temporary directory, so nothing goes into `~/.cache`). Their results are checked against NumPy, so the listings also show that the kernels work.
  - C output is passed through `clang-format` (column limit about 88) to fit the page. A footnote says it is real output, reformatted for whitespace only.
  - Long lines that are left over are wrapped by listings `breaklines`.

## Content outline (≈60 pages)
**Part I — Using pystencils**
1. **Introduction:** what a stencil code is; the problem (hand-written kernels for every target); the pystencils idea (write SymPy once, generate typed C/C++/CUDA for each target); scope and versions; the ecosystem (lbmpy, waLBerla/sweepgen, pystencils-sfg); a big-picture figure (inputs → pystencils → outputs).
2. **Getting started:** installation (pip extras from `pyproject.toml`; this workspace's `PYTHONPATH` setup); a first Jacobi kernel covering `ps.fields` → `Assignment` → `create_kernel` → `ps.inspect` → `compile()` → call with NumPy arrays; checked against NumPy; real C output.
3. **The symbolic frontend (inputs):**
   - Fields: the `fields()` string syntax, dtypes, layouts (`fzyx`/`zyxf`/`c`), field types, `center`/neighbor/index access, staggered fields.
   - `Assignment`, `AssignmentCollection` (main assignments vs subexpressions).
   - Symbols and types: `TypedSymbol`, `DynamicType`, `tcast`.
   - The supported SymPy subset; `Piecewise` conditionals; `int_div`/`int_rem`.
   - Reductions; `ps.random.Philox`; `ps.fd` (heat-equation example); `ps.simp.sympy_cse`; `@ps.kernel`.
   - `ps.flow` (experimental, short).
4. **Configuring kernel creation:**
   - `create_kernel` and `CreateKernelConfig` (Option/Category mechanism, `copy`/`override`).
   - `Target`: flags, detection, `CurrentCPU`.
   - Data types: `default_dtype`/`index_dtype`, no implicit casts.
   - Iteration space: AUTO, uniform or per-side ghost layers, `make_slice`, sparse `index_field` kernels.
   - CPU options: OpenMP, vectorization, `assume_inner_stride_one`, loop blocking.
   - GPU options: indexing schemes, launch configuration. SYCL options in brief.
   - Kernel constraints: SSA form and independence, `KernelConstraintsError`.
5. **Outputs and execution:**
   - The `Kernel`/`GpuKernel` object: `parameters`, `Parameter` + `FieldBasePtr`/`FieldShape`/`FieldStride`, `required_headers`, `metadata`.
   - Anatomy of the generated C: signature, `RESTRICT`, `_data_`/`_size_`/`_stride_` names, loop order, hoisted constants. IR view.
   - `CpuJit`/`CompilerInfo` (GCC by default; `-march` table; cache; custom compilers via `extra_cxxflags`), with an excerpt of the extension-module glue.
   - The call interface: keyword-only arguments; dtype and shape checks; ghost layers are part of the arrays passed in.
   - `CupyJit` and launch configs; `no_jit`.
   - Using kernels outside Python (waLBerla sweepgen / pystencils-sfg consume `Kernel` + parameter properties).
   - DataHandling and boundaries in brief.

**Part II — Inside pystencils**

6. **Architecture overview:** design principles (SymPy frontend, typed IR, platform-agnostic passes, platform lowering, iteration axes); source-tree map; a pipeline figure of `DefaultKernelCreationDriver.__call__`'s five stages (parse → materialize iteration space → general optimize → lowering → finalize) with each pass named.
7. **The IR:**
   - `KernelCreationContext`.
   - Symbols and properties, `PsBuffer`, `PsConstant`, `PsLiteral`.
   - Functions: IR functions vs `CFunction`.
   - The type system: hierarchy figure, parsing, const/restrict, literals.
   - AST nodes: structural, expression, vector, axes. Canonical form; the IR printer.
8. **Translation:** `KernelAnalysis`; Full/Sparse iteration spaces, archetype field, loop order; `FreezeExpressions` (a SymPy → IR mapping table); `Typifier`/`TypeContext` rules; `AstFactory`.
9. **Transformations and iteration axes:**
   - Axes cube → `AxisExpansion` strategies (CPU dense/vector shapes, GPU schemes).
   - `MaterializeAxes`: loops, OpenMP pragmas, SIMD via `AstVectorizer`, GPU guards.
   - `ReductionsToMemory`, `CanonicalizeSymbols`, `EliminateConstants`, `HoistIterationInvariantDeclarations`, `LowerToC`, `SelectIntrinsics`, `SelectFunctions`.
   - A table of passes and where each is used, including passes the driver never calls.
   - A captured "manual pipeline" example that prints the IR after each stage, abridged from `docs/source/backend/backend_walkthrough.md`.
10. **Platforms and backends:**
    - The `Platform` interface.
    - CPU: `GenericCpu`; `GenericVectorCpu` + the `SelectIntrinsics` contract; x86 (SSE/AVX/AVX512 naming, captured AVX code); NEON; SVE.
    - GPU: `GenericGpu`, CUDA (captured `__global__` code, warp reductions), HIP.
    - SYCL.
    - Emission (`CAstPrinter`, signature printing); runtime headers table; a backend feature-matrix table.
11. **The RISC-V RVV backend (fork-only box):**
    - Motivation; the VLS-256 design matching AVX (m1/mf2, literal `vl`).
    - IR → intrinsic mapping table; `rvv.hpp`; target detection and `-march=rv64gcv_zvl256b`.
    - A usage config; captured RVV Jacobi and OpenMP sum-reduction code.
    - Limitations; tests and board validation in brief, pointing to `docs/notes2/*opus5.5.md`.
    - "Recipe: adding a vector backend": the checklist distilled from this work.
12. **Worked example and outlook:** a D2Q9 LBM collide kernel, summarizing `python/learn-lb-pystencil/lb-pystencils.py` and `scripts/lbm_rvv_check.py`; further reading.

**Appendices:**
- A. Full `CreateKernelConfig` option reference (table).
- B. Source map (file → responsibility).
- C. Pitfalls and 2.0 migration notes.
- D. Glossary.

Appendix C pitfalls, each to be re-checked by running it before writing:
- `inspect_ast` is listed in `__all__` but not defined.
- `show_code` prints IR, not C.
- The deprecated `cpu_openmp=True` disables OpenMP.
- `create_fixed_size` ignores `memory_strides`.
- Staggered kernels raise `NotImplementedError`.
- The tutorial notebooks contain stale outputs.
- `CompilerInfo.target` is independent of the kernel's target.
- Kernel keyword arguments only replace top-level config fields.

## Key source references (for accuracy while writing)
- **Codegen:** `src/pystencils/codegen/{driver,config,target,kernel,parameters,properties,gpu_indexing,cpu_loop_strategies}.py`
- **Backend:** `src/pystencils/backend/{kernelcreation,ast,transformations,platforms,emission}/`, `backend/{memory,constants,functions,literals}.py`, `src/pystencils/types/`
- **JIT:** `src/pystencils/jit/{jit.py,cpu/cpujit.py,cpu/compiler_info.py,cpu/default_module_builder.py,cpu/cpu_kernel_module.tmpl.cpp,gpu_cupy.py}`
- **Frontend:** `src/pystencils/{field.py,assignment.py,simp/,sympyextensions/,fd/,flow/,defaults.py}`
- **RVV:** `backend/platforms/rvv.py`, `include/pystencils_runtime/rvv.hpp`, `tests/nbackend/test_rvv_*.py`
- **Upstream docs to paraphrase (not copy):** `docs/source/backend/{backend_walkthrough,gpu_codegen,objects,platforms}.md`, `docs/source/user_manual/*.md`

## Execution order
1. Scaffold: `main.tex`, `preamble.tex`, `build.sh`, `.gitignore`, `references.bib`, chapter stubs. Build once to prove the toolchain works.
2. Write `examples/*.py` and `tools/gen_listings.py`; run it; review `generated/`.
3. Write the chapters in order, with figures. Re-check every API claim against the source while writing.
4. Write the appendices.
5. Polish: cross-references, index of listings, fixing overfull boxes.

## Verification
- `bash docs/manual_pystencil/build.sh` exits 0 and produces `build/pystencils-manual.pdf`. `grep -E "undefined|Citation .* undefined|Rerun" build/main.log` is empty. There are no LaTeX errors and few overfull boxes.
- `pdfinfo` reports about 50–70 pages.
- Render sample pages (title, pipeline figure, a C listing, the RVV chapter, a table) with `pdftoppm -png -r 60` into the scratchpad and look at them to check the layout.
- `./build.sh listings` runs cleanly. The NumPy checks pass inside the generator, and a second run leaves `generated/` unchanged (deterministic).
- `./build.sh clean` removes `build/`. In a fresh state, `git status` shows only `docs/manual_pystencil/**` as new and untracked, with `build/` ignored, and the submodule unchanged.
