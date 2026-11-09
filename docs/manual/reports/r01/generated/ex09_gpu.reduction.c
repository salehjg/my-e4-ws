__global__ void kernel(const double* RESTRICT const _data_x,
                       const int64_t _size_x_0, const int64_t _stride_x_0,
                       double* const total)
{
   double total_local = 0.0;
   const int64_t ctr_0 =
       (int64_t)blockIdx.x * (int64_t)blockDim.x + (int64_t)threadIdx.x;
   if (ctr_0 < _size_x_0)
   {
      total_local = total_local + _data_x[ctr_0 * _stride_x_0];
   }
   {
      total_local = total_local + __shfl_xor_sync(0xffffffff, total_local, 16);
      total_local = total_local + __shfl_xor_sync(0xffffffff, total_local, 8);
      total_local = total_local + __shfl_xor_sync(0xffffffff, total_local, 4);
      total_local = total_local + __shfl_xor_sync(0xffffffff, total_local, 2);
      total_local = total_local + __shfl_xor_sync(0xffffffff, total_local, 1);
      if (!(total_local == 0.0) && threadIdx.x % 32 == 0)
      {
         atomicAdd(total, total_local);
      }
   }
}
