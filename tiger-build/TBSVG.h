#ifndef TBSVG_H
#define TBSVG_H
#include <stddef.h>
unsigned char *tb_svg_render(const char *svg, size_t length, int longest, int *width, int *height, float *scale);
#endif
