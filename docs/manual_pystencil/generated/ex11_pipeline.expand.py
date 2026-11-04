ae = AxisExpansion(ctx)
strategy = ae.create_strategy([
    ae.parallel_loop(),                            # ctr_1 (slow): OpenMP loop
    ae.peel_for_divisibility(4),                   # ctr_0 (fast): split off remainder
    [ae.block_loop(4, assume_divisible=True), ae.simd(4)],   # ... 4-wide SIMD body
    [ae.loop()],                                   # ... scalar remainder loop
])
kernel_ast = strategy(cube)
kernel_ast = HoistIterationInvariantDeclarations(ctx)(kernel_ast)
