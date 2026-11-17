void kernel(double* RESTRICT const _data_dst,
            const double* RESTRICT const _data_src, const int64_t _size_dst_0,
            const int64_t _size_dst_1, const int64_t _stride_dst_0,
            const int64_t _stride_dst_1, const int64_t _stride_dst_2,
            const int64_t _stride_src_0, const int64_t _stride_src_1,
            const int64_t _stride_src_2, const double omega)
{
   const double __c_1_0o9_0 = 1.0 / 9.0;
   const double __c_1_0o36_0 = 1.0 / 36.0;
   const double __c_3_0o2_0 = 3.0 / 2.0;
   const double __c_4_0o9_0 = 4.0 / 9.0;
   const double __c_9_0o2_0 = 9.0 / 2.0;
   for (int64_t ctr_1 = 1LL; ctr_1 < _size_dst_1 - 1LL; ctr_1 += 1LL)
   {
      for (int64_t ctr_0 = 1LL; ctr_0 < _size_dst_0 - 1LL; ctr_0 += 1LL)
      {
         const double xi_0 =
             _data_src[(ctr_0 + 1LL) * _stride_src_0 + ctr_1 * _stride_src_1 +
                       3LL * _stride_src_2] +
             _data_src[(ctr_0 + 1LL) * _stride_src_0 +
                       (ctr_1 + -1LL) * _stride_src_1 + 6LL * _stride_src_2];
         const double xi_1 =
             _data_src[(ctr_0 + -1LL) * _stride_src_0 +
                       (ctr_1 + 1LL) * _stride_src_1 + 8LL * _stride_src_2] +
             _data_src[ctr_0 * _stride_src_0 + (ctr_1 + 1LL) * _stride_src_1 +
                       4LL * _stride_src_2];
         const double xi_3 =
             -1.0 *
                 _data_src[(ctr_0 + -1LL) * _stride_src_0 +
                           (ctr_1 + -1LL) * _stride_src_1 + 5LL * _stride_src_2] +
             _data_src[(ctr_0 + 1LL) * _stride_src_0 +
                       (ctr_1 + 1LL) * _stride_src_1 + 7LL * _stride_src_2];
         const double rho =
             xi_0 + xi_1 +
             _data_src[ctr_0 * _stride_src_0 + ctr_1 * _stride_src_1] +
             _data_src[(ctr_0 + 1LL) * _stride_src_0 +
                       (ctr_1 + 1LL) * _stride_src_1 + 7LL * _stride_src_2] +
             _data_src[(ctr_0 + -1LL) * _stride_src_0 +
                       (ctr_1 + -1LL) * _stride_src_1 + 5LL * _stride_src_2] +
             _data_src[ctr_0 * _stride_src_0 + (ctr_1 + -1LL) * _stride_src_1 +
                       2LL * _stride_src_2] +
             _data_src[(ctr_0 + -1LL) * _stride_src_0 + ctr_1 * _stride_src_1 +
                       _stride_src_2];
         const double xi_2 = 1.0 / rho;
         const double xi_13 = __c_1_0o9_0 * rho;
         const double xi_18 = __c_1_0o36_0 * rho;
         const double u_x =
             xi_2 *
             (-1.0 * xi_0 - xi_3 +
              _data_src[(ctr_0 + -1LL) * _stride_src_0 +
                        (ctr_1 + 1LL) * _stride_src_1 + 8LL * _stride_src_2] +
              _data_src[(ctr_0 + -1LL) * _stride_src_0 + ctr_1 * _stride_src_1 +
                        _stride_src_2]);
         const double xi_6 = u_x * u_x;
         const double xi_7 = __c_3_0o2_0 * xi_6;
         const double xi_8 = -1.0 + xi_7;
         const double xi_10 = 3.0 * u_x;
         const double xi_16 = -1.0 * xi_10;
         const double u_y =
             xi_2 *
             (-1.0 * xi_1 - xi_3 +
              _data_src[(ctr_0 + 1LL) * _stride_src_0 +
                        (ctr_1 + -1LL) * _stride_src_1 + 6LL * _stride_src_2] +
              _data_src[ctr_0 * _stride_src_0 + (ctr_1 + -1LL) * _stride_src_1 +
                        2LL * _stride_src_2]);
         const double xi_4 = u_y * u_y;
         const double xi_5 = __c_3_0o2_0 * xi_4;
         const double xi_9 = xi_5 + xi_8;
         const double xi_11 = -1.0 * xi_5;
         const double xi_12 = 1.0 + xi_11 + 3.0 * xi_6;
         const double xi_14 = 3.0 * u_y;
         const double xi_15 = 1.0 + xi_14 - xi_7;
         const double xi_17 = u_x + u_y;
         const double xi_19 = u_x - u_y;
         const double xi_20 = xi_10 + xi_9;
         _data_dst[ctr_0 * _stride_dst_0 + ctr_1 * _stride_dst_1] =
             -1.0 * omega *
                 (__c_4_0o9_0 * rho * xi_9 +
                  _data_src[ctr_0 * _stride_src_0 + ctr_1 * _stride_src_1]) +
             _data_src[ctr_0 * _stride_src_0 + ctr_1 * _stride_src_1];
         _data_dst[ctr_0 * _stride_dst_0 + ctr_1 * _stride_dst_1 + _stride_dst_2] =
             -1.0 * omega *
                 (-1.0 * xi_13 * (xi_10 + xi_12) +
                  _data_src[(ctr_0 + -1LL) * _stride_src_0 + ctr_1 * _stride_src_1 +
                            _stride_src_2]) +
             _data_src[(ctr_0 + -1LL) * _stride_src_0 + ctr_1 * _stride_src_1 +
                       _stride_src_2];
         _data_dst[ctr_0 * _stride_dst_0 + ctr_1 * _stride_dst_1 +
                   2LL * _stride_dst_2] =
             -1.0 * omega *
                 (-1.0 * xi_13 * (xi_15 + 3.0 * xi_4) +
                  _data_src[ctr_0 * _stride_src_0 + (ctr_1 + -1LL) * _stride_src_1 +
                            2LL * _stride_src_2]) +
             _data_src[ctr_0 * _stride_src_0 + (ctr_1 + -1LL) * _stride_src_1 +
                       2LL * _stride_src_2];
         _data_dst[ctr_0 * _stride_dst_0 + ctr_1 * _stride_dst_1 +
                   3LL * _stride_dst_2] =
             -1.0 * omega *
                 (-1.0 * xi_13 * (xi_12 + xi_16) +
                  _data_src[(ctr_0 + 1LL) * _stride_src_0 + ctr_1 * _stride_src_1 +
                            3LL * _stride_src_2]) +
             _data_src[(ctr_0 + 1LL) * _stride_src_0 + ctr_1 * _stride_src_1 +
                       3LL * _stride_src_2];
         _data_dst[ctr_0 * _stride_dst_0 + ctr_1 * _stride_dst_1 +
                   4LL * _stride_dst_2] =
             -1.0 * omega *
                 (-1.0 * xi_13 * (-1.0 * xi_14 - xi_8 + 3.0 * xi_4) +
                  _data_src[ctr_0 * _stride_src_0 + (ctr_1 + 1LL) * _stride_src_1 +
                            4LL * _stride_src_2]) +
             _data_src[ctr_0 * _stride_src_0 + (ctr_1 + 1LL) * _stride_src_1 +
                       4LL * _stride_src_2];
         _data_dst[ctr_0 * _stride_dst_0 + ctr_1 * _stride_dst_1 +
                   5LL * _stride_dst_2] =
             -1.0 * omega *
                 (-1.0 * xi_18 *
                      (xi_10 + xi_11 + xi_15 + __c_9_0o2_0 * (xi_17 * xi_17)) +
                  _data_src[(ctr_0 + -1LL) * _stride_src_0 +
                            (ctr_1 + -1LL) * _stride_src_1 + 5LL * _stride_src_2]) +
             _data_src[(ctr_0 + -1LL) * _stride_src_0 +
                       (ctr_1 + -1LL) * _stride_src_1 + 5LL * _stride_src_2];
         _data_dst[ctr_0 * _stride_dst_0 + ctr_1 * _stride_dst_1 +
                   6LL * _stride_dst_2] =
             -1.0 * omega *
                 (-1.0 * xi_18 * (xi_14 - xi_20 + __c_9_0o2_0 * (xi_19 * xi_19)) +
                  _data_src[(ctr_0 + 1LL) * _stride_src_0 +
                            (ctr_1 + -1LL) * _stride_src_1 + 6LL * _stride_src_2]) +
             _data_src[(ctr_0 + 1LL) * _stride_src_0 +
                       (ctr_1 + -1LL) * _stride_src_1 + 6LL * _stride_src_2];
         _data_dst[ctr_0 * _stride_dst_0 + ctr_1 * _stride_dst_1 +
                   7LL * _stride_dst_2] =
             -1.0 * omega *
                 (-1.0 * xi_18 *
                      (-1.0 * xi_14 - xi_20 + __c_9_0o2_0 * (xi_17 * xi_17)) +
                  _data_src[(ctr_0 + 1LL) * _stride_src_0 +
                            (ctr_1 + 1LL) * _stride_src_1 + 7LL * _stride_src_2]) +
             _data_src[(ctr_0 + 1LL) * _stride_src_0 +
                       (ctr_1 + 1LL) * _stride_src_1 + 7LL * _stride_src_2];
         _data_dst[ctr_0 * _stride_dst_0 + ctr_1 * _stride_dst_1 +
                   8LL * _stride_dst_2] =
             -1.0 * omega *
                 (-1.0 * xi_18 *
                      (-1.0 * xi_14 - xi_16 - xi_9 +
                       __c_9_0o2_0 * (xi_19 * xi_19)) +
                  _data_src[(ctr_0 + -1LL) * _stride_src_0 +
                            (ctr_1 + 1LL) * _stride_src_1 + 8LL * _stride_src_2]) +
             _data_src[(ctr_0 + -1LL) * _stride_src_0 +
                       (ctr_1 + 1LL) * _stride_src_1 + 8LL * _stride_src_2];
      }
   }
}
