lc = cuda_kernel.get_launch_configuration()     # DynamicBlockSizeLaunchConfiguration
sizes = dict(_size_dst_0=130, _size_dst_1=1026)  # 128 x 1024 interior cells

block, grid = lc.evaluate(**sizes)              # default block size (16, 16, 1)
lc.fit_block_size((8, 8, 4))                    # adapt to the iteration space
block_fit, grid_fit = lc.evaluate(**sizes)
