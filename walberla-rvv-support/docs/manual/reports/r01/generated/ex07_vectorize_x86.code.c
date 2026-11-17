void kernel(double* RESTRICT const _data_dst,
            const double* RESTRICT const _data_src, const int64_t _size_dst_0,
            const int64_t _size_dst_1, const int64_t _stride_dst_0,
            const int64_t _stride_src_0)
{
   const __m256d __c__1_1_1_1__o_4_4_4_4____0 = _mm256_div_pd(
       _mm256_set_pd(1.0, 1.0, 1.0, 1.0), _mm256_set_pd(4.0, 4.0, 4.0, 4.0));
   const double __c_1_0o4_0 = 1.0 / 4.0;
   const int64_t ctr_1__rem_start = 1LL + (_size_dst_1 - 1LL - 1LL) / 4LL * 4LL;
   {
#pragma omp parallel
      {
#pragma omp for schedule(static)
         for (int64_t ctr_0 = 1LL; ctr_0 < _size_dst_0 - 1LL; ctr_0 += 1LL)
         {
            for (int64_t ctr_1__1 = 1LL; ctr_1__1 < ctr_1__rem_start;
                 ctr_1__1 += 4LL)
            {
               const int64_t ctr_1 = ctr_1__1;
               _mm256_storeu_pd(
                   &_data_dst[ctr_0 * _stride_dst_0 + ctr_1],
                   _mm256_add_pd(
                       _mm256_add_pd(
                           _mm256_add_pd(
                               _mm256_mul_pd(
                                   __c__1_1_1_1__o_4_4_4_4____0,
                                   _mm256_loadu_pd(
                                       &_data_src[(ctr_0 + 1LL) * _stride_src_0 +
                                                  ctr_1])),
                               _mm256_mul_pd(__c__1_1_1_1__o_4_4_4_4____0,
                                             _mm256_loadu_pd(
                                                 &_data_src[ctr_0 * _stride_src_0 +
                                                            (ctr_1 + 1LL)]))),
                           _mm256_mul_pd(
                               __c__1_1_1_1__o_4_4_4_4____0,
                               _mm256_loadu_pd(&_data_src[ctr_0 * _stride_src_0 +
                                                          (ctr_1 + -1LL)]))),
                       _mm256_mul_pd(__c__1_1_1_1__o_4_4_4_4____0,
                                     _mm256_loadu_pd(
                                         &_data_src[(ctr_0 + -1LL) * _stride_src_0 +
                                                    ctr_1]))));
            }
            for (int64_t ctr_1__0 = ctr_1__rem_start; ctr_1__0 < _size_dst_1 - 1LL;
                 ctr_1__0 += 1LL)
            {
               _data_dst[ctr_0 * _stride_dst_0 + ctr_1__0] =
                   __c_1_0o4_0 *
                       _data_src[(ctr_0 + 1LL) * _stride_src_0 + ctr_1__0] +
                   __c_1_0o4_0 *
                       _data_src[ctr_0 * _stride_src_0 + (ctr_1__0 + 1LL)] +
                   __c_1_0o4_0 *
                       _data_src[ctr_0 * _stride_src_0 + (ctr_1__0 + -1LL)] +
                   __c_1_0o4_0 *
                       _data_src[(ctr_0 + -1LL) * _stride_src_0 + ctr_1__0];
            }
         }
      }
   }
}
