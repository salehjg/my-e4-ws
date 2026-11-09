void kernel(double* RESTRICT const _data_h)
{
   for (int64_t ctr_0 = 0LL; ctr_0 < 16LL; ctr_0 += 2LL)
   {
      for (int64_t ctr_1 = 3LL; ctr_1 < 29LL; ctr_1 += 1LL)
      {
         _data_h[ctr_0 * 32LL + ctr_1] = 1.0;
      }
   }
}
