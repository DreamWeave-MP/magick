# @magick 0.1.3

Pure-Luau raster toolkit for Jess. Backward-compatible with the 0.1.0 Morrowind generator surface while adding PNG/BMP/TGA I/O, atlas operations, image-processing math, gradients, masking, blur/shadow, grayscale/threshold/colorize, and the H3/H3UI dependency cone.

ImageMagick is used only as a development oracle; this package does not spawn it at runtime.

What 0.1.x promises consumers, and what it keeps as it always did, is in [COMPATIBILITY.md](COMPATIBILITY.md).

## Gates

`tests/gate.jsl` holds the package to tiny exact fixtures (transparency, clipping, alpha, curves,
holes, gradients, line caps), to the reference scenes of `tests/scenes.jsl` at the pixels their
comments derive, to empty and one-pixel-wide images, and to the value of grayscale and setAlpha at
those sizes. Every value is exact except area: a flattened curve or circle is compared with its
analytic area within a quarter pixel, declared in the suite. That is a coarse check, since a shift
of a fraction of a pixel moves an area by less than a quarter pixel. The exact pixels and the scene
fingerprints are what catch a small shift. `jess package test .` writes nothing.

`tools/gallery.jsl` renders the same scenes to PNG and compares them with recorded checksums and
baseline files. Where the sizes match it reports the first differing pixel; where they do not, it reports
the geometry and the first differing byte. It needs both filesystem capabilities, and
re-baselining is an explicit `rebaseline` run whose output is reviewed. The commands are in
[BENCHMARKS.md](BENCHMARKS.md#gates).

## 0.1.3 changes

`@magick/path` fills shapes with anti-aliased coverage: polygons, rectangles (rounded or as frames), ellipses, rings, lines and polylines with butt, round or square caps, and contours of lines, quadratic and cubic curves. Coverage is worked out exactly for the flattened outline, so a pixel an edge halves is half covered. Contours that wind the same way join; one that winds the other way cuts a hole. `Path:mask()` gives the coverage and where it lies; `Path:fill(image, color)` composites a color through it. `Path:pen()` hands the path to code that draws outlines through plain functions, such as a font reader.

`Image:screen(source, dx?, dy?)` composites by screening, ImageMagick's `Screen`: black leaves what is under it alone. `Image:scale(width, height)` resamples by area, ImageMagick's `-scale`, weighing each pixel by how much of it is covered and by its alpha.

## 0.1.2 lab changes

The hot raster paths operate directly on packed RGBA buffers. `Image:overMask(mask, color, dx?, dy?)` composites a one-byte alpha mask directly into an image without materializing a temporary RGBA image. This is especially useful for glyph/logo masks and generated-site assets.
