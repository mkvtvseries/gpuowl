// gpuOwl, an OpenCL Mersenne primality test.
// Copyright (C) 2017 Mihai Preda.

// The data is organized in pairs of words in a matrix WIDTH x HEIGHT.
// The pair (a, b) is sometimes interpreted as the complex value a + i*b.
// The order of words is column-major (i.e. transposed from the usual row-major matrix order).

// Expected defines: WIDTH, HEIGHT, EXP.
// Defines to select between "Fast Gallois Transform" using either M(31) or M(61),
// and floating point FFT in either double or single precision.
// One of: FGT_31, FGT_61, FP_DP (double precision), FP_SP (single precision).
// If FGT, also LOG_ROOT2 is expected, LOG_ROOT2 == log2(32 / (NWORDS % 31) % 31).

// FGT: a GF(P^2) (Galois Field) convolution, with P == M(31) == 2^31-1 a Mersenne prime.
// GF(P^2) means Gaussian integers ("complex integers") with the real/imaginary part modulo P.

// Number of words; a power of two?
#define NWORDS (WIDTH * HEIGHT * 2u)

// Used in bitlen() and weighting.
#define STEP (NWORDS - (EXP % NWORDS))

// Each word has either BASE_BITLEN ("small word") or BASE_BITLEN+1 ("big word") bits.
#define BASE_BITLEN (EXP / NWORDS)

// Propagate carry this many pairs of words.
#define CARRY_LEN 16

// OpenCL 2.x introduces the "generic" memory space, so there's no need to specify "global" on pointers everywhere.
#if __OPENCL_C_VERSION__ >= 200
#define G
#else
#define G global
#endif

// This mem_fence is only needed to workaround a bug in the ROCm compiler,
// see https://github.com/RadeonOpenCompute/ROCm/issues/234
// For some reason, the bug does not seem to affect floating point.
void amd_fence() {
#if !defined(NO_AMDFENCE) && !(FP_DP || FP_SP)
  mem_fence(CLK_LOCAL_MEM_FENCE);
#endif
}

uint lo(ulong a) { return a & 0xffffffffu; }
uint up(ulong a) { return a >> 32; }

#if FGT_31 || FGT_61

#if FGT_31
typedef uint T;
typedef uint2 T2;
#else
typedef ulong T;
typedef ulong2 T2;
#endif

typedef uint Word;
typedef uint2 Word2;
typedef ulong Carry;

#elif FP_DP || FP_SP

#pragma OPENCL FP_CONTRACT ON

#if FP_DP
#pragma OPENCL EXTENSION cl_khr_fp64 : enable
typedef double T;
typedef double2 T2;
#else
typedef float T;
typedef float2 T2;
#endif // FP_DP

typedef int Word;
typedef int2 Word2;
typedef long Carry;

#else
#error "Expected FGT_31, FGT_61, FP_DP or FP_SP"
#endif


T2 U2(T a, T b) { return (T2)(a, b); }


#if FGT_31 || FGT_61

typedef uint u32;
typedef ulong u64;

#include "nttshared.h"

// mul with (0, 1). (twiddle of tau/4, sqrt(-1) aka "i").
T2 mul_t4(T2 a) { return U2(neg(a.y), a.x); }

#if FGT_31

// mul with (2^15, 2^15). (twiddle of tau/8 aka sqrt(i)). Note: 2 * (2^15)^2 == 1 (mod M31).
T2 mul_t8(T2 a) { return U2(shl1(a.x + neg(a.y), 15), shl1(a.x + a.y, 15)); }

// mul with (-2^15, 2^15). (twiddle of 3*tau/8).
T2 mul_3t8(T2 a) { return U2(shl1(neg(a.x) + neg(a.y), 15), shl1(a.x + neg(a.y), 15)); }

#else

// mul with (2^30, 2^30).
T2 mul_t8(T2 a) { return U2(shl1(a.x + neg(a.y), 30), shl1(a.x + a.y, 30)); }

// mul with (-2^30, 2^30). (twiddle of 3*tau/8).
T2 mul_3t8(T2 a) { return U2(shl1(neg(a.x) + neg(a.y), 30), shl1(a.x + neg(a.y), 30)); }

