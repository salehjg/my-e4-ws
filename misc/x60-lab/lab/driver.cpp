// D3Q19 kernel lab driver (misc/x60-lab, Phase 3 of docs/notes3).
//
// Runs one generated StreamCollide kernel (gen.py) on fields laid out exactly like waLBerla's
// v8 fields on RISC-V: fzyx, 1 ghost layer, x extent padded to a multiple of 16 bytes
// (hostAlignment() = __BIGGEST_ALIGNMENT__ = 16), interior origin 16-byte aligned, and the
// block base where glibc's mmap-backed malloc puts it (page + 16). Pull scheme with f/f_tmp
// swap and a periodic ghost fill after every step (not timed), like the waLBerla app minus MPI.
//
// Usage: ./lab N STEPS [WARMUP]
// Env:   THP=1      madvise(MADV_HUGEPAGE) on the fields (before first touch)
//        PADF=<n>   extra elements between PDF components (default 0 = waLBerla)
//        XPAD=<n>   x allocation padded to a multiple of n elements (default 16 B / sizeof(T))
//        ALIGN=<b>  alignment of the interior origin in bytes (default 16)
//        AA=1       in-place AA pattern (hand/f32-hand-aa.cpp, `run_kernel_aa`): one PDF field,
//                   initialised with the pull-streamed initial state so that the rho/u outputs
//                   (energy, mass) of every step equal the pull kernels'; periodic ghost fill
//                   before odd steps, ghost-to-interior fold after odd steps (both untimed)
// Prints: one tab-separated key=value line (MLUP/s of the kernel alone, cycles/insns per cell
//         from perf_event_open around the kernel calls, checksums).
#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <sys/mman.h>
#include <vector>
#include "../probes/pmu.hpp"

#ifndef T
#define T float
#endif

extern "C" void run_kernel(T* f, T* ftmp, T* rho, T* u, int64_t n0, int64_t n1, int64_t n2, int64_t sf1, int64_t sf2,
                           int64_t sf3, int64_t sr1, int64_t sr2, int64_t su1, int64_t su2, int64_t su3, int64_t s0,
                           T omega) __attribute__((weak));
extern "C" void run_kernel_aa(T* f, T* rho, T* u, int64_t n0, int64_t n1, int64_t n2, int64_t sf1, int64_t sf2,
                              int64_t sf3, int64_t sr1, int64_t sr2, int64_t su1, int64_t su2, int64_t su3, int parity,
                              T omega) __attribute__((weak));

static long env(const char* k, long d) { const char* v = std::getenv(k); return v ? std::atol(v) : d; }

//  lbmpy / waLBerla D3Q19 ordering: C N S W E T B NW NE SW SE TN TS TW TE BN BS BW BE
static const int C[19][3] = {{0, 0, 0},   {0, 1, 0},  {0, -1, 0}, {-1, 0, 0}, {1, 0, 0},  {0, 0, 1},  {0, 0, -1},
                             {-1, 1, 0},  {1, 1, 0},  {-1, -1, 0}, {1, -1, 0}, {0, 1, 1},  {0, -1, 1}, {-1, 0, 1},
                             {1, 0, 1},   {0, 1, -1}, {0, -1, -1}, {-1, 0, -1}, {1, 0, -1}};

