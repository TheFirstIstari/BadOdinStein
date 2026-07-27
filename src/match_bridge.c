/* match_bridge.c — SIMD-accelerated L1 distance via hardware intrinsics.
 *
 * Provides feature_l1_simd and feature_l1_bounded_simd for Odin,
 * using the same SSE2/AVX2/NEON intrinsics as the C reference
 * (BadApplestein's match.c).
 */
#include <stdint.h>
#include <string.h>

#if defined(__AVX2__)
#include <immintrin.h>
#define HAS_SIMD 1
#define SIMD_WIDTH 32
#elif defined(__SSE2__)
#include <emmintrin.h>
#define HAS_SIMD 1
#define SIMD_WIDTH 16
#elif defined(__ARM_NEON) || defined(__ARM_NEON__)
#include <arm_neon.h>
#define HAS_SIMD 1
#define SIMD_WIDTH 16
#else
#define HAS_SIMD 0
#define SIMD_WIDTH 1
#endif

/* ── Full L1 distance (no early exit) ──────────────────────── */

#if HAS_SIMD && defined(__AVX2__)
uint32_t feature_l1_simd(const uint8_t *a, const uint8_t *b, int len) {
    int j = 0;
    __m256i acc = _mm256_setzero_si256();
    for (; j + 32 <= len; j += 32) {
        __m256i va = _mm256_loadu_si256((const __m256i *)(a + j));
        __m256i vb = _mm256_loadu_si256((const __m256i *)(b + j));
        acc = _mm256_add_epi64(acc, _mm256_sad_epu8(va, vb));
    }
    /* Horizontal sum of 4 × 64-bit accumulators */
    __m128i lo = _mm256_castsi256_si128(acc);
    __m128i hi = _mm256_extracti128_si256(acc, 1);
    __m128i sum128 = _mm_add_epi64(lo, hi);
    uint64_t parts[2];
    _mm_storeu_si128((__m128i *)parts, sum128);
    uint64_t s = parts[0] + parts[1];
    for (; j < len; j++) {
        int d = (int)a[j] - (int)b[j];
        s += (uint64_t)(d < 0 ? -d : d);
    }
    return (s > 0xFFFFFFFFu) ? 0xFFFFFFFFu : (uint32_t)s;
}

#elif HAS_SIMD && defined(__SSE2__)
uint32_t feature_l1_simd(const uint8_t *a, const uint8_t *b, int len) {
    int j = 0;
    __m128i acc = _mm_setzero_si128();
    for (; j + 16 <= len; j += 16) {
        __m128i va = _mm_loadu_si128((const __m128i *)(a + j));
        __m128i vb = _mm_loadu_si128((const __m128i *)(b + j));
        acc = _mm_add_epi64(acc, _mm_sad_epu8(va, vb));
    }
    uint64_t parts[2];
    _mm_storeu_si128((__m128i *)parts, acc);
    uint64_t s = parts[0] + parts[1];
    for (; j < len; j++) {
        int d = (int)a[j] - (int)b[j];
        s += (uint64_t)(d < 0 ? -d : d);
    }
    return (s > 0xFFFFFFFFu) ? 0xFFFFFFFFu : (uint32_t)s;
}

#elif HAS_SIMD && defined(__ARM_NEON)
uint32_t feature_l1_simd(const uint8_t *a, const uint8_t *b, int len) {
    int j = 0;
    uint32x4_t acc = vdupq_n_u32(0);
    for (; j + 16 <= len; j += 16) {
        uint8x16_t va = vld1q_u8(a + j);
        uint8x16_t vb = vld1q_u8(b + j);
        uint8x16_t diff = vabdq_u8(va, vb);
        acc = vpadalq_u16(acc, vpaddlq_u8(diff));
    }
    uint32x2_t sum_pair = vadd_u32(vget_low_u32(acc), vget_high_u32(acc));
    uint64_t s = (uint64_t)vget_lane_u32(sum_pair, 0) + (uint64_t)vget_lane_u32(sum_pair, 1);
    for (; j < len; j++) {
        int d = (int)a[j] - (int)b[j];
        s += (uint32_t)(d < 0 ? -d : d);
    }
    return (s > 0xFFFFFFFFu) ? 0xFFFFFFFFu : (uint32_t)s;
}

#else
/* Scalar fallback */
uint32_t feature_l1_simd(const uint8_t *a, const uint8_t *b, int len) {
    uint32_t dist = 0;
    for (int j = 0; j < len; j++) {
        int d = (int)a[j] - (int)b[j];
        dist += (uint32_t)(d < 0 ? -d : d);
    }
    return dist;
}
#endif

/* ── Bounded L1 distance (early exit when dist > bound) ────── */

