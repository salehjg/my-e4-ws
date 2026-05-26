# Lattice Boltzmann Method — Lid-Driven Cavity

![](https://github.com/salehjg/my-e4-ws/blob/main/python/learn-lb-numpy/lbm_result.png?raw=true)

A minimal 2D fluid simulation in plain NumPy using the Lattice Boltzmann Method (LBM).
No external CFD libraries required.

```
pip install numpy matplotlib
python lbm_simple.py
```

---

## Table of Contents

1. [What Problem Are We Solving?](#1-what-problem-are-we-solving)
2. [The Physics](#2-the-physics)
3. [What Is the Lattice Boltzmann Method?](#3-what-is-the-lattice-boltzmann-method)
4. [The D2Q9 Stencil](#4-the-d2q9-stencil)
5. [The Two Core Steps](#5-the-two-core-steps)
6. [Boundary Conditions](#6-boundary-conditions)
7. [Code Walkthrough](#7-code-walkthrough)
8. [Parameters & Stability](#8-parameters--stability)
9. [Expected Output](#9-expected-output)

---

## 1. What Problem Are We Solving?

The **lid-driven cavity** is the "Hello, World" of computational fluid dynamics.

**Setup:** A square box, completely filled with viscous fluid. All four walls are solid.
The only driver is the **top wall (lid), which slides horizontally** at constant speed.

```
 ──────────────────────────────→   lid moves right at U = 0.1
│                                │
│          viscous fluid         │
│                                │
│         (incompressible)       │
│                                │
 ────────────────────────────────   fixed bottom wall
^                                ^
fixed left wall               fixed right wall
```

There is **no inlet, no outlet, no pressure difference**. The only energy input is the moving lid.
The fluid has nowhere to go, so it forms a **recirculating vortex**.

**Why is this useful?**
It's one of the few fluid problems with well-known reference solutions (Ghia et al. 1982),
making it the standard benchmark to verify a new CFD solver is working correctly.

---

## 2. The Physics

The governing equations are the **incompressible Navier-Stokes equations**:

| Equation | Meaning |
|---|---|
| `∇·u = 0` | Incompressibility — fluid volume is conserved |
| `ρ Du/Dt = −∇p + μ∇²u` | Momentum — inertia = pressure gradient + viscous diffusion |

### Reynolds Number

The Reynolds number tells you the ratio of inertial to viscous forces:

```
Re = U_lid × L / ν
```

| Re | Character of the flow |
|---|---|
| Re = 100 | Viscosity dominates. One clean central vortex. |
| Re = 1000 | Inertia grows. Small secondary vortices appear in corners. |
| Re > 5000 | Flow becomes unsteady, eventually turbulent. |

This simulation runs at **Re = 100** by default.

### What Should the Solution Look Like?

At Re = 100, the lid drags fluid rightward at the top. That fluid hits the right wall,
descends, travels along the bottom, and rises up the left wall — a single **clockwise vortex**:

```
 ─────────────────→  lid
│  →  →  →  →  →  │
│ ↑             ↓  │
│ ↑   vortex    ↓  │
│ ↑             ↓  │
│  ←  ←  ←  ←  ←  │
 ──────────────────
```

---

## 3. What Is the Lattice Boltzmann Method?

LBM is a **mesoscopic** approach — it doesn't simulate individual molecules (too expensive),
and it doesn't solve the fluid equations directly. Instead, it simulates a simplified
**gas of particle populations** on a grid, and lets the Navier-Stokes equations
**emerge** from the statistics.

At every grid cell, instead of storing velocity directly, you store **9 distribution
functions** `f[i]` — one per direction — representing *how many particles are
heading that way*. Density and velocity are recovered as simple sums:

```
ρ   = Σ f[i]                 (sum all populations)
ρ·u = Σ f[i] · e[i]          (weighted sum by direction vectors)
```

Every timestep consists of exactly **two operations**:

```
COLLISION  →  particles at each cell scatter toward local equilibrium
STREAMING  →  particles propagate to their neighbouring cell
```

That's the whole method. Its appeal is that:
- Collision is **purely local** (no neighbours needed → trivially parallelisable)
- Streaming is a **simple array shift** (`np.roll` in NumPy)
- Pressure comes for **free** from density (`p = ρ·cs²`)
- Complex boundaries reduce to **reversing particle directions**

---

## 4. The D2Q9 Stencil

We use the standard **D2Q9** stencil: 2 Dimensions, 9 Velocities.

```
Direction index layout:

  6   2   5
  3   0   1       →   NW  N  NE
  7   4   8           W   0   E
                      SW  S  SE
```

Each direction `i` has:
- A **velocity vector** `e[i]` — which cell it points toward
- A **weight** `w[i]` — how much it contributes at equilibrium

```python
E = np.array([
    [ 0,  0],   # 0  rest
    [ 1,  0],   # 1  East
    [ 0,  1],   # 2  North
    [-1,  0],   # 3  West
    [ 0, -1],   # 4  South
    [ 1,  1],   # 5  NE
    [-1,  1],   # 6  NW
    [-1, -1],   # 7  SW
    [ 1, -1],   # 8  SE
])

W = np.array([4/9,                       # rest
              1/9,  1/9,  1/9,  1/9,     # axis-aligned
              1/36, 1/36, 1/36, 1/36])   # diagonals
```

The weights come from kinetic theory and must sum to 1. The rest direction gets the
most weight (4/9), diagonals the least (1/36).

The **speed of sound** in lattice units is `cs² = 1/3`. This is baked into the
equilibrium formula and is a fundamental constant of D2Q9.

---

## 5. The Two Core Steps

### Step 1 — Collision (BGK relaxation)

Each cell independently relaxes its `f` toward the **equilibrium** `f_eq`.
How fast it relaxes is controlled by `τ` (relaxation time):

```
f[i] +=  −(f[i] − f_eq[i]) / τ
```

- `τ → 0.5`: relaxes instantly → zero viscosity → unstable
- `τ → ∞` : relaxes slowly  → high viscosity → very diffusive

Viscosity is directly linked to τ:

```
ν = cs² · (τ − 0.5) = (τ − 0.5) / 3
```

### The Equilibrium Distribution

`f_eq` is what `f` would be at the current `ρ` and `u` if the fluid were at rest.
It's derived from a second-order Taylor expansion of the Maxwell-Boltzmann distribution:

```
f_eq[i] = w[i] · ρ · (1  +  3(e·u)  +  4.5(e·u)²  −  1.5|u|²)
                       ^^^^  ^^^^^^^^   ^^^^^^^^^^^^   ^^^^^^^^^
                       base  linear     quadratic      speed
                             (convection)(curvature)   correction
```

In code:
```python
def equilibrium(rho, ux, uy):
    f_eq = np.zeros((Q, NX, NY))
    u_sq = ux**2 + uy**2
    for i in range(Q):
        eu = E[i, 0] * ux + E[i, 1] * uy      # dot product e·u
        f_eq[i] = W[i] * rho * (1 + 3*eu + 4.5*eu**2 - 1.5*u_sq)
    return f_eq
```

### Step 2 — Streaming

After collision, each population slides **one cell in its own direction**.
In NumPy this is just a roll:

```python
for i in range(Q):
    f[i] = np.roll(f[i], shift=E[i, 0], axis=0)   # shift in x
    f[i] = np.roll(f[i], shift=E[i, 1], axis=1)   # shift in y
```

`np.roll` wraps around at edges (periodic). Walls then overwrite those wrapped
values with the correct boundary values in the next step.

---

## 6. Boundary Conditions

### Bounce-Back (No-Slip Walls)

For a solid wall, any particle that would stream *into* the wall is sent back
in the **opposite direction** — as if it bounced off. This produces zero fluid
velocity at the wall (no-slip condition).

```python
OPPOSITE = [0, 3, 4, 1, 2, 7, 8, 5, 6]   # OPPOSITE[i] = direction 180° from i

# On the left wall (x=0): reverse populations
for i in range(Q):
    f[i, 0, :] = f[OPPOSITE[i], 0, :]
```

This is applied to the left wall, right wall, and bottom wall.

### Zou-He Velocity BC (Moving Lid)

The bounce-back condition gives `u = 0`. For the moving lid we need `u = U_lid`.
The **Zou-He** method works by:

1. Computing `ρ` at the lid from the populations we *already know*
2. Setting the three *unknown* incoming populations analytically so that
   the resulting macroscopic velocity equals exactly `U_lid`

```python
# Known populations streaming away from the lid: directions 2, 5, 6
# Unknown populations streaming into the lid: directions 4, 7, 8

rho_lid = (f[0] + f[1] + f[3] + 2*(f[2] + f[5] + f[6])) / (1 + U_LID)

f[4, :, y] = f[2, :, y] - (2/3) * rho_lid * U_LID
f[7, :, y] = f[5, :, y] - (1/6) * rho_lid * U_LID + 0.5*(f[1] - f[3])
f[8, :, y] = f[6, :, y] + (1/6) * rho_lid * U_LID - 0.5*(f[1] - f[3])
```

---

## 7. Code Walkthrough

```
lbm_simple.py
│
├── Parameters           NX, NY, U_LID, RE, NU, TAU, N_STEPS
│
├── D2Q9 constants       E (velocity vectors), W (weights), OPPOSITE (bounce-back map)
│
├── macroscopic(f)       f → ρ, ux, uy via moment sums
│
├── equilibrium(ρ,u)     ρ, ux, uy → f_eq via BGK formula
│
├── Initialisation       f = f_eq(ρ=1, u=0)   — start at equilibrium
│
└── Main loop (N_STEPS)
    ├── 1. Collision      f += -(f - f_eq) / τ
    ├── 2. Streaming      np.roll per direction
    └── 3. Boundaries
        ├── Bounce-back   left wall, right wall, bottom
        └── Zou-He        top lid at U_LID
```

### Data Layout

The distribution function `f` has shape `(Q=9, NX, NY)`:

```
f[direction, x, y]

f[0, :, :]   ← density of particles at rest, at every cell
f[1, :, :]   ← density of particles heading East, at every cell
...
f[8, :, :]   ← density of particles heading SE, at every cell
```

All 9 arrays are updated simultaneously each timestep.

---

## 8. Parameters & Stability

| Parameter | Role | Safe range |
|---|---|---|
| `U_LID` | Lid speed in lattice units | `< 0.3` (Mach number limit) |
| `RE` | Reynolds number | Start low (`≤ 400`) |
| `TAU` | Relaxation time | `> 0.5` (always) |
| `N_STEPS` | How long to run | `≥ 5000` for Re=100 to converge |

**Stability rule of thumb:** `TAU` must stay above 0.5. It is set automatically from
`U_LID` and `RE` via:

```python
NU  = U_LID * NX / RE     # viscosity in lattice units
TAU = 3 * NU + 0.5        # BGK relaxation time
```

Raising `RE` reduces `NU`, which pushes `TAU` toward 0.5, which destabilises the
simulation. If you see `NaN` values, lower `RE` or lower `U_LID`.

---

## 9. Expected Output

After ~5000 steps at Re=100 you should see:

- **Speed map**: near-zero (purple) in the bulk, maximum (yellow) at the top corners
  where the lid meets the side walls
- **Streamlines**: one large clockwise vortex filling the cavity, with the vortex
  centre slightly right of center (pushed by inertia)

The vortex centre position is a standard benchmark quantity — at Re=100 it should
sit around `(x, y) ≈ (0.62, 0.74)` in normalised coordinates, matching Ghia et al. (1982).

---

## References

- Ghia, U., Ghia, K.N., Shin, C.T. (1982). *High-Re solutions for incompressible flow
  using the Navier-Stokes equations and a multigrid method.* Journal of Computational
  Physics, 48(3), 387–411. — The classic benchmark reference.

- Krueger, T. et al. (2017). *The Lattice Boltzmann Method: Principles and Practice.*
  Springer. — The definitive textbook.

- Zou, Q., He, X. (1997). *On pressure and velocity boundary conditions for the lattice
  Boltzmann BGK model.* Physics of Fluids, 9(6). — Source of the Zou-He BC used here.