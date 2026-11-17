cfg = ps.CreateKernelConfig(target=ps.Target.CurrentCPU, default_dtype="float64")
cfg.ghost_layers = 1                       # or: cfg.iteration_slice = ps.make_slice[1:-1, ::2]
cfg.cpu.openmp.enable = True
cfg.cpu.vectorize.enable = cfg.get_target().is_vector_cpu()
cfg.cpu.vectorize.assume_inner_stride_one = True
gpu_cfg = ps.CreateKernelConfig(target=ps.Target.CUDA)
gpu_cfg.gpu.indexing_scheme = "blockwise4d"
