f, g = ps.fields("f, g: double[2D]")
cfg_block = ps.CreateKernelConfig(ghost_layers=0)
cfg_block.cpu.openmp.enable = True
cfg_block.cpu.loop_blocking = (16, 8)          # 16 x 8 tiles
blocked = ps.create_kernel(ps.Assignment(g.center, 2 * f.center), cfg_block)
