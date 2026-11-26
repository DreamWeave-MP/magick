# @magick 0.1.3

Pure-Luau raster toolkit for Jess. Backward-compatible with the 0.1.0 Morrowind generator surface while adding PNG/BMP/TGA I/O, atlas operations, image-processing math, gradients, masking, blur/shadow, grayscale/threshold/colorize, and the H3/H3UI dependency cone.

ImageMagick is used only as a development oracle; this package does not spawn it at runtime.

What 0.1.x promises consumers, and what it keeps as it always did, is in [COMPATIBILITY.md](COMPATIBILITY.md).

The renderer design for 0.2.0 (coordinates, transforms, premultiplied working tiles, compositing and the API boundaries) is proposed for ratification by review in [RFC-0001](docs/RFC-0001-renderer.md), with its checked sketches in `docs/rfc/sketches/`.

## 0.2.0, in development

Everything below is opt-in. A caller who uses only 0.1.x names gets the bytes 0.1.3 gave, except for the owner-approved
`Path:transformed` change recorded in [COMPATIBILITY.md](COMPATIBILITY.md#owner-approved-changes).

### `@magick/transform`

2x3 affine matrices in SVG's field order, `matrix(a b c d e f)` as `scaleX, skewY, skewX, scaleY, offsetX, offsetY`,
applied to column vectors. `multiply(first, second)` applies `second` first; `compose(T, S, R)` rotates, then scales,
then moves.

- `identity()`, `translate(x, y)`, `scale(x, y?)`, `rotate(radians)` (clockwise on screen), `skew(tanX, tanY?)`,
  `matrix(a, b, c, d, e, f)`.
- `multiply`, `compose`, `apply(m, x, y)`, `applyVector(m, x, y)`, `determinant`, `inverse`, `sigmaMax` (the largest
  stretch), `isIdentity`, `isSingular`, `check`, and `cubicBox(m, ...)`, the exact device box of a cubic.
- Every constructor refuses a NaN or infinite field (`magick: transform must be finite`). `inverse` refuses a matrix
  whose determinant is 0 or at most 1e-12 of the square of its largest linear entry (`magick: transform is singular`).

### Paths keep their curves

Each closed contour keeps the commands it was drawn with: points, quadratic and cubic curves, and the arcs of circles,
rings, rounded rectangles and round caps. `Path.contours` stays the 0.1.3 flattening at the path's tolerance.

- `Path:transformBy(matrix)`: a new path under a matrix, its curves flattened again where they land.
  `Path:transformed(scale, dx, dy)` is `transformBy(matrix(scale, 0, 0, scale, dx, dy))`.
- `path.flatten(path, tolerance?, matrix?)`: the closed contours as device-space point lists, the tolerance in device
  pixels (the path's own when left out). A chord strays from a quadratic by at most twice the tolerance, the 0.1.3
  piece-count formula, kept so legacy output does not move.
- `Path:deviceBounds(matrix?, halfWidth?)`: a box holding the exact curves (cubic and quadratic extrema, ellipse
  extremes on each arc) and the polygon they flatten to, widened by `halfWidth` times the matrix's largest stretch.
- Caps: `MaxPiecesPerCurve` 16384 pieces a curve, `MaxCommandsPerPath` 2^20, and every coordinate finite and within
  `MaxCoordinate` 2^22 when a 0.2.0 call flattens.

### Exact fill rules over any window

`Path:coverageIn(left, top, width, height, options?)` returns a `Mask` of the window's coverage bytes. Options:
`fillRule` (`nonzero`, the default, or `evenodd`), `transform` (a matrix, user to device), `tolerance` (device pixels)
and `clips` (at most `MaxClipDepth` 16 of `{ mask, left, top }`, multiplied in as `(coverage * clip + 127) // 255`).
An unknown option, fill rule or a window that is not whole numbers is refused by name.

- **Exact**: coverage is the area where the winding passes the rule, for crossing and overlapping contours too
  (RFC-0001 amendment A1). Legacy `Path:mask()` keeps the summed 0.1.3 rule; where no contours overlap the two agree
  within one step.
- **Tiles**: a window is the same bytes as that part of a larger window, so tiles rebuild a whole mask exactly.
  Scratch is one f64 row the window's width; geometry outside the window costs only its edges.
  `path.prepare(path, options?)` flattens and sorts once, and `path.coverOf(prepared, rule, left, top, width, height)`
  covers each tile from it.
- **Cost** (`bench/bench.jsl`, a 512 square, this machine, jess 0.4.0): the ring row is 2.1 ms against 1.5 ms for the
  0.1.3 mask; a row of many small shapes costs more (400 circles: 8.7 ms against 2.0 ms), since each crossing and
  vertex cuts the row. Known limitation, recorded rather than hidden.
- **Bounded**: exactness needs every crossing, so geometry that crosses itself densely inside one pixel row is
  refused rather than approximated: `path.MaxStripCrossings` (65,536) crossings, or `path.MaxStripWork` (2^22) pair
  tests and band steps, for one cluster of overlapping edges in one row raises before that work is done. Whether an
  outline is refused depends on the outline alone, never on the tiling. A 400-edge zigzag inside one row took 11.6 s
  before the caps and is now refused in milliseconds; 200 such edges cover exactly in 0.35 s.

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