#endif

#elif FP_DP || FP_SP

T neg(T x) { return -x; }
T add1(T a, T b) { return a + b; }
T sub1(T a, T b) { return a - b; }

T2 add(T2 a, T2 b) { return a + b; }
T2 sub(T2 a, T2 b) { return a - b; }

T shl1(T a, uint k) { return a * (1 << k); }

// complex mul
T2 mul(T2 a, T2 b) { return U2(a.x * b.x - a.y * b.y, a.x * b.y + a.y * b.x); }
// T2 mul(T2 a, T2 b) { return U2(a.x * b.x - a.y * b.y, (a.x + a.y) * (b.x + b.y) - a.x * b.x - a.y * b.y); }

// complex square
T2 sq(T2 a) { return U2((a.x + a.y) * (a.x - a.y), 2 * a.x * a.y); }

T mul1(T a, T b) { return a * b; }

T2 mul_t4(T2 a)  { return mul(a, U2( 0, -1)); }
T2 mul_t8(T2 a)  { return mul(a, U2( 1, -1)) * (T)(M_SQRT1_2); }
T2 mul_3t8(T2 a) { return mul(a, U2(-1, -1)) * (T)(M_SQRT1_2); }

#else
#error
#endif


T2 shl(T2 a, uint k) { return U2(shl1(a.x, k), shl1(a.y, k)); }

T2 addsub(T2 a) { return U2(add1(a.x, a.y), sub1(a.x, a.y)); }
T2 swap(T2 a) { return U2(a.y, a.x); }
T2 conjugate(T2 a) { return U2(a.x, neg(a.y)); }

uint extra(uint k) { return mul24(k, STEP) % NWORDS; }

void bar()    { barrier(CLK_LOCAL_MEM_FENCE); }
void bigBar() { barrier(CLK_GLOBAL_MEM_FENCE | CLK_LOCAL_MEM_FENCE); }

// Is the word at pos a big word (BASE_BITLEN+1 bits)? (vs. a small, BASE_BITLEN bits word).
bool isBigWord(uint k) { return extra(k) + STEP < NWORDS; }

// Number of bits for the word at pos.
uint bitlen(uint k) { return EXP / NWORDS + isBigWord(k); }


#if FGT_31 || FGT_61

Word lowBits(T x, uint bits) { return ((Word) x) & ((1u << bits) - 1); }

// one step of carry propagation; optional mul.
Word carryStep(Carry x, Carry *carry, uint bits) {
  x += *carry;
  *carry = x >> bits;
  return lowBits(x, bits);
}

// uint update(T x, Carry *carry, uint bits) { return carryStep(x, carry, bits); }

Carry unweight(T x, uint pos) {
  x = (x + ((x + 1) >> MBITS)) & M; // if x==M, set it to 0.
  return shl1(x, (extra(pos) * (MBITS - LOG_ROOT2) + (MBITS - LOG_NWORDS - 2)) % MBITS);
}

// Reverse weighting and carry propagation.
Word2 unweightAndCarry(uint mul, T2 u, Carry *carry, uint pos, const G T2 *dummyA, uint dummyP) {
  Word x = carryStep(mul * unweight(u.x, 2 * pos + 0), carry, bitlen(2 * pos + 0));
  Word y = carryStep(mul * unweight(u.y, 2 * pos + 1), carry, bitlen(2 * pos + 1));
  return (Word2) (x, y);
}

// NWORDS-th order root of 2: root2 ^ NWORDS == 2 (mod M31)
T weight1(Word x, uint pos) { return shl1(x, (extra(pos) * LOG_ROOT2) % MBITS); }

T2 weightAux(Word2 a, uint pos) { return U2(weight1(a.x, 2 * pos + 0), weight1(a.y, 2 * pos + 1)); }

T2 weight(Word2 a, uint pos, const G T2 *dummyA, uint dummyP) { return weightAux(a, pos); }

// No carry out. The final carry is "absorbed" in the last word.
T2 carryAndWeightFinal(Word2 u, Carry carry, uint pos, const G T2 *dummyA, uint dummyP) {
  u.x = carryStep(u.x, &carry, bitlen(2 * pos + 0));
  u.y = u.y + carry;
  return weightAux(u, pos);
}

