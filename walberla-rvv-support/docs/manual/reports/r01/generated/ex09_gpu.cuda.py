cfg = ps.CreateKernelConfig(target=ps.Target.CUDA)
cuda_kernel = ps.create_kernel(update, cfg)          # a GpuKernel
