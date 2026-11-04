void kernel(const double* RESTRICT const _data_x, const int64_t _size_x_0,
            double* const w)
{
   double w_local = 0.0;
   const int64_t ctr_0__rem_start = _size_x_0 / 4LL * 4LL;
   {
#pragma omp parallel reduction(+ : w_local)
      {
         vfloat64m1_t w_local__1 = __riscv_vfmv_v_f_f64m1(0.0, 4uLL);
#pragma omp for schedule(static)
         for (int64_t ctr_0__1 = 0LL; ctr_0__1 < ctr_0__rem_start; ctr_0__1 += 4LL)
         {
            const int64_t ctr_0 = ctr_0__1;
            w_local__1 = __riscv_vfadd_vv_f64m1(
                w_local__1, __riscv_vle64_v_f64m1(&_data_x[ctr_0], 4uLL), 4uLL);
         }
         w_local =
             pystencils::runtime::rvv::horizontal_add_f64m1(w_local, w_local__1);
      }
   }
   for (int64_t ctr_0__0 = ctr_0__rem_start; ctr_0__0 < _size_x_0; ctr_0__0 += 1LL)
   {
      w_local = w_local + _data_x[ctr_0__0];
   }
   w[0LL] = w[0LL] + w_local;
}
