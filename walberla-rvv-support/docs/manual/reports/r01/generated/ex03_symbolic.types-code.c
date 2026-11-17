void kernel(int64_t* RESTRICT const _data_i, float* RESTRICT const _data_x,
            const int64_t _size_i_0, const int64_t _stride_i_0,
            const int64_t _stride_x_0, const float scale)
{
   for (int64_t ctr_0 = 0LL; ctr_0 < _size_i_0; ctr_0 += 1LL)
   {
      _data_x[ctr_0 * _stride_x_0] = _data_x[ctr_0 * _stride_x_0] * scale;
      _data_i[ctr_0 * _stride_i_0] = (int64_t)_data_x[ctr_0 * _stride_x_0];
   }
}
