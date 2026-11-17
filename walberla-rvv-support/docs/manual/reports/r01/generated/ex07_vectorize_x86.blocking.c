void kernel(const double* RESTRICT const _data_f, double* RESTRICT const _data_g,
            const int64_t _size_f_0, const int64_t _size_f_1,
            const int64_t _stride_f_0, const int64_t _stride_f_1,
            const int64_t _stride_g_0, const int64_t _stride_g_1)
{
#pragma omp parallel
   {
#pragma omp for schedule(static)
      for (int64_t ctr_0__0 = 0LL; ctr_0__0 < _size_f_0; ctr_0__0 += 16LL)
      {
         for (int64_t ctr_1__0 = 0LL; ctr_1__0 < _size_f_1; ctr_1__0 += 8LL)
         {
            for (int64_t ctr_0 = ctr_0__0;
                 ctr_0 <
                 (_size_f_0 <= ctr_0__0 + 16LL ? _size_f_0 : ctr_0__0 + 16LL);
                 ctr_0 += 1LL)
            {
               for (int64_t ctr_1 = ctr_1__0;
                    ctr_1 <
                    (_size_f_1 <= ctr_1__0 + 8LL ? _size_f_1 : ctr_1__0 + 8LL);
                    ctr_1 += 1LL)
               {
                  _data_g[ctr_0 * _stride_g_0 + ctr_1 * _stride_g_1] =
                      2.0 * _data_f[ctr_0 * _stride_f_0 + ctr_1 * _stride_f_1];
               }
            }
         }
      }
   }
}
