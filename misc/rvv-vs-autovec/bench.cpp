// Standalone driver for one generated LBM kernel (out-of-tree experiment, see README.md).
//
// The kernel object from gen.py provides `run_kernel`; this file sets up the same data
// layout as the Python harness (18 separate row-major arrays with a 1-cell ghost ring),
// calls the kernel REPS times and reports:
//   * wall time per call (best and median) -> MLUP/s
//   * cycles and retired instructions per cell, read from the hardware counters via
//     perf_event_open around the timed calls -> tells "more work" apart from "slower work"
//   * a checksum of g, so the variants can be checked against each other.
//
// Usage: ./bench NX NY REPS        Build: see run.sh (-DT=double or -DT=float)

#include <algorithm>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <vector>

#include <linux/perf_event.h>
#include <sys/ioctl.h>
#include <sys/syscall.h>
#include <unistd.h>

#ifndef T
#define T double
#endif

extern "C" void run_kernel(T * const * f, T * const * g, int64_t nx, int64_t ny, int64_t stride0, T omega);

//  One hardware counter; `group` = leader fd or -1. Returns -1 if counters are unavailable.
static int open_counter(uint64_t config, int group)
{
   perf_event_attr a;
   std::memset(&a, 0, sizeof(a));
   a.type = PERF_TYPE_HARDWARE;
   a.size = sizeof(a);
   a.config = config;
   a.disabled = (group == -1);
   a.exclude_kernel = 1;
   a.exclude_hv = 1;
   int fd = (int) syscall(SYS_perf_event_open, &a, 0, -1, group, 0);
   if (fd < 0) {   // some PMUs cannot filter by privilege level: count everything instead
      a.exclude_kernel = 0;
      a.exclude_hv = 0;
      fd = (int) syscall(SYS_perf_event_open, &a, 0, -1, group, 0);
   }
   return fd;
}

static uint64_t read_counter(int fd)
{
   uint64_t v = 0;
   if (fd < 0 || read(fd, &v, sizeof(v)) != (ssize_t) sizeof(v)) return 0;
   return v;
}

int main(int argc, char ** argv)
{
   const int64_t NX = argc > 1 ? std::atoll(argv[1]) : 200;
   const int64_t NY = argc > 2 ? std::atoll(argv[2]) : 200;
   const int REPS = argc > 3 ? std::atoi(argv[3]) : 50;
   const int64_t nx = NX + 2, ny = NY + 2;   // + ghost ring; kernels iterate over [1, n-1)
   const T omega = T(1.0 / 0.6);             // any stable relaxation rate; it does not affect timing

   //  D2Q9 equilibrium of a smooth Taylor-Green velocity field: realistic values everywhere
   //  (ghosts included), so there are no NaNs/denormals that could distort the timing.
   static const int cx[9] = {0, 1, 0, -1, 0, 1, -1, -1, 1};
   static const int cy[9] = {0, 0, 1, 0, -1, 1, 1, -1, -1};
   static const double w[9] = {4. / 9, 1. / 9, 1. / 9, 1. / 9, 1. / 9, 1. / 36, 1. / 36, 1. / 36, 1. / 36};
   std::vector<std::vector<T>> fs(9, std::vector<T>(nx * ny)), gs(9, std::vector<T>(nx * ny, T(0)));
   for (int64_t x = 0; x < nx; ++x)
      for (int64_t y = 0; y < ny; ++y) {
         const double kx = 2 * M_PI / NX, ky = 2 * M_PI / NY, u0 = 0.04;
         const double ux = -u0 * std::cos(kx * x) * std::sin(ky * y);
         const double uy = u0 * std::sin(kx * x) * std::cos(ky * y);
         for (int i = 0; i < 9; ++i) {
            const double cu = cx[i] * ux + cy[i] * uy;
            fs[i][x * ny + y] = T(w[i] * (1.0 + 3.0 * cu + 4.5 * cu * cu - 1.5 * (ux * ux + uy * uy)));
         }
      }
   T * f[9];
   T * g[9];
   for (int i = 0; i < 9; ++i) {
      f[i] = fs[i].data();
      g[i] = gs[i].data();
   }

   for (int r = 0; r < 3; ++r) run_kernel(f, g, nx, ny, ny, omega);   // warm-up (caches, pages)

   const int cyc = open_counter(PERF_COUNT_HW_CPU_CYCLES, -1);
   const int ins = cyc >= 0 ? open_counter(PERF_COUNT_HW_INSTRUCTIONS, cyc) : -1;
   if (cyc >= 0) {
      ioctl(cyc, PERF_EVENT_IOC_RESET, PERF_IOC_FLAG_GROUP);
      ioctl(cyc, PERF_EVENT_IOC_ENABLE, PERF_IOC_FLAG_GROUP);
   }
   std::vector<double> secs(REPS);
   for (int r = 0; r < REPS; ++r) {
      const auto t0 = std::chrono::steady_clock::now();
      run_kernel(f, g, nx, ny, ny, omega);
      secs[r] = std::chrono::duration<double>(std::chrono::steady_clock::now() - t0).count();
   }
   if (cyc >= 0) ioctl(cyc, PERF_EVENT_IOC_DISABLE, PERF_IOC_FLAG_GROUP);
   const double cells = double(NX) * double(NY);
   const double calls_cells = cells * REPS;
   const double cycles = read_counter(cyc) / calls_cells;
   const double insns = read_counter(ins) / calls_cells;

   std::sort(secs.begin(), secs.end());
   //  Weighted by direction: a plain sum of all populations is just the mass, which any
   //  collision conserves -- that would not catch a wrong kernel.
   double checksum = 0;
   for (int i = 0; i < 9; ++i)
      for (int64_t x = 1; x < nx - 1; ++x)
         for (int64_t y = 1; y < ny - 1; ++y) checksum += (i + 1) * double(gs[i][x * ny + y]);

   //  One tab-separated line; report.py collects and pivots them
   std::printf("best_mlups=%.3f\tmedian_mlups=%.3f\tcycles_per_cell=%.1f\tinsns_per_cell=%.1f\tipc=%.2f\tchecksum=%.12e\n",
               cells / secs[0] / 1e6, cells / secs[REPS / 2] / 1e6, cycles, insns,
               cycles > 0 ? insns / cycles : 0.0, checksum);
   return 0;
}
