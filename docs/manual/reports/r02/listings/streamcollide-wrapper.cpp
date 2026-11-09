void StreamCollide::operator()(walberla::IBlock * block)
{
  // Fields from the properties struct, and their views on this block
  walberla::v8::memory::Field< double, 19, walberla::v8::memory::memtag::host > f { this->properties_.f_ };
  // ... same for rho and u ...
  walberla::v8::memory::BufferView< double, 4, walberla::v8::memory::memtag::host > f_view { f.bufferSystem().view(*block) };
  walberla::v8::memory::BufferView< double, 4, walberla::v8::memory::memtag::host > f_tmp_view { this->shadow_f_.view(f) };

  // Raw pointer, sizes and strides for the pystencils kernel
  const double * RESTRICT const _data_f { f_view.data() };
  const int64_t _size_f_0 { int64_t( f_view.shape()[0] ) };
  const int64_t _size_f_1 { int64_t( f_view.shape()[1] ) };
  const int64_t _size_f_2 { int64_t( f_view.shape()[2] ) };
  /* f_view.shape()[3] == 19 */
  /* f_view.strides()[0] == _stride_f_0 */          // assume_inner_stride_one: recorded, not checked
  const int64_t _stride_f_1 { int64_t( f_view.strides()[1] ) };
  const int64_t _stride_f_2 { int64_t( f_view.strides()[2] ) };
  const int64_t _stride_f_3 { int64_t( f_view.strides()[3] ) };
  double * RESTRICT const _data_f_tmp { f_tmp_view.data() };
  // ... strides of f_tmp, rho and u ...
  const double omega { this->properties_.omega_ };

  SweepgenLbmCPU::gen::LBM::StreamCollide_kernels::StreamCollide(
      _data_f, _data_f_tmp, _data_rho, _data_u, _size_f_0, _size_f_1, _size_f_2,
      _stride_f_1, _stride_f_2, _stride_f_3, /* ... */ omega);

  this->shadow_f_.swapBuffers(f, *block);           // f <-> f_tmp
}
