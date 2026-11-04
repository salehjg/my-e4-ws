void manual_kernel(double* RESTRICT const _data_f, double* RESTRICT const _data_g,
                   const int64_t _size_f_0, const int64_t _size_f_1,
                   const int64_t _stride_f_1, const int64_t _stride_g_1,
                   const double c)
{
   const int64_t ctr_0__rem_start = _size_f_0 / 4LL * 4LL;
   {
#pragma omp parallel
      {
#pragma omp for
         for (int64_t ctr_1 = 0LL; ctr_1 < _size_f_1; ctr_1 += 1LL)
         {
            for (int64_t ctr_0__1 = 0LL; ctr_0__1 < ctr_0__rem_start;
                 ctr_0__1 += 4LL)
            {
               const int64_t ctr_0 = ctr_0__1;
               _mm256_storeu_pd(
                   &_data_g[ctr_0 + ctr_1 * _stride_g_1],
                   _mm256_add_pd(
                       _mm256_set_pd(1.0, 1.0, 1.0, 1.0),
                       _mm256_mul_pd(_mm256_set1_pd(c),
                                     _mm256_loadu_pd(
                                         &_data_f[ctr_0 + ctr_1 * _stride_f_1]))));
            }
            for (int64_t ctr_0__0 = ctr_0__rem_start; ctr_0__0 < _size_f_0;
                 ctr_0__0 += 1LL)
            {
               _data_g[ctr_0__0 + ctr_1 * _stride_g_1] =
                   1.0 + c * _data_f[ctr_0__0 + ctr_1 * _stride_f_1];
            }
         }
      }
   }
}
