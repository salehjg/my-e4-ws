// Direction-split D3Q19 SRT pull kernel (lever M2 of docs/notes3): same update as waLBerla's
// generated StreamCollide (compressible, zero-centered PDFs, outputs rho and u), but organised
// so that only a few DRAM streams are live at any time:
//
//   for each block of BY rows (all x) of one z-plane:
//     1. moments  : for each group of GM directions: acc[δρ, jx, jy, jz] += pulled f_i     (GM read streams)
//     2. macro    : ρ = 1 + δρ, u = j/ρ, u²; write rho, u (4 short write streams); keep the
//                   per-cell terms in an L1 scratch
//     3. collide  : for each group of GC directions: f_tmp_i = f_i + ω (f_eq_i − f_i)        (GC write streams;
//                   the pulled f_i come back from L1/L2, they were loaded in step 1)
//
// The X60 prefetcher follows ~8 concurrent streams well and gives up past ~20 (docs/notes3,
// Loop 2), while the fused kernel keeps 19 read + 23 write streams live.
//
// Compile-time knobs: BY (rows per block, default 4), GM / GC (directions per group, default 5),
// PF (software prefetch distance in floats along each stream, 0 = off; prefetch.r on the
// moment loads, prefetch.w on all stores).
// Requires n0 % 8 == 0 (VLEN = 256, f32 m1).
#include <riscv_vector.h>
#include <cstdint>
#include <utility>

#ifndef BY
#define BY 4
#endif
#ifndef GM
#define GM 5
#endif
#ifndef GC
#define GC 5
#endif
#ifndef PF
#define PF 0
#endif

namespace {
constexpr int Q = 19;
constexpr int CX[Q] = {0, 0, 0, -1, 1, 0, 0, -1, 1, -1, 1, 0, 0, -1, 1, 0, 0, -1, 1};
constexpr int CY[Q] = {0, 1, -1, 0, 0, 0, 0, 1, 1, -1, -1, 1, -1, 0, 0, 1, -1, 0, 0};
constexpr int CZ[Q] = {0, 0, 0, 0, 0, 1, -1, 0, 0, 0, 0, 1, 1, 1, 1, -1, -1, -1, -1};
constexpr float W[Q] = {1.f / 3,  1.f / 18, 1.f / 18, 1.f / 18, 1.f / 18, 1.f / 18, 1.f / 18, 1.f / 36, 1.f / 36, 1.f / 36,
                        1.f / 36, 1.f / 36, 1.f / 36, 1.f / 36, 1.f / 36, 1.f / 36, 1.f / 36, 1.f / 36, 1.f / 36};
constexpr size_t VL = 8;
constexpr int MAXCELLS = BY * 256;
using V = vfloat32m1_t;

inline V ld(const float* p) { return __riscv_vle32_v_f32m1(p, VL); }
inline void st(float* p, V v) { __riscv_vse32_v_f32m1(p, v, VL); }
inline void pfr(const void* p) { __builtin_prefetch(p, 0, 3); }
inline void pfw(const void* p) { __builtin_prefetch(p, 1, 3); }

template <int c>
inline V addc(V acc, V v) {   // acc + c * v for c in {-1, 0, 1}
   if constexpr (c == 1) return __riscv_vfadd_vv_f32m1(acc, v, VL);
   else if constexpr (c == -1) return __riscv_vfsub_vv_f32m1(acc, v, VL);
   else return acc;
}

struct Ctx {
   const float* f;
   float* ft;
   int64_t sf1, sf2, sf3;
   int64_t z, y0, n0;
};

//  pulled f_i at block cell (yy, x): f_i[x - c_i]
template <int I>
inline const float* src(const Ctx& c, int64_t yy, int64_t x) {
   return c.f + (x - CX[I]) + (c.y0 + yy - CY[I]) * c.sf1 + (c.z - CZ[I]) * c.sf2 + I * c.sf3;
}

template <int... Is>
inline void moments_group(const Ctx& c, float* acc0, float* acc1, float* acc2, float* acc3, bool first,
                          std::integer_sequence<int, Is...>) {
   for (int64_t yy = 0; yy < BY; ++yy)
      for (int64_t x = 0; x < c.n0; x += VL) {
         const int64_t k = yy * c.n0 + x;
         V r, jx, jy, jz;
         if (first) {
            r = jx = jy = jz = __riscv_vfmv_v_f_f32m1(0.f, VL);
         } else {
            r = ld(acc0 + k); jx = ld(acc1 + k); jy = ld(acc2 + k); jz = ld(acc3 + k);
         }
         if constexpr (PF > 0) { (pfr(src<Is>(c, yy, x) + PF), ...); }
         //  one basic block after inlining: the scheduler can hoist the loads above the adds
         (
            [&] {
               const V v = ld(src<Is>(c, yy, x));
               r = __riscv_vfadd_vv_f32m1(r, v, VL);
               jx = addc<CX[Is]>(jx, v);
               jy = addc<CY[Is]>(jy, v);
               jz = addc<CZ[Is]>(jz, v);
            }(),
            ...);
         st(acc0 + k, r); st(acc1 + k, jx); st(acc2 + k, jy); st(acc3 + k, jz);
      }
}

template <int I>
inline V cu_of(V ux, V uy, V uz) {   // c_i . u without a zero splat (vfmv.v.f costs 4 cycles on the X60)
   constexpr int cx = CX[I], cy = CY[I], cz = CZ[I];
   V a;
   if constexpr (cx != 0) {
      a = cx > 0 ? ux : __riscv_vfneg_v_f32m1(ux, VL);
      a = addc<cy>(a, uy);
      return addc<cz>(a, uz);
   } else if constexpr (cy != 0) {
      a = cy > 0 ? uy : __riscv_vfneg_v_f32m1(uy, VL);
      return addc<cz>(a, uz);
   } else {
      return cz > 0 ? uz : __riscv_vfneg_v_f32m1(uz, VL);
   }
}

template <int... Is>
inline void collide_group(const Ctx& c, const float* sdr, const float* srho, const float* sux, const float* suy,
                          const float* suz, const float* susq, float omega, std::integer_sequence<int, Is...>) {
   for (int64_t yy = 0; yy < BY; ++yy)
      for (int64_t x = 0; x < c.n0; x += VL) {
         const int64_t k = yy * c.n0 + x;
         const V dr = ld(sdr + k), rho = ld(srho + k), ux = ld(sux + k), uy = ld(suy + k), uz = ld(suz + k);
         const V base = ld(susq + k);   // -1.5 u^2
         (
            [&] {
               constexpr int I = Is;
               float* dst = c.ft + x + (c.y0 + yy) * c.sf1 + c.z * c.sf2 + I * c.sf3;
               if constexpr (PF > 0) pfw(dst + PF);
               const V v = ld(src<I>(c, yy, x));
               V t;
               if constexpr (I == 0) {
                  t = base;
               } else {
                  const V cu = cu_of<I>(ux, uy, uz);
                  //  3cu + 4.5cu^2 - 1.5u^2 = cu * (3 + 4.5cu) + base
                  t = __riscv_vfmacc_vv_f32m1(base, cu, __riscv_vfadd_vf_f32m1(__riscv_vfmul_vf_f32m1(cu, 4.5f, VL), 3.f, VL), VL);
               }
               //  feq = w (dr + rho t);   out = v + omega (feq - v)
               const V feq = __riscv_vfmul_vf_f32m1(__riscv_vfmacc_vv_f32m1(dr, rho, t, VL), W[I], VL);
               st(dst, __riscv_vfmacc_vf_f32m1(v, omega, __riscv_vfsub_vv_f32m1(feq, v, VL), VL));
            }(),
            ...);
      }
}

template <int Start, int Len>
using Seq = decltype([]<int... Is>(std::integer_sequence<int, Is...>) {
   return std::integer_sequence<int, (Start + Is)...>{};
}(std::make_integer_sequence<int, Len>{}));

template <int G, int Start = 0, class F>
inline void for_groups(F&& fn) {
   if constexpr (Start < Q) {
      constexpr int Len = (Start + G <= Q) ? G : Q - Start;
      fn(Seq<Start, Len>{}, Start == 0);
      for_groups<G, Start + Len>(fn);
   }
}
}   // namespace