#elif FP_DP || FP_SP

Word lowBits(int u, uint bits) { return (u << (32 - bits)) >> (32 - bits); }

Word carryStep(Carry x, Carry *carry, int bits) {
  x += *carry;
  Word w = lowBits(x, bits);
  *carry = (x - w) >> bits;
  return w;
}

// Simpler version of signbit(a).
uint signBit(double a) { return ((uint *)&a)[1] >> 31; }

uint oldBitlen(double a) { return EXP / NWORDS + signBit(a); }

Carry unweight(T x, T weight) { return rint(x * fabs(weight)); }

Word2 unweightAndCarry(uint mul, T2 u, Carry *carry, uint dummyPos, const G T2 *iA, uint p) {
  T2 weight = iA[p];
  Word a = carryStep(mul * unweight(u.x, weight.x), carry, oldBitlen(weight.x));
  Word b = carryStep(mul * unweight(u.y, weight.y), carry, oldBitlen(weight.y));
  return (Word2) (a, b);
}

T2 weightAux(Word x, Word y, T2 weight) { return U2(x, y) * fabs(weight); }

T2 weight(Word2 a, uint dummyPos, const G T2 *A, uint p) { return weightAux(a.x, a.y, A[p]); }

// No carry out. The final carry is "absorbed" in the last word.
T2 carryAndWeightFinal(Word2 u, Carry carry, uint dummyPos, const G T2 *A, uint p) {
  T2 w = A[p];
  Word x = carryStep(u.x, &carry, oldBitlen(w.x));
  Word y = u.y + carry;
  return weightAux(x, y, w);
}

#else
#error
#endif


// Generic code below.

// Carry propagation from word and carry.
Word2 carryWord(Word2 a, Carry *carry, uint pos) {
  a.x = carryStep(a.x, carry, bitlen(2 * pos + 0));
  a.y = carryStep(a.y, carry, bitlen(2 * pos + 1));
  return a;
}

T2 foo2(T2 a, T2 b) {
  a = addsub(a);
  b = addsub(b);
  return addsub(U2(mul1(a.x, b.x), mul1(a.y, b.y)));
}

// computes 2*[x^2+y^2 + i*(2*x*y)]. Needs a name.
T2 foo(T2 a) { return foo2(a, a); }

#define X2(a, b) { T2 t = a; a = add(t, b); b = sub(t, b); }
#define SWAP(a, b) { T2 t = a; a = b; b = t; }

void fft4Core(T2 *u) {
  X2(u[0], u[2]);
  X2(u[1], u[3]);
  u[3] = mul_t4(u[3]);
  X2(u[0], u[1]);
  X2(u[2], u[3]);
}

void fft6Core(T2 *u) {

}

void fft8Core(T2 *u) {
  for (int i = 0; i < 4; ++i) { X2(u[i], u[i + 4]); }
  u[5] = mul_t8(u[5]);
  u[6] = mul_t4(u[6]);
  u[7] = mul_3t8(u[7]);
  
  fft4Core(u);
  fft4Core(u + 4);
}

void fft4(T2 *u) {
  fft4Core(u);
  SWAP(u[1], u[2]);
}

void fft8(T2 *u) {
  fft8Core(u);
  SWAP(u[1], u[4]);
  SWAP(u[3], u[6]);
}

void shufl(uint WG, local T *lds, T2 *u, uint n, uint f) {
  uint me = get_local_id(0);
  uint m = me / f;
  
  for (int b = 0; b < 2; ++b) {
    if (b) { bar(); }
    for (uint i = 0; i < n; ++i) { lds[(m + i * WG / f) / n * f + m % n * WG + me % f] = ((T *) (u + i))[b]; }
    bar();
    for (uint i = 0; i < n; ++i) { ((T *) (u + i))[b] = lds[i * WG + me]; }
  }
  amd_fence();
}

void tabMul(uint WG, const G T2 *trig, T2 *u, uint n, uint f) {
  uint me = get_local_id(0);
  for (int i = 1; i < n; ++i) { u[i] = mul(u[i], trig[me / f + i * (WG / f)]); }
}

