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
