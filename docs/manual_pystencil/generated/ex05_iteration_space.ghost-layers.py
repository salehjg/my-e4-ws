k_auto = ps.create_kernel(asm)                        # AUTO: inferred from accesses -> 0
k_gl2 = ps.create_kernel(asm, ghost_layers=2)         # 2 on every side
k_gl_sides = ps.create_kernel(asm, ghost_layers=[(1, 3), 0])  # (low, high) per axis
