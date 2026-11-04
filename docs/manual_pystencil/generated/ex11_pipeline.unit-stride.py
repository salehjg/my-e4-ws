from pystencils.backend.constants import PsConstant

inner = ispace.loop_order[-1]          # fastest coordinate (ctr_0 for fzyx)
for fld in (f, g):                     # what cpu.vectorize.assume_inner_stride_one does
    buf = ctx.get_buffer(fld)
    buf.strides[inner] = PsConstant(1, buf.index_type)
