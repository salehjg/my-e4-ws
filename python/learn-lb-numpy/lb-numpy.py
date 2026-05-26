# claude generated

"""
Lattice Boltzmann Method — Lid-Driven Cavity
=============================================
A minimal D2Q9 implementation in plain NumPy.

Grid: NX x NY cells
Top wall moves at velocity U_LID → drives a recirculating flow
"""

import numpy as np
import matplotlib.pyplot as plt

# ── Grid & physical parameters ─────────────────────────────────────────────
NX, NY   = 100, 100       # grid size
U_LID    = 0.1            # lid velocity (in lattice units, keep < 0.3)
RE       = 100            # Reynolds number
NU       = U_LID * NX / RE  # kinematic viscosity (derived)
TAU      = 3 * NU + 0.5   # relaxation time  (τ > 0.5 for stability)
N_STEPS  = 5000           # time steps to run

# ── D2Q9 velocity set ──────────────────────────────────────────────────────
#   Direction index:  0   1   2   3   4   5   6   7   8
#                     0   E   N   W   S  NE  NW  SW  SE
E = np.array([        # lattice velocity vectors [i, xy]
    [ 0,  0],         # 0  rest
    [ 1,  0],         # 1  East
    [ 0,  1],         # 2  North
    [-1,  0],         # 3  West
    [ 0, -1],         # 4  South
    [ 1,  1],         # 5  NE
    [-1,  1],         # 6  NW
    [-1, -1],         # 7  SW
    [ 1, -1],         # 8  SE
])

W = np.array([4/9,              # weight for rest
              1/9,  1/9,  1/9,  1/9,       # axis-aligned
              1/36, 1/36, 1/36, 1/36])     # diagonals

# Opposite direction of each index (used for bounce-back walls)
OPPOSITE = [0, 3, 4, 1, 2, 7, 8, 5, 6]

Q = 9  # number of directions

# ── Helper: compute macroscopic quantities from f ──────────────────────────
def macroscopic(f):
    """
    f has shape (Q, NX, NY).
    Returns:
      rho : (NX, NY)  — density  = Σ f[i]
      ux  : (NX, NY)  — x-velocity = Σ f[i] * e[i,x] / rho
      uy  : (NX, NY)  — y-velocity = Σ f[i] * e[i,y] / rho
    """
    rho = f.sum(axis=0)
    ux  = np.einsum('i,ixy->xy', E[:, 0], f) / rho
    uy  = np.einsum('i,ixy->xy', E[:, 1], f) / rho
    return rho, ux, uy

# ── Helper: compute equilibrium distribution ──────────────────────────────
def equilibrium(rho, ux, uy):
    """
    f_eq[i] = w[i] * rho * (1 + 3(e·u) + 4.5(e·u)² − 1.5|u|²)
    This is a second-order Taylor expansion of the Maxwell-Boltzmann distribution.
    Returns f_eq of shape (Q, NX, NY).
    """
    f_eq = np.zeros((Q, NX, NY))
    u_sq = ux**2 + uy**2                     # |u|²  shape (NX, NY)
    for i in range(Q):
        eu = E[i, 0] * ux + E[i, 1] * uy    # e·u   shape (NX, NY)
        f_eq[i] = W[i] * rho * (1 + 3*eu + 4.5*eu**2 - 1.5*u_sq)
    return f_eq

# ── Initialise: fluid at rest ──────────────────────────────────────────────
rho = np.ones((NX, NY))
ux  = np.zeros((NX, NY))
uy  = np.zeros((NX, NY))
f   = equilibrium(rho, ux, uy)   # start at equilibrium → no transient noise

# ── Main loop ─────────────────────────────────────────────────────────────
for step in range(N_STEPS):

    # ── 1. COLLISION (BGK) ────────────────────────────────────────────────
    #   Nudge f toward f_eq.  τ controls how quickly (viscosity).
    #   f ← f − (f − f_eq) / τ
    rho, ux, uy = macroscopic(f)
    f_eq = equilibrium(rho, ux, uy)
    f += -(f - f_eq) / TAU

    # ── 2. STREAMING ──────────────────────────────────────────────────────
    #   Each population slides one cell in its own direction.
    #   np.roll handles the periodic shift; walls fix this up next.
    for i in range(Q):
        f[i] = np.roll(f[i], shift=E[i, 0], axis=0)  # shift in x
        f[i] = np.roll(f[i], shift=E[i, 1], axis=1)  # shift in y

    # ── 3. BOUNDARY CONDITIONS ────────────────────────────────────────────

    # --- Bounce-back on bottom, left, right walls (no-slip: u=0) ----------
    #   Any population that streamed INTO a wall is reversed.
    #   We just swap f[i] with f[opposite_i] on the wall nodes.
    for i in range(Q):
        op = OPPOSITE[i]
        f[i, 0,  :] = f[op, 0,  :]   # left wall   (x=0)
        f[i, -1, :] = f[op, -1, :]   # right wall  (x=NX-1)
        f[i, :,  0] = f[op, :,  0]   # bottom wall (y=0)

    # --- Moving lid (top wall, y=NY-1): Zou-He velocity BC ----------------
    #   We KNOW the velocity at the lid: ux=U_LID, uy=0.
    #   Compute rho from the known populations, then set the unknown ones.
    y = NY - 1
    # Populations streaming away from lid (known after bounce-back): 2,5,6
    # Populations streaming into lid (unknown): 4,7,8
    rho_lid = (f[0, :, y] + f[1, :, y] + f[3, :, y]
             + 2*(f[2, :, y] + f[5, :, y] + f[6, :, y])) / (1 + U_LID)

    # Set the three unknown populations using the Zou-He formula
    f[4, :, y] = f[2, :, y] - (2/3) * rho_lid * U_LID   # wait, uy=0, ux=U_LID
    f[7, :, y] = f[5, :, y] - (1/6) * rho_lid * U_LID \
                             + 0.5 * (f[1, :, y] - f[3, :, y])
    f[8, :, y] = f[6, :, y] + (1/6) * rho_lid * U_LID \
                             - 0.5 * (f[1, :, y] - f[3, :, y])

    if step % 500 == 0:
        speed = np.sqrt(ux**2 + uy**2)
        print(f"  step {step:5d}   max speed = {speed.max():.4f}")

# ── Visualise the result ───────────────────────────────────────────────────
rho, ux, uy = macroscopic(f)
speed = np.sqrt(ux**2 + uy**2)

fig, axes = plt.subplots(1, 2, figsize=(12, 5))
fig.suptitle(f"Lid-Driven Cavity  (Re={RE}, {NX}×{NY}, {N_STEPS} steps)", fontsize=13)

# Speed contour
im = axes[0].imshow(speed.T, origin='lower', cmap='viridis', interpolation='bilinear')
axes[0].set_title("Speed |u|")
axes[0].set_xlabel("x"); axes[0].set_ylabel("y")
plt.colorbar(im, ax=axes[0])

# Streamlines
X, Y = np.meshgrid(np.arange(NX), np.arange(NY), indexing='ij')
axes[1].streamplot(X.T, Y.T, ux.T, uy.T, color=speed.T,
                   cmap='plasma', density=1.5, linewidth=0.8)
axes[1].set_title("Streamlines")
axes[1].set_xlabel("x"); axes[1].set_ylabel("y")

plt.tight_layout()
plt.savefig("lbm_result.png", dpi=150)
plt.show()
print("Done! Saved lbm_result.png")