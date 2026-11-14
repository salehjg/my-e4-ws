// In-place AA-pattern D3Q19 SRT kernel with direction-split passes (lever M4 of docs/notes3).
// Included by f32-hand-aa.cpp (REAL_F64 unset) and f64-hand-aa.cpp (REAL_F64=1).
//
// Same collision as waLBerla's generated StreamCollide (compressible, zero-centered PDFs,
// outputs rho and u), but with the AA streaming pattern (Bailey et al. 2009, lbmpy's 'aa'):
//   even step: read f_i(x),               write the post-collision value of i to slot inv(i) at x
//   odd step : read slot inv(i) at x-c_i, write the post-collision value of i to slot i at x+c_i
// Every memory location is read and written by exactly one cell per step, so a single PDF
// field suffices: no f_tmp, no write-allocate of a second array (≈184 instead of ≈260 B/cell
// in f32), and 19 + 4 streams instead of 19 + 23.
//
// Passes per block of BY rows, as in f32-hand-split.cpp: moments in groups of GM directions,
// macroscopic values, collide in groups of GP opposite-direction pairs (a pair must be loaded
// before either slot is overwritten, because each pair's write targets are its read sources).
//
// Knobs (-D): BY, GM, GP, LMUL (1, 2, 4: register group; VL = LMUL * 256 / element bits).
// Entry point: run_kernel_aa(f, rho, u, n0, n1, n2, sf1, sf2, sf3, sr1, sr2, su1, su2, su3, parity, omega)
// (the lab driver uses it when AA=1). Requires n0 % VL == 0, n1 % BY == 0.
// Arithmetic uses the overloaded RVV intrinsics, so one body serves every element type and LMUL.
#include <riscv_vector.h>
#include <cstdint>
#include <utility>

#ifndef BY
#define BY 2
#endif
#ifndef GM
#define GM 5
#endif
#ifndef GP
#define GP 2
#endif
#ifndef LMUL
#define LMUL 1
#endif

#if REAL_F64
#define EW 64
typedef double R;
#else
#define EW 32
typedef float R;
#endif
#define VT_(ew, l) vfloat##ew##m##l##_t
#define VT(ew, l) VT_(ew, l)
#define LD_(ew, l) __riscv_vle##ew##_v_f##ew##m##l
#define LD(ew, l) LD_(ew, l)
#define ST_(ew) __riscv_vse##ew
#define ST(ew) ST_(ew)
#define SPLAT_(ew, l) __riscv_vfmv_v_f_f##ew##m##l
#define SPLAT(ew, l) SPLAT_(ew, l)

