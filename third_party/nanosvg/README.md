# nanosvg

Mikko Mononen's NanoSVG: a small SVG parser and rasterizer in plain C (`nanosvg.h`, `nanosvgrast.h`, header-only). Tiger Build uses it to draw SVG pictures for the converter (attachments and `convert_file`), so a model can see an SVG as well as read its source.

- Source: https://github.com/memononen/nanosvg, commit `239e102ec2c691f2902e20ace2ed36ee4a35cfe6`, `nanosvg.h` has one change by Tiger Build (`objectBoundingBox.patch`: unitless gradient coordinates such as `x2="1"` are fractions of the shape, as the SVG standard says, instead of pixels); `nanosvgrast.h` is unchanged.
- License: zlib (see `LICENSE.txt`).
- What it draws: shapes, paths, strokes, fills, gradients, transforms, use/defs, clipping to the view box. What it does not draw: `<text>` (Tiger Build draws text itself, in `TBExtract.m`), filters, masks, CSS styles from `<style>` blocks beyond simple attributes, embedded images.
- The code that wraps it is `tiger-build/TBSVG.c`, compiled into `TBNet.c` like jxldec.
