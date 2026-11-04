void kernel(const double* RESTRICT const _data_u,
            double* RESTRICT const _data_u_new, const int64_t _size_u_0,
            const int64_t _size_u_1, const int64_t _stride_u_0,
            const int64_t _stride_u_1, const int64_t _stride_u_new_0,
            const int64_t _stride_u_new_1, const double alpha)
{
   for (int64_t ctr_0 = 1LL; ctr_0 < _size_u_0 - 1LL; ctr_0 += 1LL)
   {
      for (int64_t ctr_1 = 1LL; ctr_1 < _size_u_1 - 1LL; ctr_1 += 1LL)
      {
         const double lap =
             -4.0 * _data_u[ctr_0 * _stride_u_0 + ctr_1 * _stride_u_1] +
             _data_u[(ctr_0 + 1LL) * _stride_u_0 + ctr_1 * _stride_u_1] +
             _data_u[ctr_0 * _stride_u_0 + (ctr_1 + 1LL) * _stride_u_1] +
             _data_u[ctr_0 * _stride_u_0 + (ctr_1 + -1LL) * _stride_u_1] +
             _data_u[(ctr_0 + -1LL) * _stride_u_0 + ctr_1 * _stride_u_1];
         _data_u_new[ctr_0 * _stride_u_new_0 + ctr_1 * _stride_u_new_1] =
             alpha * lap + _data_u[ctr_0 * _stride_u_0 + ctr_1 * _stride_u_1];
      }
   }
}