namespace {
constexpr int Q = 19;
constexpr int CX[Q] = {0, 0, 0, -1, 1, 0, 0, -1, 1, -1, 1, 0, 0, -1, 1, 0, 0, -1, 1};
constexpr int CY[Q] = {0, 1, -1, 0, 0, 0, 0, 1, 1, -1, -1, 1, -1, 0, 0, 1, -1, 0, 0};
constexpr int CZ[Q] = {0, 0, 0, 0, 0, 1, -1, 0, 0, 0, 0, 1, 1, 1, 1, -1, -1, -1, -1};
constexpr int INV[Q] = {0, 2, 1, 4, 3, 6, 5, 10, 9, 8, 7, 16, 15, 18, 17, 12, 11, 14, 13};
constexpr int PAIRS[9] = {1, 3, 5, 7, 8, 11, 12, 13, 14};   // first member of each pair
constexpr R W[Q] = {R(1) / 3,  R(1) / 18, R(1) / 18, R(1) / 18, R(1) / 18, R(1) / 18, R(1) / 18,
                    R(1) / 36, R(1) / 36, R(1) / 36, R(1) / 36, R(1) / 36, R(1) / 36, R(1) / 36,
                    R(1) / 36, R(1) / 36, R(1) / 36, R(1) / 36, R(1) / 36};
constexpr size_t VL = LMUL * 256 / EW;
constexpr int MAXCELLS = BY * 256;
using V = VT(EW, LMUL);

inline V ld(const R* p) { return LD(EW, LMUL)(p, VL); }
inline void st(R* p, V v) { ST(EW)(p, v, VL); }

template <int c>
inline V addc(V acc, V v) {
   if constexpr (c == 1) return __riscv_vfadd(acc, v, VL);
   else if constexpr (c == -1) return __riscv_vfsub(acc, v, VL);
   else return acc;
}

struct Ctx {
   R* f;
   int64_t sf1, sf2, sf3;
   int64_t z, y0, n0;
};

//  where the pre-collision value of direction I of block cell (yy, x) is read
template <int P, int I>
inline R* src(const Ctx& c, int64_t yy, int64_t x) {
   if constexpr (P == 0) return c.f + x + (c.y0 + yy) * c.sf1 + c.z * c.sf2 + I * c.sf3;
   else return c.f + (x - CX[I]) + (c.y0 + yy - CY[I]) * c.sf1 + (c.z - CZ[I]) * c.sf2 + INV[I] * c.sf3;
}
//  where its post-collision value is written
template <int P, int I>
inline R* dst(const Ctx& c, int64_t yy, int64_t x) {
   if constexpr (P == 0) return c.f + x + (c.y0 + yy) * c.sf1 + c.z * c.sf2 + INV[I] * c.sf3;
   else return c.f + (x + CX[I]) + (c.y0 + yy + CY[I]) * c.sf1 + (c.z + CZ[I]) * c.sf2 + I * c.sf3;
}

template <int P, int... Is>
inline void moments_group(const Ctx& c, R* a0, R* a1, R* a2, R* a3, bool first, std::integer_sequence<int, Is...>) {
   for (int64_t yy = 0; yy < BY; ++yy)
      for (int64_t x = 0; x < c.n0; x += VL) {
         const int64_t k = yy * c.n0 + x;
         V r, jx, jy, jz;
         if (first) r = jx = jy = jz = SPLAT(EW, LMUL)(R(0), VL);
         else { r = ld(a0 + k); jx = ld(a1 + k); jy = ld(a2 + k); jz = ld(a3 + k); }
         ([&] {
             const V v = ld(src<P, Is>(c, yy, x));
             r = __riscv_vfadd(r, v, VL);
             jx = addc<CX[Is]>(jx, v);
             jy = addc<CY[Is]>(jy, v);
             jz = addc<CZ[Is]>(jz, v);
          }(),
          ...);
         st(a0 + k, r); st(a1 + k, jx); st(a2 + k, jy); st(a3 + k, jz);
      }
}

template <int I>
inline V cu_of(V ux, V uy, V uz) {   // c_I . u, no zero splat
   constexpr int cx = CX[I], cy = CY[I], cz = CZ[I];
   if constexpr (cx != 0) {
      V a = cx > 0 ? ux : __riscv_vfneg(ux, VL);
      return addc<cz>(addc<cy>(a, uy), uz);
   } else if constexpr (cy != 0) {
      V a = cy > 0 ? uy : __riscv_vfneg(uy, VL);
      return addc<cz>(a, uz);
   } else {
      return cz > 0 ? uz : __riscv_vfneg(uz, VL);
   }
}

//  out = v + omega (w (dr + rho t) - v)
inline V relax(V v, V dr, V rho, V t, R w, R omega) {
   const V feq = __riscv_vfmul(__riscv_vfmacc(dr, rho, t, VL), w, VL);
   return __riscv_vfmacc(v, omega, __riscv_vfsub(feq, v, VL), VL);
}

template <int P, int... Ps>
inline void collide_pairs(const Ctx& c, R* const* sc, R omega, bool with_rest, std::integer_sequence<int, Ps...>) {
   for (int64_t yy = 0; yy < BY; ++yy)
      for (int64_t x = 0; x < c.n0; x += VL) {
         const int64_t k = yy * c.n0 + x;
         const V dr = ld(sc[0] + k), rho = ld(sc[1] + k), ux = ld(sc[2] + k), uy = ld(sc[3] + k), uz = ld(sc[4] + k);
         const V base = ld(sc[5] + k);   // -1.5 u^2
         if (with_rest) {   // direction 0 is its own inverse: same slot, same cell, in both parities
            R* p = c.f + x + (c.y0 + yy) * c.sf1 + c.z * c.sf2;
            st(p, relax(ld(p), dr, rho, base, W[0], omega));
         }
         ([&] {
             constexpr int I = PAIRS[Ps], J = INV[I];
             const V vi = ld(src<P, I>(c, yy, x)), vj = ld(src<P, J>(c, yy, x));   // both loads first
             const V cu = cu_of<I>(ux, uy, uz);                                     // cu_J = -cu
             const V a = __riscv_vfmul(cu, R(4.5), VL);
             const V ti = __riscv_vfmacc(base, cu, __riscv_vfadd(a, R(3), VL), VL);
             const V tj = __riscv_vfmacc(base, cu, __riscv_vfsub(a, R(3), VL), VL);
             st(dst<P, I>(c, yy, x), relax(vi, dr, rho, ti, W[I], omega));
             st(dst<P, J>(c, yy, x), relax(vj, dr, rho, tj, W[J], omega));
          }(),
          ...);
      }
}

template <int Start, int Len>
using Seq = decltype([]<int... Is>(std::integer_sequence<int, Is...>) {
   return std::integer_sequence<int, (Start + Is)...>{};
}(std::make_integer_sequence<int, Len>{}));

template <int G, int N, int Start = 0, class F>
inline void for_groups(F&& fn) {
   if constexpr (Start < N) {
      constexpr int Len = (Start + G <= N) ? G : N - Start;
      fn(Seq<Start, Len>{}, Start == 0);
      for_groups<G, N, Start + Len>(fn);
   }
}

template <int P>
void step(R* f, R* rho, R* u, int64_t n0, int64_t n1, int64_t n2, int64_t sf1, int64_t sf2, int64_t sf3,
          int64_t sr1, int64_t sr2, int64_t su1, int64_t su2, int64_t su3, R omega) {
   alignas(64) static R acc[4][MAXCELLS];
   alignas(64) static R scr[6][MAXCELLS];
   R* sc[6] = {scr[0], scr[1], scr[2], scr[3], scr[4], scr[5]};
   Ctx c{f, sf1, sf2, sf3, 0, 0, n0};
   for (int64_t z = 0; z < n2; ++z)
      for (int64_t y0 = 0; y0 + BY <= n1; y0 += BY) {
         c.z = z;
         c.y0 = y0;
         for_groups<GM, Q>([&](auto seq, bool first) { moments_group<P>(c, acc[0], acc[1], acc[2], acc[3], first, seq); });
         for (int64_t yy = 0; yy < BY; ++yy)
            for (int64_t x = 0; x < n0; x += VL) {
               const int64_t k = yy * n0 + x;
               const V dr = ld(acc[0] + k);
               const V r = __riscv_vfadd(dr, R(1), VL);
               const V inv = __riscv_vfrdiv(r, R(1), VL);
               const V ux = __riscv_vfmul(ld(acc[1] + k), inv, VL);
               const V uy = __riscv_vfmul(ld(acc[2] + k), inv, VL);
               const V uz = __riscv_vfmul(ld(acc[3] + k), inv, VL);
               V usq = __riscv_vfmul(ux, ux, VL);
               usq = __riscv_vfmacc(usq, uy, uy, VL);
               usq = __riscv_vfmacc(usq, uz, uz, VL);
               st(scr[0] + k, dr); st(scr[1] + k, r); st(scr[2] + k, ux); st(scr[3] + k, uy); st(scr[4] + k, uz);
               st(scr[5] + k, __riscv_vfmul(usq, R(-1.5), VL));
               const int64_t o = x + (y0 + yy) * sr1 + z * sr2, ou = x + (y0 + yy) * su1 + z * su2;
               st(rho + o, r);
               st(u + ou, ux); st(u + ou + su3, uy); st(u + ou + 2 * su3, uz);
            }
         for_groups<GP, 9>([&](auto seq, bool first) { collide_pairs<P>(c, sc, omega, first, seq); });
      }
}
}   // namespace

extern "C" void run_kernel_aa(R* f, R* rho, R* u, int64_t n0, int64_t n1, int64_t n2, int64_t sf1, int64_t sf2,
                              int64_t sf3, int64_t sr1, int64_t sr2, int64_t su1, int64_t su2, int64_t su3,
                              int parity, R omega) {
   if (parity == 0) step<0>(f, rho, u, n0, n1, n2, sf1, sf2, sf3, sr1, sr2, su1, su2, su3, omega);
   else step<1>(f, rho, u, n0, n1, n2, sf1, sf2, sf3, sr1, sr2, su1, su2, su3, omega);
}
