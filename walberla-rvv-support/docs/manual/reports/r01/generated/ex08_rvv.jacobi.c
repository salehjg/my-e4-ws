void kernel(float* RESTRICT const _data_dst, const float* RESTRICT const _data_src,
            const int64_t _size_dst_0, const int64_t _size_dst_1,
            const int64_t _stride_dst_0, const int64_t _stride_src_0)
{
   const vfloat32m1_t __c__1_1_1_1_1_1_1_1__o_4_4_4_4_4_4_4_4____0 =
       __riscv_vfdiv_vv_f32m1(__riscv_vfmv_v_f_f32m1(1.0f, 8uLL),
                              __riscv_vfmv_v_f_f32m1(4.0f, 8uLL), 8uLL);
   const float __c_1_0o4_0 = 1.0f / 4.0f;
   const int64_t ctr_1__rem_start = 1LL + (_size_dst_1 - 1LL - 1LL) / 8LL * 8LL;
   {
#pragma omp parallel
      {
#pragma omp for schedule(static)
         for (int64_t ctr_0 = 1LL; ctr_0 < _size_dst_0 - 1LL; ctr_0 += 1LL)
         {
            for (int64_t ctr_1__1 = 1LL; ctr_1__1 < ctr_1__rem_start;
                 ctr_1__1 += 8LL)
            {
               const int64_t ctr_1 = ctr_1__1;
               __riscv_vse32_v_f32m1(
                   &_data_dst[ctr_0 * _stride_dst_0 + ctr_1],
                   __riscv_vfadd_vv_f32m1(
                       __riscv_vfadd_vv_f32m1(
                           __riscv_vfadd_vv_f32m1(
                               __riscv_vfmul_vv_f32m1(
                                   __c__1_1_1_1_1_1_1_1__o_4_4_4_4_4_4_4_4____0,
                                   __riscv_vle32_v_f32m1(
                                       &_data_src[(ctr_0 + 1LL) * _stride_src_0 +
                                                  ctr_1],
                                       8uLL),
                                   8uLL),
                               __riscv_vfmul_vv_f32m1(
                                   __c__1_1_1_1_1_1_1_1__o_4_4_4_4_4_4_4_4____0,
                                   __riscv_vle32_v_f32m1(
                                       &_data_src[ctr_0 * _stride_src_0 +
                                                  (ctr_1 + 1LL)],
                                       8uLL),
                                   8uLL),
                               8uLL),
                           __riscv_vfmul_vv_f32m1(
                               __c__1_1_1_1_1_1_1_1__o_4_4_4_4_4_4_4_4____0,
                               __riscv_vle32_v_f32m1(
                                   &_data_src[ctr_0 * _stride_src_0 +
                                              (ctr_1 + -1LL)],
                                   8uLL),
                               8uLL),
                           8uLL),
                       __riscv_vfmul_vv_f32m1(
                           __c__1_1_1_1_1_1_1_1__o_4_4_4_4_4_4_4_4____0,
                           __riscv_vle32_v_f32m1(
                               &_data_src[(ctr_0 + -1LL) * _stride_src_0 + ctr_1],
                               8uLL),
                           8uLL),
                       8uLL),
                   8uLL);
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