void fft1kImpl(local T *lds, T2 *u, const G T2 *trig) {
  for (int s = 6; s >= 0; s -= 2) {
    fft4(u);
    
    if (s != 6) { bar(); }
    shufl (256, lds,  u, 4, 1 << s);
    tabMul(256, trig, u, 4, 1 << s);
  }

  fft4(u);
}

// WG:512, LDS:32KB, u:8.
void fft4kImpl(local T *lds, T2 *u, const G T2 *trig) {
  for (int s = 6; s >= 0; s -= 3) {
    fft8(u);

    if (s != 6) { bar(); }
    shufl (512, lds,  u, 8, 1 << s);
    tabMul(512, trig, u, 8, 1 << s);
  }
  fft8(u);
}

// WG:256, LDS:16KB?, u:8
void fft2kImpl(local T *lds, T2 *u, const G T2 *trig) {
  for (int s = 5; s >= 2; s -= 3) {
      fft8(u);
      if (s != 5) { bar(); }
      shufl (256, lds,  u, 8, 1 << s);
      tabMul(256, trig, u, 8, 1 << s);
  }
  
  /*
  fft8(u);
  shufl(256, lds,   u, 8, 32);
  tabMul(256, trig, u, 8, 32);

  fft8(u);
  bar();
  shufl(256, lds,   u, 8, 4);
  tabMul(256, trig, u, 8, 4);
  */
  
  fft8(u);

  uint me = get_local_id(0);
  for (int b = 0; b < 2; ++b) {
    bar();
    for (int i = 0; i < 8; ++i) { lds[(me + i * 256) / 4 + me % 4 * 512] = ((T *) (u + i))[b]; }
    bar();
    for (int i = 0; i < 4; ++i) {
      ((T *) (u + i))[b]     = lds[i * 512       + me];
      ((T *) (u + i + 4))[b] = lds[i * 512 + 256 + me];
    }
  }

  amd_fence();
  for (int i = 1; i < 4; ++i) {
    u[i]     = mul(u[i],     trig[i * 512       + me]);
    u[i + 4] = mul(u[i + 4], trig[i * 512 + 256 + me]);
  }

  fft4(u);
  fft4(u + 4);

  // fix order: interleave u[0:3] and u[4:7], like (u.even, u.odd) = (u.lo, u.hi).
  SWAP(u[1], u[2]);
  SWAP(u[1], u[4]);
  SWAP(u[5], u[6]);
  SWAP(u[3], u[6]);
}

// choose between 1K and 2K based on N.
void fftImpl(uint SIZE, local T *lds, T2 *u, const G T2 *trig) {
  if (SIZE == 1024) {
    fft1kImpl(lds, u, trig);
  } else if (SIZE == 2048) {
    fft2kImpl(lds, u, trig);
  } else if (SIZE == 4096) {
    fft4kImpl(lds, u, trig);
  }
}

void read(uint WG, uint N, T2 *u, G T2 *in, uint base) {
  for (int i = 0; i < N; ++i) { u[i] = in[base + i * WG + (uint) get_local_id(0)]; }
}

void write(uint WG, uint N, T2 *u, G T2 *out, uint base) {
  for (int i = 0; i < N; ++i) { out[base + i * WG + (uint) get_local_id(0)] = u[i]; }
}

// fftPremul: weight words with "A" (for IBDWT) followed by FFT.
void fftPremul(uint N, uint H, local T *lds, T2 *u, const G Word2 *in, G T2 *out, const G T2 *A, const G T2 *trig) {
  uint g = get_group_id(0);
  uint step = N * 256 * g;
  in  += step;
  out += step;
  A   += step;
  
  uint me = get_local_id(0);

  for (int i = 0; i < N; ++i) {
    uint pos = g + H * 256 * i + H * me;
    u[i] = weight(in[256 * i + me], pos, A, me + 256 * i);
  }

  fftImpl(N * 256, lds, u, trig);

  write(256, N, u, out, 0);
}

