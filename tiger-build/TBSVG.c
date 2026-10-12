/* SVG pictures for the converter: NanoSVG (third_party/nanosvg) parses the file and draws it into an RGBA bitmap. Compiled into TBNet.c, as jxldec is. */
#include <stdlib.h>
#include <string.h>
#include <math.h>

#define NANOSVG_IMPLEMENTATION
#define NANOSVG_ALL_COLOR_KEYWORDS
#include "../third_party/nanosvg/nanosvg.h"
#define NANOSVGRAST_IMPLEMENTATION
#include "../third_party/nanosvg/nanosvgrast.h"

#include "TBSVG.h"

/* Draws an SVG (UTF-8 text) so that its longer side is `longest` pixels, whatever size it declares. Returns malloc'd RGBA (not premultiplied, transparent where nothing is
   drawn) and its width and height, or NULL when the file is not an SVG that can be read or is empty. */
unsigned char *tb_svg_render(const char *svg, size_t length, int longest, int *width, int *height, float *scale_out)
{
    char *copy;
    NSVGimage *image;
    NSVGrasterizer *raster;
    unsigned char *pixels;
    float scale, big;
    int w, h;
    if (!svg || length == 0 || length > 20 * 1024 * 1024 || longest < 16)
        return NULL;
    copy = (char *)malloc(length + 1);
    if (!copy)
        return NULL;
    memcpy(copy, svg, length);
    copy[length] = 0;
    image = nsvgParse(copy, "px", 96.0f);     /* nsvgParse changes the text it is given */
    free(copy);
    if (!image)
        return NULL;
    if (image->width < 0.5f || image->height < 0.5f || image->shapes == NULL) {
        nsvgDelete(image);
        return NULL;
    }
    big = image->width > image->height ? image->width : image->height;
    scale = (float)longest / big;
    w = (int)(image->width * scale + 0.5f);
    h = (int)(image->height * scale + 0.5f);
    if (w < 1) w = 1;
    if (h < 1) h = 1;
    raster = nsvgCreateRasterizer();
    pixels = (unsigned char *)calloc((size_t)w * h, 4);
    if (!raster || !pixels) {
        if (raster) nsvgDeleteRasterizer(raster);
        free(pixels);
        nsvgDelete(image);
        return NULL;
    }
    nsvgRasterize(raster, image, 0, 0, scale, pixels, w, h, w * 4);
    nsvgDeleteRasterizer(raster);
    nsvgDelete(image);
    *width = w;
    *height = h;
    if (scale_out)
        *scale_out = scale;      /* pixels per unit of the drawing's own size */
    return pixels;
}
