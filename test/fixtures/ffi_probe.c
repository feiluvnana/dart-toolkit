// Functions libc has no clean example of, compiled by test/ffi_test.dart when a `cc` is on the PATH.
#include <stdint.h>

int64_t sum8(int64_t a, int64_t b, int64_t c, int64_t d, int64_t e, int64_t f, int64_t g, int64_t h) {
  return a + 10 * b + 100 * c + 1000 * d + 10000 * e + 100000 * f + 1000000 * g + 10000000 * h;
}

double mixed(double a, int32_t b, double c, int64_t d) { return a + 10 * b + 100 * c + 1000 * d; }

float halff(float x) { return x / 2; }

int32_t from8(int8_t x) { return x; }

int32_t fromu8(uint8_t x) { return x; }

int64_t call2(int64_t (*cb)(int32_t, int32_t), int32_t a, int32_t b) { return cb(a, b); }

intptr_t call0(intptr_t (*cb)(void)) { return cb(); }