// Carry propagation with optional MUL-3, over CARRY_LEN words.
// Input is conjugated and inverse-weighted.
void carryACore(uint N, uint H, uint mul, const G T2 *in, const G T2 *A, G Word2 *out, G Carry *carryOut) {
  uint g  = get_group_id(0);
  uint me = get_local_id(0);
  uint gx = g % N;
  uint gy = g / N;

  uint step = 256 * gx + N * 256 * CARRY_LEN * gy;
  in  += step;
  out += step;
  A   += step;

  Carry carry = 0;

  for (int i = 0; i < CARRY_LEN; ++i) {
    uint pos = CARRY_LEN * gy + H * 256 * gx  + H * me + i;
    uint p = me + i * N * 256;
    out[p] = unweightAndCarry(mul, conjugate(in[p]), &carry, pos, A, p);
  }
  carryOut[g * 256 + me] = carry;
}

// The second round of carry propagation (16 words), needed to "link the chain" after carryA.
void carryBCore(uint N, uint H, G Word2 *io, const G Carry *carryIn) {
  uint g  = get_group_id(0);
  uint me = get_local_id(0);
  uint gx = g % N;
  uint gy = g / N;
  
  uint step = 256 * gx + N * 256 * CARRY_LEN * gy;
  io += step;

  uint HB = H / CARRY_LEN;
  
  uint prev = (gy + HB * 256 * gx + HB * me - 1) & (HB * N * 256 - 1);
  uint prevLine = prev % HB;
  uint prevCol  = prev / HB;
  Carry carry = carryIn[N * 256 * prevLine + prevCol];
  
  for (int i = 0; i < CARRY_LEN; ++i) {
    uint pos = CARRY_LEN * gy + H * 256 * gx + H * me + i;
    uint p = me + i * N * 256;
    io[p] = carryWord(io[p], &carry, pos);
    if (!carry) { return; }
  }
}

// Inputs normal (non-conjugate); outputs conjugate.
void csquare(uint W, uint H, G T2 *io, const G T2 *bigTrig) {
  uint g  = get_group_id(0);
  uint me = get_local_id(0);

  if (g == 0 && me == 0) {
    io[0]     = shl(foo(conjugate(io[0])), 2);
    io[W / 2] = shl(sq(conjugate(io[W / 2])), 3);
    return;
  }
  
  uint line = g / (W / 512);
  uint posInLine = g % (W / 512) * 256 + me;
  uint k = line * W + posInLine;
  uint v = ((H - line) & (H - 1)) * W + (W - 1) - posInLine + ((line - 1) >> 31);
  
  T2 a = io[k];
  T2 b = conjugate(io[v]);
  T2 t = swap(mul(bigTrig[W * 2 + H / 2 + line], bigTrig[posInLine]));
  
  X2(a, b);
  b = mul(b, conjugate(t));
  X2(a, b);

  a = sq(a);
  b = sq(b);

  X2(a, b);
  b = mul(b,  t);
  X2(a, b);
  
  io[k] = conjugate(a);
  io[v] = b;
}

// Like csquare(), but for multiplication.
void cmul(uint W, uint H, G T2 *io, const G T2 *in, const G T2 *bigTrig) {
  uint g  = get_group_id(0);
  uint me = get_local_id(0);

  if (g == 0 && me == 0) {
    io[0]     = shl(foo2(conjugate(io[0]), conjugate(in[0])), 2);
    io[W / 2] = shl(conjugate(mul(io[W / 2], in[W / 2])), 3);
    return;
  }
  
  uint line = g / (W / 512);
  uint posInLine = g % (W / 512) * 256 + me;
  uint k = line * W + posInLine;
  uint v = ((H - line) & (H - 1)) * W + (W - 1) - posInLine + ((line - 1) >> 31);
  
  T2 a = io[k];
  T2 b = conjugate(io[v]);
  T2 t = swap(mul(bigTrig[W * 2 + H / 2 + line], bigTrig[posInLine]));
  
  X2(a, b);
  b = mul(b, conjugate(t));
  X2(a, b);
  
  T2 c = in[k];
  T2 d = conjugate(in[v]);
  X2(c, d);
  d = mul(d, conjugate(t));
  X2(c, d);

  a = mul(a, c);
  b = mul(b, d);

  X2(a, b);
  b = mul(b,  t);
  X2(a, b);
  
  io[k] = conjugate(a);
  io[v] = b;
}

