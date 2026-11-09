void kernel(float* RESTRICT const _data_noise, const int64_t _size_noise_0,
            const int64_t _size_noise_1, const int64_t _stride_noise_0,
            const int64_t _stride_noise_1, const int64_t t)
{
   for (int64_t ctr_0 = 0LL; ctr_0 < _size_noise_0; ctr_0 += 1LL)
   {
      for (int64_t ctr_1 = 0LL; ctr_1 < _size_noise_1; ctr_1 += 1LL)
      {
         pystencils::runtime::ShortArray<float, 4> rng_0 =
             pystencils::runtime::random::philox_float32<int64_t>(
                 t, ctr_0, ctr_1, 0LL, 51966LL, 0LL);
         _data_noise[ctr_0 * _stride_noise_0 + ctr_1 * _stride_noise_1] =
             -0.5f + rng_0[0LL];
      }
   }
}
