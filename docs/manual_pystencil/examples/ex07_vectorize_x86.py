"""Chapter 4/10: OpenMP + explicit SIMD vectorization for x86 AVX."""

from _manual import save, save_c

import numpy as np
import pystencils as ps

src, dst = ps.fields("src, dst: double[2D]")
update = ps.Assignment(dst.center, (src[1, 0] + src[-1, 0] + src[0, 1] + src[0, -1]) / 4)

# [config]
cfg = ps.CreateKernelConfig(target=ps.Target.X86_AVX)
cfg.cpu.openmp.enable = True
cfg.cpu.vectorize.enable = True
cfg.cpu.vectorize.assume_inner_stride_one = True   # contiguous fastest coordinate

avx = ps.create_kernel(update, cfg)
# [/config]
save_c("code", avx.get_c_code())
save("headers", "\n".join(sorted(avx.required_headers)))

# [copy]
cfg_sse = cfg.copy()                    # configs are copied, never shared
cfg_sse.target = ps.Target.X86_SSE
sse = ps.create_kernel(update, cfg_sse)
# [/copy]
assert "_mm_loadu_pd" in sse.get_c_code()

#   Run on this host if it supports AVX (it is checked against NumPy).
if ps.Target.X86_AVX in ps.Target.available_targets():
    # [run]
    fn = avx.compile()
    a = np.random.default_rng(3).random((30, 37))   # 35 inner points: not a multiple of 4
    b = np.zeros_like(a)
    fn(src=a, dst=b)
    # [/run]
    ref = (a[2:, 1:-1] + a[:-2, 1:-1] + a[1:-1, 2:] + a[1:-1, :-2]) / 4
    assert np.allclose(b[1:-1, 1:-1], ref)
    save("check", "AVX kernel executed on this host; NumPy reference check: OK")

save("targets", "\n".join([
    f"Target.available_targets()      = {[t.name for t in ps.Target.available_targets()]}",
    f"Target.auto_cpu()               = {ps.Target.auto_cpu().name}",
    f"X86_AVX.default_vector_lanes(float64) = {ps.Target.X86_AVX.default_vector_lanes(ps.create_type('float64'))}",
    f"X86_AVX.default_vector_lanes(float32) = {ps.Target.X86_AVX.default_vector_lanes(ps.create_type('float32'))}",
]))

# [blocking]
f, g = ps.fields("f, g: double[2D]")
cfg_block = ps.CreateKernelConfig(ghost_layers=0)
cfg_block.cpu.openmp.enable = True
cfg_block.cpu.loop_blocking = (16, 8)          # 16 x 8 tiles
blocked = ps.create_kernel(ps.Assignment(g.center, 2 * f.center), cfg_block)
# [/blocking]
save_c("blocking", blocked.get_c_code())
