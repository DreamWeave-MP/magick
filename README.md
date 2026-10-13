# @magick 0.1.2

Pure-Luau raster toolkit for Jess. Backward-compatible with the 0.1.0 Morrowind generator surface while adding PNG/BMP/TGA I/O, atlas operations, image-processing math, gradients, masking, blur/shadow, grayscale/threshold/colorize, and the H3/H3UI dependency cone.

ImageMagick is used only as a development oracle; this package does not spawn it at runtime.


## 0.1.2 lab changes

The hot raster paths operate directly on packed RGBA buffers. `Image:overMask(mask, color, dx?, dy?)` composites a one-byte alpha mask directly into an image without materializing a temporary RGBA image. This is especially useful for glyph/logo masks and generated-site assets.