struct Field {   // fzyx, 1 ghost layer
   int64_t n, xa, ya, za, sz, comps, sc;   // sz = z stride, sc = component stride
   T* base = nullptr;                       // element (0,0,0) of the allocation (ghost corner)
   T* interior = nullptr;                   // element (1,1,1)
   size_t bytes = 0;
   Field(int64_t n_, int64_t comps_, long xpad, long padf, long align, bool thp) : n(n_), comps(comps_) {
      xa = (n + 2 + xpad - 1) / xpad * xpad;
      ya = n + 2;
      za = n + 2;
      sz = xa * ya;
      sc = sz * za + padf;
      const size_t elems = (size_t) sc * comps + 64;
      bytes = elems * sizeof(T) + 2 * align + 4096;
      void* raw = mmap(nullptr, bytes + (2u << 20), PROT_READ | PROT_WRITE, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0);
      if (raw == MAP_FAILED) { std::perror("mmap"); std::exit(1); }
      char* page = (char*) (((uintptr_t) raw + (2u << 20) - 1) & ~(uintptr_t) ((2u << 20) - 1));
      if (thp) madvise(page, bytes, MADV_HUGEPAGE);
      char* blk = page + 16;                                    // glibc mmap chunk: page + 16
      const size_t off = (size_t) (1 + xa + sz) * sizeof(T);    // interior origin offset
      char* inner = (char*) (((uintptr_t) blk + off + align - 1) & ~(uintptr_t) (align - 1));
      interior = (T*) inner;
      base = interior - (1 + xa + sz);
   }
   T& at(int64_t x, int64_t y, int64_t z, int64_t c) { return base[x + y * xa + z * sz + c * sc]; }   // x,y,z incl. ghosts
   //  AA, after an odd step: a value written into a ghost cell g (slot i, coming from the
   //  interior cell g - c_i) belongs to the periodic image of g
   void aa_fold(const int (*c)[3]) {
      auto wrap = [&](int64_t v) { return v == 0 ? n : (v == n + 1 ? 1 : v); };
      auto inside = [&](int64_t v) { return v >= 1 && v <= n; };
      for (int64_t z = 0; z <= n + 1; ++z)
         for (int64_t y = 0; y <= n + 1; ++y)
            for (int64_t x = 0; x <= n + 1; ++x) {
               if (inside(x) && inside(y) && inside(z)) continue;
               for (int i = 1; i < comps; ++i)
                  if (inside(x - c[i][0]) && inside(y - c[i][1]) && inside(z - c[i][2]))
                     at(wrap(x), wrap(y), wrap(z), i) = at(x, y, z, i);
            }
   }
   void periodic_fill() {
      for (int64_t c = 0; c < comps; ++c) {
         for (int64_t z = 1; z <= n; ++z)
            for (int64_t y = 1; y <= n; ++y) { at(0, y, z, c) = at(n, y, z, c); at(n + 1, y, z, c) = at(1, y, z, c); }
         for (int64_t z = 1; z <= n; ++z) {
            std::memcpy(&at(0, 0, z, c), &at(0, n, z, c), xa * sizeof(T));
            std::memcpy(&at(0, n + 1, z, c), &at(0, 1, z, c), xa * sizeof(T));
         }
         std::memcpy(&at(0, 0, 0, c), &at(0, 0, n, c), sz * sizeof(T));
         std::memcpy(&at(0, 0, n + 1, c), &at(0, 0, 1, c), sz * sizeof(T));
      }
   }
};

static double now() { return std::chrono::duration<double>(std::chrono::steady_clock::now().time_since_epoch()).count(); }

