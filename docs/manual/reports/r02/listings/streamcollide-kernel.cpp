void StreamCollide (const double * RESTRICT const _data_f, double * RESTRICT const _data_f_tmp,
                    double * RESTRICT const _data_rho, double * RESTRICT const _data_u,
                    const int64_t _size_f_0, const int64_t _size_f_1, const int64_t _size_f_2,
                    const int64_t _stride_f_1, const int64_t _stride_f_2, const int64_t _stride_f_3,
                    /* ... strides of f_tmp, rho, u ... */ const double omega)
{
  // Vector constants are hoisted out of the loops (here 1/6 as a 4-lane vector)
  const vfloat64m1_t __c__1_1_1_1__o_6_6_6_6____0 = __riscv_vfdiv_vv_f64m1(
      __riscv_vfmv_v_f_f64m1(1.0, 4uLL), __riscv_vfmv_v_f_f64m1(6.0, 4uLL), 4uLL);
  // ... 8 more vector constants, and their scalar twins for the remainder loop ...
  const int64_t ctr_0__rem_start = _size_f_0 / 4LL * 4LL;
  for(int64_t ctr_2 = 0LL; ctr_2 < _size_f_2; ctr_2 += 1LL)
  {
    for(int64_t ctr_1 = 0LL; ctr_1 < _size_f_1; ctr_1 += 1LL)
    {
      // Vector loop: 4 cells along x per iteration, one vfloat64m1_t each
      for(int64_t ctr_0__1 = 0LL; ctr_0__1 < ctr_0__rem_start; ctr_0__1 += 4LL)
      {
        const int64_t ctr_0 = ctr_0__1;
        // pull: gather PDFs from the neighbours, e.g. direction 2 from y+1 and 16 from (y+1, z+1)
        const vfloat64m1_t xi_6__2 = __riscv_vfadd_vv_f64m1(
            __riscv_vle64_v_f64m1(&_data_f[ctr_0 + (ctr_1 + 1LL) * _stride_f_1 + ctr_2 * _stride_f_2
                                           + 2LL * _stride_f_3], 4uLL),
            __riscv_vle64_v_f64m1(&_data_f[ctr_0 + (ctr_1 + 1LL) * _stride_f_1 + (ctr_2 + 1LL) * _stride_f_2
                                           + 16LL * _stride_f_3], 4uLL), 4uLL);
        // ... density and momentum sums ...
        const vfloat64m1_t rho__2 = __riscv_vfadd_vv_f64m1(__riscv_vfmv_v_f_f64m1(1.0, 4uLL),
                                                          delta_rho__2, 4uLL);
        const vfloat64m1_t xi_3__2 = __riscv_vfdiv_vv_f64m1(__riscv_vfmv_v_f_f64m1(1.0, 4uLL),
                                                           rho__2, 4uLL);      // 1 / rho
        const vfloat64m1_t u_0__2 = __riscv_vfmul_vv_f64m1(xi_3__2, xi_7__2, 4uLL);
        // ... equilibrium and collision, then 19 PDF stores like this one:
        __riscv_vse64_v_f64m1(&_data_f_tmp[ctr_0 + ctr_1 * _stride_f_tmp_1 + ctr_2 * _stride_f_tmp_2],
            __riscv_vfadd_vv_f64m1(__riscv_vfmul_vv_f64m1(__riscv_vfmv_v_f_f64m1(omega, 4uLL), /* ... */),
                                   /* ... */, 4uLL), 4uLL);
        // ... plus rho and the 3 velocity components
        __riscv_vse64_v_f64m1(&_data_rho[ctr_0 + ctr_1 * _stride_rho_1 + ctr_2 * _stride_rho_2], rho__2, 4uLL);
      }
      // Scalar remainder loop: the same update in plain C++ for the last _size_f_0 % 4 cells
      for(int64_t ctr_0__0 = ctr_0__rem_start; ctr_0__0 < _size_f_0; ctr_0__0 += 1LL)
      {
        const double xi_6__0 = _data_f[ctr_0__0 + (ctr_1 + 1LL) * _stride_f_1 + ctr_2 * _stride_f_2 + 2LL * _stride_f_3]
                             + _data_f[ctr_0__0 + (ctr_1 + 1LL) * _stride_f_1 + (ctr_2 + 1LL) * _stride_f_2 + 16LL * _stride_f_3];
        // ...
      }
    }
  }
}