extern "C" void run_kernel(float* f, float* ftmp, float* rho, float* u, int64_t n0, int64_t n1, int64_t n2, int64_t sf1,
                           int64_t sf2, int64_t sf3, int64_t sr1, int64_t sr2, int64_t su1, int64_t su2, int64_t su3,
                           int64_t, float omega) {
   alignas(64) static float acc[4][MAXCELLS];
   alignas(64) static float sc[6][MAXCELLS];
   Ctx c{f, ftmp, sf1, sf2, sf3, 0, 0, n0};
   for (int64_t z = 0; z < n2; ++z)
      for (int64_t y0 = 0; y0 + BY <= n1; y0 += BY) {   // n1 % BY == 0 assumed
         c.z = z;
         c.y0 = y0;
         for_groups<GM>([&](auto seq, bool first) { moments_group(c, acc[0], acc[1], acc[2], acc[3], first, seq); });
         for (int64_t yy = 0; yy < BY; ++yy)
            for (int64_t x = 0; x < n0; x += VL) {
               const int64_t k = yy * n0 + x;
               const V dr = ld(acc[0] + k);
               const V r = __riscv_vfadd_vf_f32m1(dr, 1.f, VL);
               const V inv = __riscv_vfrdiv_vf_f32m1(r, 1.f, VL);
               const V ux = __riscv_vfmul_vv_f32m1(ld(acc[1] + k), inv, VL);
               const V uy = __riscv_vfmul_vv_f32m1(ld(acc[2] + k), inv, VL);
               const V uz = __riscv_vfmul_vv_f32m1(ld(acc[3] + k), inv, VL);
               V usq = __riscv_vfmul_vv_f32m1(ux, ux, VL);
               usq = __riscv_vfmacc_vv_f32m1(usq, uy, uy, VL);
               usq = __riscv_vfmacc_vv_f32m1(usq, uz, uz, VL);
               st(sc[0] + k, dr); st(sc[1] + k, r); st(sc[2] + k, ux); st(sc[3] + k, uy); st(sc[4] + k, uz);
               st(sc[5] + k, __riscv_vfmul_vf_f32m1(usq, -1.5f, VL));
               const int64_t o = x + (y0 + yy) * sr1 + z * sr2, ou = x + (y0 + yy) * su1 + z * su2;
               if constexpr (PF > 0) { pfw(rho + o + PF); pfw(u + ou + PF); pfw(u + ou + su3 + PF); pfw(u + ou + 2 * su3 + PF); }
               st(rho + o, r);
               st(u + ou, ux); st(u + ou + su3, uy); st(u + ou + 2 * su3, uz);
            }
         for_groups<GC>([&](auto seq, bool) { collide_group(c, sc[0], sc[1], sc[2], sc[3], sc[4], sc[5], omega, seq); });
      }
}
