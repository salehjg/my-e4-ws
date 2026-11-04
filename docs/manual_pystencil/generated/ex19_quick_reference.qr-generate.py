kernel = ps.create_kernel(rule, cfg)       # -> Kernel (GpuKernel for CUDA/HIP)
code = kernel.get_c_code()                 # C/C++ text; ps.inspect(kernel, show_cpp=True)
ir = kernel.get_ir_code()                  # typed IR
params = [(p.name, str(p.dtype)) for p in kernel.parameters]
headers = kernel.required_headers          # #include list
gl = kernel.metadata["ghost_layers"]
