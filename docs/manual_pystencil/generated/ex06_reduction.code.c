void kernel(const double* RESTRICT const _data_x, const int64_t _size_x_0,
            const int64_t _stride_x_0, double* const peak, double* const total)
{
   double total_local = 0.0;
   double peak_local = -std::numeric_limits<double>::infinity();
#pragma omp parallel reduction(+ : total_local) reduction(max : peak_local)
   {
#pragma omp for schedule(static)
      for (int64_t ctr_0 = 0LL; ctr_0 < _size_x_0; ctr_0 += 1LL)
      {
         total_local = total_local + _data_x[ctr_0 * _stride_x_0];
         peak_local = fmax(peak_local, _data_x[ctr_0 * _stride_x_0]);
      }
   }
   total[0LL] = total[0LL] + total_local;
   peak[0LL] = fmax(peak[0LL], peak_local);
}