#if HAS_SIMD && defined(__AVX2__)
uint32_t feature_l1_bounded_simd(const uint8_t *a, const uint8_t *b,
                                 int len, uint32_t bound) {
    int j = 0;
    __m256i acc = _mm256_setzero_si256();
    for (; j + 32 <= len; j += 32) {
        __m256i va = _mm256_loadu_si256((const __m256i *)(a + j));
        __m256i vb = _mm256_loadu_si256((const __m256i *)(b + j));
        acc = _mm256_add_epi64(acc, _mm256_sad_epu8(va, vb));
        /* Check every 128 bytes (4 AVX iterations) — amortize hsum cost */
        if (((j + 32) % 128) == 0) {
            __m128i lo = _mm256_castsi256_si128(acc);
            __m128i hi = _mm256_extracti128_si256(acc, 1);
            __m128i sum128 = _mm_add_epi64(lo, hi);
            uint64_t parts[2];
            _mm_storeu_si128((__m128i *)parts, sum128);
            uint64_t s = parts[0] + parts[1];
            if (s > (uint64_t)bound) return bound + 1;
        }
    }
    /* Final flush of SIMD accumulator */
    __m128i lo = _mm256_castsi256_si128(acc);
    __m128i hi = _mm256_extracti128_si256(acc, 1);
    __m128i sum128 = _mm_add_epi64(lo, hi);
    uint64_t parts[2];
    _mm_storeu_si128((__m128i *)parts, sum128);
    uint64_t s = parts[0] + parts[1];
    for (; j < len; j++) {
        int d = (int)a[j] - (int)b[j];
        s += (uint64_t)(d < 0 ? -d : d);
        if (s > (uint64_t)bound) return bound + 1;
    }
    return (s > 0xFFFFFFFFu) ? 0xFFFFFFFFu : (uint32_t)s;
}

#elif HAS_SIMD && defined(__SSE2__)
uint32_t feature_l1_bounded_simd(const uint8_t *a, const uint8_t *b,
                                 int len, uint32_t bound) {
    int j = 0;
    __m128i acc = _mm_setzero_si128();
    for (; j + 16 <= len; j += 16) {
        __m128i va = _mm_loadu_si128((const __m128i *)(a + j));
        __m128i vb = _mm_loadu_si128((const __m128i *)(b + j));
        acc = _mm_add_epi64(acc, _mm_sad_epu8(va, vb));
        /* Check every 128 bytes (8 SSE iterations) */
        if (((j + 16) % 128) == 0) {
            uint64_t parts[2];
            _mm_storeu_si128((__m128i *)parts, acc);
            uint64_t s = parts[0] + parts[1];
            if (s > (uint64_t)bound) return bound + 1;
        }
    }
    uint64_t parts[2];
    _mm_storeu_si128((__m128i *)parts, acc);
    uint64_t s = parts[0] + parts[1];
    for (; j < len; j++) {
        int d = (int)a[j] - (int)b[j];
        s += (uint64_t)(d < 0 ? -d : d);
        if (s > (uint64_t)bound) return bound + 1;
    }
    return (s > 0xFFFFFFFFu) ? 0xFFFFFFFFu : (uint32_t)s;
}

#elif HAS_SIMD && defined(__ARM_NEON)
uint32_t feature_l1_bounded_simd(const uint8_t *a, const uint8_t *b,
                                 int len, uint32_t bound) {
    int j = 0;
    uint32x4_t acc = vdupq_n_u32(0);
    for (; j + 16 <= len; j += 16) {
        uint8x16_t va = vld1q_u8(a + j);
        uint8x16_t vb = vld1q_u8(b + j);
        uint8x16_t diff = vabdq_u8(va, vb);
        acc = vpadalq_u16(acc, vpaddlq_u8(diff));
        /* Check every 64 bytes (4 NEON iterations) */
        if (((j + 16) % 64) == 0) {
            uint32_t s = vaddvq_u32(acc);
            if (s > bound) return bound + 1;
        }
    }
    uint32_t s = vaddvq_u32(acc);
    for (; j < len; j++) {
        int d = (int)a[j] - (int)b[j];
        s += (uint32_t)(d < 0 ? -d : d);
        if (s > bound) return s;
    }
    return s;
}

#else
/* Scalar fallback */
uint32_t feature_l1_bounded_simd(const uint8_t *a, const uint8_t *b,
                                 int len, uint32_t bound) {
    uint32_t dist = 0;
    for (int j = 0; j < len; j++) {
        int d = (int)a[j] - (int)b[j];
        dist += (uint32_t)(d < 0 ? -d : d);
        if (dist > bound) return dist;
    }
    return dist;
}
#endif
