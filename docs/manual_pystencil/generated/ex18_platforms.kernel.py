f, g = ps.fields("f, g: double[1D]")
c = sp.Symbol("c")
asm = ps.Assignment(g.center, c * f.center + 1)


def vector_kernel(target, lanes=None):
    cfg = ps.CreateKernelConfig(target=target)
    cfg.cpu.vectorize.enable = True
    cfg.cpu.vectorize.assume_inner_stride_one = True
    if lanes is not None:
        cfg.cpu.vectorize.lanes = lanes      # required for ARM_SVE
    return ps.create_kernel(asm, cfg)
