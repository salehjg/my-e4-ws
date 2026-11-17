"""Chapter 2/5: the first kernel -- a 2D Jacobi smoother, end to end."""

from _manual import save, save_c, save_params

# [imports]
import numpy as np
import pystencils as ps
# [/imports]

# [fields]
src, dst = ps.fields("src, dst: double[2D]")
# [/fields]

# [assignment]
update = ps.Assignment(
    dst.center(), (src[1, 0] + src[-1, 0] + src[0, 1] + src[0, -1]) / 4
)
# [/assignment]
save("assignment", update)

# [create]
kernel = ps.create_kernel(update)  # default config: Target.GenericCPU, float64
# [/create]

save_c("code", kernel.get_c_code())
save("ir", kernel.get_ir_code())
save_params("params", kernel)
save("headers", "\n".join(sorted(kernel.required_headers)))
save("str", str(kernel))
save("metadata", kernel.metadata)

# [run]
jacobi = kernel.compile()  # C++ -> Python extension module, loaded on the fly

rng = np.random.default_rng(seed=42)
src_arr = rng.random((64, 48))  # includes one ghost layer on each side
dst_arr = np.zeros_like(src_arr)

jacobi(src=src_arr, dst=dst_arr)  # keyword arguments = field names
# [/run]

# [check]
expected = (
    src_arr[2:, 1:-1] + src_arr[:-2, 1:-1] + src_arr[1:-1, 2:] + src_arr[1:-1, :-2]
) / 4
assert np.allclose(dst_arr[1:-1, 1:-1], expected)
assert np.all(dst_arr[0, :] == 0.0)  # ghost layers are not written
# [/check]

save("wrapper", f"{type(jacobi).__name__} wrapping kernel {jacobi.kernel.name!r}")
save("check", "NumPy reference check: OK")
