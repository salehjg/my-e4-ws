void kernel(double* RESTRICT const _data_s, const int64_t _size_s_0,
            const int64_t _size_s_1, const int64_t _stride_s_0,
            const int64_t _stride_s_1)
{
   const int64_t ctr_1__rem_start = _size_s_1 / 4LL * 4LL;
   for (int64_t ctr_0 = 0LL; ctr_0 < _size_s_0; ctr_0 += 1LL)
   {
      for (int64_t ctr_1__1 = 0LL; ctr_1__1 < ctr_1__rem_start; ctr_1__1 += 4LL)
      {
         const int64_t ctr_1 = ctr_1__1;
         __riscv_vsse64_v_f64m1(
             &_data_s[ctr_0 * _stride_s_0 + ctr_1 * _stride_s_1], 8LL * _stride_s_1,
             __riscv_vfmul_vv_f64m1(
                 __riscv_vfmv_v_f_f64m1(3.0, 4uLL),
                 __riscv_vlse64_v_f64m1(
                     &_data_s[ctr_0 * _stride_s_0 + ctr_1 * _stride_s_1],
                     8LL * _stride_s_1, 4uLL),
                 4uLL),
             4uLL);
      }
      for (int64_t ctr_1__0 = ctr_1__rem_start; ctr_1__0 < _size_s_1;
           ctr_1__0 += 1LL)
      {
         _data_s[ctr_0 * _stride_s_0 + ctr_1__0 * _stride_s_1] =
             3.0 * _data_s[ctr_0 * _stride_s_0 + ctr_1__0 * _stride_s_1];
      }
   }
}
