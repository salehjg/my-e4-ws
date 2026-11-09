void kernel(double* RESTRICT const _data_dom,
            const uint8_t* RESTRICT const _data_idx, const int64_t _stride_dom_0,
            const int64_t _stride_dom_1)
{
   for (int64_t sparse_idx = 0LL; sparse_idx < 3LL; sparse_idx += 1LL)
   {
      const int64_t ctr_0 = ((int64_t*)&_data_idx[sparse_idx * 24LL + 0LL])[0LL];
      const int64_t ctr_1 = ((int64_t*)&_data_idx[sparse_idx * 24LL + 8LL])[0LL];
      _data_dom[ctr_0 * _stride_dom_0 + ctr_1 * _stride_dom_1] =
          ((double*)&_data_idx[sparse_idx * 24LL + 16LL])[0LL];
   }
}
