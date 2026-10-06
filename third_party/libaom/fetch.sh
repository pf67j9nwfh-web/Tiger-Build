#!/bin/sh
# Downloads libaom 3.11.0 (BSD-2-Clause with a patent grant, checked against its SHA-256), keeps the AV1 decoder's sources in src/, and writes
# config/, the generated headers for a plain C build (no assembly, no threads, 8 to 12 bits). Run on a current Mac with cmake:
# the old ones cannot download over modern TLS. AVIF pictures are AV1 frames in a HEIF file.
set -e
cd "$(dirname "$0")"
VERSION=3.11.0
SHA256=cf7d103d2798e512aca9c6e7353d7ebf8967ee96fffe9946e015bb9947903e3e
rm -rf src build config && mkdir src build
curl -fsSL -o src/libaom.tar.gz "https://storage.googleapis.com/aom-releases/libaom-$VERSION.tar.gz"
echo "$SHA256  src/libaom.tar.gz" | shasum -a 256 -c -
tar -xzf src/libaom.tar.gz -C src
rm src/libaom.tar.gz
mv "src/libaom-$VERSION" src/libaom
(cd build && cmake ../src/libaom -DAOM_TARGET_CPU=generic -DCONFIG_RUNTIME_CPU_DETECT=0 -DCONFIG_MULTITHREAD=0 -DCONFIG_AV1_ENCODER=0 \
  -DENABLE_DOCS=0 -DENABLE_EXAMPLES=0 -DENABLE_TESTS=0 -DENABLE_TOOLS=0 -DENABLE_TESTDATA=0 -DCONFIG_WEBM_IO=0 -DCONFIG_PIC=1 \
  -DCONFIG_AV1_HIGHBITDEPTH=1 -DCONFIG_LOWBITDEPTH=0 -DCONFIG_TUNE_VMAF=0 -DCONFIG_INSPECTION=0 -DCONFIG_ACCOUNTING=0 -DENABLE_NASM=0 \
  -DCONFIG_SIZE_LIMIT=1 -DDECODE_WIDTH_LIMIT=16384 -DDECODE_HEIGHT_LIMIT=16384 -DCMAKE_BUILD_TYPE=Release >/dev/null)
mkdir config
cp build/config/aom_config.h build/config/aom_config.c build/config/aom_dsp_rtcd.h build/config/aom_scale_rtcd.h build/config/av1_rtcd.h build/config/aom_version.h config/
# the generated headers were made on a little-endian Mac; the PowerPC slices are big-endian
sed -i '' 's/^#define CONFIG_BIG_ENDIAN 0/#ifdef __BIG_ENDIAN__\n#define CONFIG_BIG_ENDIAN 1\n#else\n#define CONFIG_BIG_ENDIAN 0\n#endif/' config/aom_config.h
rm -rf build include && mkdir -p include/aom
cp src/libaom/aom/aom.h src/libaom/aom/aom_codec.h src/libaom/aom/aom_decoder.h src/libaom/aom/aom_image.h src/libaom/aom/aom_integer.h src/libaom/aom/aom_frame_buffer.h src/libaom/aom/aomdx.h include/aom/
cp src/libaom/LICENSE LICENSE
cp src/libaom/PATENTS PATENTS
echo "libaom $VERSION is in third_party/libaom/src/libaom; its generated config is in third_party/libaom/config"