void transposeCore(local T *lds, T2 *u) {
  uint me = get_local_id(0);
  for (int b = 0; b < 2; ++b) {
    if (b) { bar(); }
    for (int i = 0; i < 16; ++i) {
      uint l = i * 4 + me / 64;
      // uint c = me % 64;
      lds[l * 64 + (me + l) % 64 ] = ((T *)(u + i))[b];
    }
    bar();
    for (int i = 0; i < 16; ++i) {
      uint c = i * 4 + me / 64;
      uint l = me % 64;
      ((T *)(u + i))[b] = lds[l * 64 + (c + l) % 64];
    }
  }
}

// M == max(W, H)
void transpose(uint W, uint H, uint MAX, local T *lds, const G T2 *in, G T2 *out, const G T2 *bigTrig) {
  uint GW = W / 64, GH = H / 64;
  uint g = get_group_id(0), gx = g % GW, gy = g / GW;
  gy = (gy + gx) % GH;
  in   += gy * 64 * W + gx * 64;
  out  += gy * 64     + gx * 64 * H;
  uint me = get_local_id(0), mx = me % 64, my = me / 64;
  
  T2 u[16];
  for (int i = 0; i < 16; ++i) {
    uint p = (my + i * 4) * W + mx;
    u[i] = in[p];
  }

  transposeCore(lds, u);
  
  for (int i = 0; i < 16; ++i) {
    uint k = mul24(gy * 64 + mx, gx * 64 + my + (uint) i * 4);
    u[i] = mul(u[i], bigTrig[MAX * 2 + k % (W * H / (MAX * 2))]);
    u[i] = mul(u[i], bigTrig[k / (W * H / (MAX * 2))]);

    uint p = (my + i * 4) * H + mx;
    out[p] = u[i];
  }
}

#define KERNEL(x) kernel __attribute__((reqd_work_group_size(x, 1, 1))) void

#define N_WIDTH  (WIDTH  / 256)
#define N_HEIGHT (HEIGHT / 256)

#ifndef ALT_RESTRICT

#define P(x) global x * restrict
#define CP(x) const P(x)
typedef CP(T2) Trig;

#else

#define P(x) global x *
#define CP(x) const P(x)
typedef CP(T2) restrict Trig;

#endif



/*
// experimental 2K fft implemented with 512 WG size.
void fft2kTry(uint WG, local T *lds, T2 *u, const G T2 *trig) {
  fft4(u);
  shufl(WG, lds,   u, 4, 128);
  tabMul(WG, trig, u, 4, 128);

  fft4(u);
  bar();
  shufl(WG, lds,   u, 4, 32);
  tabMul(WG, trig, u, 4, 32);

  fft4(u);
  bar();
  shufl(WG, lds,   u, 4, 8);
  tabMul(WG, trig, u, 4, 8);

  fft4(u);
  bar();
  shufl(WG, lds,   u, 4, 2);
  tabMul(WG, trig, u, 4, 2);

  fft4(u);
  uint me = get_local_id(0);
  for (int b = 0; b < 2; ++b) {
    bar();
    for (int i = 0; i < 4; ++i) { lds[(me + i * WG) / 2 + me % 2 * 2 * WG] = ((T *) (u + i))[b]; }
    bar();
    for (int i = 0; i < 2; ++i) {
      ((T *) (u + i))[b]     = lds[i * 2 * WG + me];
      ((T *) (u + i + 2))[b] = lds[i * 2 * WG + WG + me]; 
    }
  }

  u[1] = mul(u[1], trig[2 * WG + me]);
  u[3] = mul(u[3], trig[2 * WG + WG + me]);

  X2(u[0], u[1]);
  X2(u[2], u[3]);
  //interleave
  SWAP(u[1], u[2]);
}

KERNEL(512) fftHTry(P(T2) io, Trig smallTrig) {
  local T lds[2048];
  T2 u[4];

  uint g = get_group_id(0);
  uint step = g * 2048;
  io += step;

  read(512, 4, u, io, 0);
  fft2kTry(512, lds, u, smallTrig);
  write(512, 4, u, io, 0);
}
*/