int main(int argc, char** argv) {
   const int64_t N = argc > 1 ? std::atol(argv[1]) : 64;
   const int steps = argc > 2 ? std::atoi(argv[2]) : 20;
   const int warmup = argc > 3 ? std::atoi(argv[3]) : 2;
   const bool thp = env("THP", 0);
   const long xpad = env("XPAD", std::max<long>(1, 16 / (long) sizeof(T)));
   const long padf = env("PADF", 0), align = env("ALIGN", 16);

   Field f(N, 19, xpad, padf, align, thp), g(N, 19, xpad, padf, align, thp);
   Field rho(N, 1, xpad, 0, align, thp), u(N, 3, xpad, padf, align, thp);

   //  DoubleShearLayer-like physics: omega from Re = 30000, u0 = 0.04, as in the app
   const double u0 = 0.04, nu = u0 * N / 30000.0, tau = nu / (1.0 / 3.0);
   const T omega = T(2.0 / (2.0 * tau + 1.0));
   static const double w[19] = {1. / 3,  1. / 18, 1. / 18, 1. / 18, 1. / 18, 1. / 18, 1. / 18, 1. / 36, 1. / 36, 1. / 36,
                                1. / 36, 1. / 36, 1. / 36, 1. / 36, 1. / 36, 1. / 36, 1. / 36, 1. / 36, 1. / 36};
   //  zero-centered equilibrium (lbmpy's storage: f_i - w_i) of a smooth shear-layer flow
   for (int64_t z = 1; z <= N; ++z)
      for (int64_t y = 1; y <= N; ++y)
         for (int64_t x = 1; x <= N; ++x) {
            const double yy = (y - 0.5) / N, xx = (x - 0.5) / N, zz = (z - 0.5) / N;
            const double ux = u0 * std::tanh(80 * (yy <= 0.5 ? yy - 0.25 : 0.75 - yy));
            const double uy = 0.05 * u0 * std::sin(2 * M_PI * (xx + 0.25)), uz = 0.01 * u0 * std::sin(2 * M_PI * zz);
            const double r = 1.0, usq = ux * ux + uy * uy + uz * uz;
            for (int i = 0; i < 19; ++i) {
               const double cu = C[i][0] * ux + C[i][1] * uy + C[i][2] * uz;
               f.at(x, y, z, i) = T(w[i] * (r - 1.0) + w[i] * r * (3 * cu + 4.5 * cu * cu - 1.5 * usq));
            }
         }
   f.periodic_fill();
   std::memset(g.base, 0, g.sc * 19 * sizeof(T));
   const bool aa = env("AA", 0);
   if (aa) {   // f(x, i) <- f_init(x - c_i, i): the state the pull kernel gathers in its first step
      if (!run_kernel_aa) { std::fprintf(stderr, "AA=1 needs a kernel providing run_kernel_aa\n"); return 1; }
      std::memcpy(g.base, f.base, g.sc * 19 * sizeof(T));
      for (int64_t z = 1; z <= N; ++z)
         for (int64_t y = 1; y <= N; ++y)
            for (int64_t x = 1; x <= N; ++x)
               for (int i = 0; i < 19; ++i) f.at(x, y, z, i) = g.at(x - C[i][0], y - C[i][1], z - C[i][2], i);
   } else if (!run_kernel) {
      std::fprintf(stderr, "kernel provides no run_kernel (AA kernel? set AA=1)\n");
      return 1;
   }

   long aa_t = 0;   // AA step counter (parity)
   auto step = [&](Field& src, Field& dst) {
      if (aa)
         run_kernel_aa(f.interior, rho.interior, u.interior, N, N, N, f.xa, f.sz, f.sc, rho.xa, rho.sz, u.xa, u.sz, u.sc,
                       int(aa_t & 1), omega);
      else
         run_kernel(src.interior, dst.interior, rho.interior, u.interior, N, N, N, src.xa, src.sz, src.sc, rho.xa,
                    rho.sz, u.xa, u.sz, u.sc, 1, omega);
   };
   //  untimed work between steps: pull swaps fields and refills the ghosts; AA folds the
   //  ghosts back after odd steps and refills them before odd steps
   Field* a = &f;
   Field* b = &g;
   auto between = [&]() {
      if (aa) {
         if (aa_t & 1) f.aa_fold(C);
         ++aa_t;
         if (aa_t & 1) f.periodic_fill();
      } else {
         std::swap(a, b);
         a->periodic_fill();
      }
   };
   if (aa && (warmup % 2 || steps % 2)) { std::fprintf(stderr, "AA needs even STEPS and WARMUP\n"); return 1; }
   for (int s = 0; s < warmup; ++s) { step(*a, *b); between(); }

   Pmu pmu;
   std::vector<double> secs;
   uint64_t cyc = 0, ins = 0;
   for (int s = 0; s < steps; ++s) {
      const double t0 = now();
      pmu.start();
      step(*a, *b);
      pmu.stop();
      secs.push_back(now() - t0);
      cyc += pmu.cycles();
      ins += pmu.insns();
      between();
   }
   std::sort(secs.begin(), secs.end());
   const double cells = double(N) * N * N;
   double e = 0, mass = 0, wsum = 0;
   for (int64_t z = 1; z <= N; ++z)
      for (int64_t y = 1; y <= N; ++y)
         for (int64_t x = 1; x <= N; ++x) {
            const double ux = u.at(x, y, z, 0), uy = u.at(x, y, z, 1), uz = u.at(x, y, z, 2);
            e += ux * ux + uy * uy + uz * uz;
            mass += rho.at(x, y, z, 0);
            for (int i = 0; i < 19; ++i) wsum += (i + 1) * double(a->at(x, y, z, i));
         }
   std::printf("best_mlups=%.3f\tmedian_mlups=%.3f\tcycles_per_cell=%.1f\tinsns_per_cell=%.1f\tipc=%.3f\t"
               "energy=%.12e\tmass=%.12e\twsum=%.12e\n",
               cells / secs[0] / 1e6, cells / secs[secs.size() / 2] / 1e6, cyc / (cells * steps),
               ins / (cells * steps), cyc ? double(ins) / cyc : 0.0, e, mass, wsum);
   return 0;
}
