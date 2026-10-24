/* src/core/money.c — 金额运算的 C 侧助手（Uya 没有 i128，只能在 C 侧做 128 位中间值）
 *
 * 约定：金额一律用 **整数 nano-USD**（1 USD = 1e9 nano），费率用 nano/1M tokens。
 * 所有函数对溢出返回饱和值（LLONG_MIN/LLONG_MAX），绝不静默回绕 —— 计费回绕比溢出更危险。
 */
#include <limits.h>

typedef __int128 i128;

static long long aigw_sat(i128 v) {
    if (v > (i128)LLONG_MAX) {
        return LLONG_MAX;
    }
    if (v < (i128)LLONG_MIN) {
        return LLONG_MIN;
    }
    return (long long)v;
}

/* (a * b) / c，向零取整；c <= 0 视为非法，返回 0。 */
long long aigw_mul_div(long long a, long long b, long long c) {
    if (c <= 0) {
        return 0;
    }
    return aigw_sat(((i128)a * (i128)b) / (i128)c);
}

/* (a * b) / c 四舍五入（half-up，绝对值）；c <= 0 返回 0。 */
long long aigw_mul_div_round(long long a, long long b, long long c) {
    if (c <= 0) {
        return 0;
    }
    i128 p = (i128)a * (i128)b;
    i128 half = (i128)c / 2;
    if (p >= 0) {
        return aigw_sat((p + half) / (i128)c);
    }
    return aigw_sat((p - half) / (i128)c);
}

/* tokens * rate(nano/1M tokens) / 1e6，四舍五入到 nano。 */
long long aigw_price_nano(long long tokens, long long rate_nano_per_mtok) {
    return aigw_mul_div_round(tokens, rate_nano_per_mtok, 1000000LL);
}

/* 按千分比阶梯定价：nano * permille / 1000（四舍五入）。 */
long long aigw_scale_permille(long long nano, long long permille) {
    return aigw_mul_div_round(nano, permille, 1000LL);
}

/* 两个 i64 相加，饱和。 */
long long aigw_add_sat(long long a, long long b) {
    i128 s = (i128)a + (i128)b;
    return aigw_sat(s);
}
