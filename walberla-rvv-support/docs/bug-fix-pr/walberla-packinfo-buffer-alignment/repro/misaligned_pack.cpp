// Minimal reproduction of the misaligned buffer access in waLBerla's generated pack infos, without waLBerla.
//
// waLBerla's UniformBufferedScheme writes a header of 6 bytes (block ID length, block ID, direction) before each
// block's data, then the generated packing kernel writes the PDFs through a float pointer at that position:
//     float * buffer = reinterpret_cast<float*>(outBuffer);      // LbmStorageSpecification.tmpl.cpp
// This program does the same: a byte buffer, a header of <offset> bytes, then the loop of an edge direction
// (3 PDFs per cell, interleaved), as the generated kernel has it.
//
//   x86, any compiler:   g++ -O2 -fsanitize=alignment misaligned_pack.cpp && ./a.out 6
//                        -> "runtime error: store to misaligned address ... for type 'float'"
//   RISC-V with RVV:     g++ -O3 -march=rv64gcv misaligned_pack.cpp && ./a.out 6
//                        -> GCC vectorizes the loop to vsseg3e32.v; on cores that trap on element-misaligned
//                           vector accesses (e.g. SpacemiT X60), the program dies with SIGBUS
//                           (offsets 0 and 4 work, 2 and 6 fail). With -march=rv64gc the loop stays scalar
//                           and every offset works.
#include <cstdio>
#include <cstdlib>
#include <cstring>

__attribute__((noinline)) void pack3(float *__restrict buf, const float *__restrict a, const float *__restrict b,
                                     const float *__restrict c, long n)
{
   for (long i = 0; i < n; ++i)
   {
      buf[3 * i]     = a[i];
      buf[3 * i + 1] = b[i];
      buf[3 * i + 2] = c[i];
   }
}

int main(int argc, char **argv)
{
   const long offset = argc > 1 ? std::atol(argv[1]) : 6;   // 6: the header length in waLBerla's buffers
   alignas(64) static unsigned char raw[4096];               // like a SendBuffer: allocated with new[], aligned
   static float a[64], b[64], c[64];
   for (int i = 0; i < 64; ++i) { a[i] = float(i); b[i] = float(100 + i); c[i] = float(200 + i); }

   pack3(reinterpret_cast<float *>(raw + offset), a, b, c, 64);

   float last;
   std::memcpy(&last, raw + offset + (3 * 63 + 2) * sizeof(float), sizeof(float));
   std::printf("offset %ld: ok, last value %g\n", offset, last);
   return 0;
}
