"""Chapter 4/10: CUDA code generation (no GPU or cupy needed to *generate* code)."""

from _manual import save, save_c

import pystencils as ps

src, dst = ps.fields("src, dst: double[2D]")
update = ps.Assignment(dst.center, (src[1, 0] + src[-1, 0] + src[0, 1] + src[0, -1]) / 4)

# [cuda]
cfg = ps.CreateKernelConfig(target=ps.Target.CUDA)
cuda_kernel = ps.create_kernel(update, cfg)          # a GpuKernel
# [/cuda]
save_c("linear3d", cuda_kernel.get_c_code())
save("headers", "\n".join(sorted(cuda_kernel.required_headers)))

# [schemes]
launch_configs = {}
for scheme in ["linear3d", "gridstrided_linear3d", "blockwise4d"]:
    c = cfg.copy()
    c.gpu.indexing_scheme = scheme
    k = ps.create_kernel(update, c)
    launch_configs[scheme] = type(k.get_launch_configuration()).__name__

c = cfg.copy()
c.gpu.manual_launch_grid = True
launch_configs["linear3d + manual_launch_grid"] = type(
    ps.create_kernel(update, c).get_launch_configuration()).__name__
# [/schemes]
save("schemes", "\n".join(f"{k:<30} -> {v}" for k, v in launch_configs.items()))

c = cfg.copy()
c.gpu.indexing_scheme = "blockwise4d"
save_c("blockwise4d", ps.create_kernel(update, c).get_c_code())

# [gpu-reduction]
x = ps.fields("x: double[1D]")
total = ps.TypedSymbol("total", "double")
c = cfg.copy()
c.gpu.assume_warp_aligned_block_size = True       # together with an explicit
c.gpu.warp_size = 32                              # warp size: warp-level shuffles
gpu_red = ps.create_kernel(ps.AddReductionAssignment(total, x.center), c)
# [/gpu-reduction]
save_c("reduction", gpu_red.get_c_code())

# [launch]
lc = cuda_kernel.get_launch_configuration()     # DynamicBlockSizeLaunchConfiguration
sizes = dict(_size_dst_0=130, _size_dst_1=1026)  # 128 x 1024 interior cells

block, grid = lc.evaluate(**sizes)              # default block size (16, 16, 1)
lc.fit_block_size((8, 8, 4))                    # adapt to the iteration space
block_fit, grid_fit = lc.evaluate(**sizes)
# [/launch]
save("launch", "\n".join([
    f"parameters        : {sorted(p.name for p in lc.parameters)}",
    f"default           : block {block}, grid {grid}",
    f"fit_block_size    : block {block_fit}, grid {grid_fit}",
]))
