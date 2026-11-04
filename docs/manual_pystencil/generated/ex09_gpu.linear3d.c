__global__ void kernel(double* RESTRICT const _data_dst,
                       const double* RESTRICT const _data_src,
                       const int64_t _size_dst_0, const int64_t _size_dst_1,
                       const int64_t _stride_dst_0, const int64_t _stride_dst_1,
                       const int64_t _stride_src_0, const int64_t _stride_src_1)
{
   const double __c_1_0o4_0 = 1.0 / 4.0;
   const int64_t ctr_0 =
       1LL + ((int64_t)blockIdx.y * (int64_t)blockDim.y + (int64_t)threadIdx.y);
   const int64_t ctr_1 =
       1LL + ((int64_t)blockIdx.x * (int64_t)blockDim.x + (int64_t)threadIdx.x);
   if (ctr_0 < _size_dst_0 - 1LL && ctr_1 < _size_dst_1 - 1LL)
   {
      _data_dst[ctr_0 * _stride_dst_0 + ctr_1 * _stride_dst_1] =
          __c_1_0o4_0 *
              _data_src[(ctr_0 + 1LL) * _stride_src_0 + ctr_1 * _stride_src_1] +
          __c_1_0o4_0 *
              _data_src[ctr_0 * _stride_src_0 + (ctr_1 + 1LL) * _stride_src_1] +
          __c_1_0o4_0 *
              _data_src[ctr_0 * _stride_src_0 + (ctr_1 + -1LL) * _stride_src_1] +
          __c_1_0o4_0 *
              _data_src[(ctr_0 + -1LL) * _stride_src_0 + ctr_1 * _stride_src_1];
   }
}
