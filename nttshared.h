#if FGT_31

#define TBITS 32
#define MBITS 31

uint2 wideMul(u32 a, u32 b) {
  u64 ab = ((u64) a) * b;
  return U2(lo(ab), up(ab));
}

#elif FGT_61

// bits in a word of type T.
#define TBITS 64

// bits in reduced mod M.
#define MBITS 61

u64 mad64(u32 a, u32 b, u64 c) {
#ifdef ASM
  // force V_MAD_U64_U32.
  u64 result;
  __asm("v_mad_u64_u32 %0, vcc, %1, %2, %3\n"
        : "=v"(result)
        : "v"(a), "v"(b), "v"(c)
        : "vcc"
      );
  return result;
#else
  // The compiler should be able to generate V_MAD_U64_U32 by itself...
  return ((u64) a) * b + c;
#endif
}

u64 mul64(u32 a, u32 b) {
#ifdef ASM
  u64 result;
  __asm("v_mad_u64_u32 %0, vcc, %1, %2, 0\n"
        : "=v"(result)
        : "v"(a), "v"(b)
        : "vcc"
      );
  return result;  
#else
  return ((u64) a) * b;
#endif
}

ulong2 wideMul(u64 ab, u64 cd) {
  u32 a = lo(ab);
  u32 b = up(ab);
  u32 c = lo(cd);
  u32 d = up(cd);
  
  u64 x = mul64(a, c);
  u64 y = mad64(a, d, up(x));
  u64 z = mad64(b, c, y);
  u64 w = mad64(b, d, up(z));
  
  u64 low = lo(x) | (((u64) lo(z)) << 32);
  return U2(low, w);
}

#else
#error "Expected FGT_31 or FGT_61."
#endif


#define M ((((T) 1) << MBITS) - 1)

T mod(T a) { return (a & M) + (a >> MBITS); }

T neg(T a) { return M - a; }

T add1(T a, T b) { return mod(a + b); }
T sub1(T a, T b) { return add1(a, neg(b)); }

T2 add(T2 a, T2 b) { return U2(add1(a.x, b.x), add1(a.y, b.y)); }
T2 sub(T2 a, T2 b) { return U2(sub1(a.x, b.x), sub1(a.y, b.y)); }

// Assumes k reduced mod MBITS.
T shl1(T a, u32 k) {
  T up = a >> (MBITS - k);
  T lo = (a << k) & M;
  return mod(up + lo);
}

// mul not reduced.
T weakMul1(T a, T b) {
  T2 ab = wideMul(a, b);
  // return (ab.y << (TBITS - MBITS)) + (ab.x >> MBITS) + (ab.x & M);
  return add1(mod(mod(ab.y) << (TBITS - MBITS)), mod(ab.x));
}

T mul1(T a, T b) { return mod(weakMul1(a, b)); }


#if FGT_31 || SAFE_61
// The main, complex multiplication; input and output reduced.
// (a + i*b) * (c + i*d) mod reduced.
T2 mul(T2 u, T2 v) {
  T a = u.x, b = u.y, c = v.x, d = v.y;
  T k1 = mul1(c,      add1(a, b));
  T k2 = mul1(a,      sub1(d, c));
  T k3 = mul1(neg(b), add1(d, c));
  return U2(mod(k1 + k3), mod(k1 + k2));
}

// input, output reduced. Uses (a + i*b)^2 == ((a+b)*(a-b) + i*2*a*b).
T2 sq(T2 a) { return U2(mul1(add1(a.x, a.y), sub1(a.x, a.y)), mul1(a.x, mod(a.y << 1))); }

#elif FGT_61
// On M61, we can relax the reductions because we have 3 "spare bits" at the top (vs. 1 spare bit for M31).

T2 mul(T2 u, T2 v) {
  T a = u.x, b = u.y, c = v.x, d = v.y;
  T k1 = weakMul1(c,      a + b);
  T k2 = weakMul1(a,      d + neg(c));
  T k3 = weakMul1(neg(b), d + c);
  return U2(mod(k1 + k3), mod(k1 + k2));
}

// input, output 31 bits. Uses (a + i*b)^2 == ((a+b)*(a-b) + i*2*a*b).
T2 sq(T2 a) { return U2(mul1(a.x + a.y, a.x + neg(a.y)), mul1(a.x, a.y << 1)); }

#else
#error "Expected FGT_31 or FGT_61"
#endif
