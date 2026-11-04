cfg_sse = cfg.copy()                    # configs are copied, never shared
cfg_sse.target = ps.Target.X86_SSE
sse = ps.create_kernel(update, cfg_sse)
