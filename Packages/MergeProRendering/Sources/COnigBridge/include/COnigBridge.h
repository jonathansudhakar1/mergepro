#ifndef MP_ONIG_H
#define MP_ONIG_H
#include <stdint.h>
typedef struct MPScanner MPScanner;
typedef struct { int32_t start; int32_t end; } MPCapture;
MPScanner *mp_scanner_new(void);
int32_t mp_scanner_add(MPScanner *, const uint8_t *, int32_t);
/* Returns source index, -1 mismatch, or <= -2 structured error. */
int32_t mp_scanner_search(MPScanner *, const uint8_t *, int32_t, int32_t, int32_t, MPCapture *, int32_t, int32_t *);
void mp_scanner_free(MPScanner *);
#endif
