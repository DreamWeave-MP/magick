# @magick 0.1.3: compatibility contract

This is what consumers of `org.dreamweave.magick` 0.1.3 may rely on, and what a change must not
alter inside 0.1.x. It was written from the package as imported (commit `6206925`), with the
suites in `tests/` as the proof: `tests/compat.jsl` runs the examples here, and the goldens in
`tests/goldens.jsl` hold every operation to the bytes it gave at import.

Measured against: `jess` 0.3.0 (`jess_api = "1"` in `jess.toml`). Gates run on this checkout:

- `jess package test .`: 376 passed, 0 failed (each test counted once per provider; 274 before `tests/rfc.jsl`, which adds 102).
- `jess package check .`: no errors, strict types over every `.jsl`.
- `jess run --package . bench/bench.jsl`: all 91 workloads ran and held their fingerprints.

## Policy

- **Additions are free.** A new function, a new export, or a new optional parameter after the
  existing ones does not break anyone.
- **Anything listed here is the contract.** That covers each name, its parameters, what it
  returns, whether it mutates its argument, the byte layout of images and masks, and the error
  messages the suites pin. A change to any of them is breaking.
- **Quirks are contract too.** The legacy behavior in [Legacy compositing](#legacy-compositing-as-implemented)
  is kept as it is. A fix goes in as a clearly versioned opt-in, never as a silent change.
- **Exports consumers reach are contract, documented or not.** `magick.color` is undocumented
  and used by the Morrowind UI generator, so it stays.
- **Goldens are never regenerated to hide a regression.** A golden moves only when the change
  that moves it is deliberate and recorded in the release notes.
- **Performance is not contract, except the fingerprints.** Timings come from `BENCHMARKS.md`'s
  methodology. Every benchmark row is held to the output the package gave at import, so a faster
  path that does different work fails.

## Values

**Image.** A table with `width`, `height` and `data`, its metatable `Image`. `data` is a buffer of
`width * height * 4` bytes: RGBA, straight (not premultiplied) alpha, rows from the top, pixels
left to right. Treat `width` and `height` as read-only; the buffer must match them.

**Mask.** A table with `width`, `height` and `data`, and no metatable. `data` is a buffer of
`width * height` bytes, one byte of coverage a pixel, rows from the top. `Magick.mask` rejects a
buffer of any other length.

**Color.** Anything `Magick.new`, `fill` and the color arguments accept:

- a string: `#rgb`, `#rrggbb` or `#rrggbbaa`, with or without the `#`;
- an array of channels by position, `{ red, green, blue, alpha }`, where a missing color channel
  is 0 and a missing alpha is 255;
- a table of named channels `{ r, g, b, a }`, with the same defaults.

`magick.color` turns a color into its four channels, `{ red, green, blue, alpha }`.

Two inputs that look alike mean different things, and the difference is contract:

- `nil` (no color at all) is **transparent black**, `{ 0, 0, 0, 0 }`. `magick.new(w, h)` is clear.
- `{}` (an empty table) is **opaque black**, `{ 0, 0, 0, 255 }`. `magick.new(w, h, {})` is black.

`false` is not a color and is refused with `magick: color must be a table or hex string`.

**Source.** A color, or an `Image` repeated as a tile from its top left corner.

**Path.** `@magick/path` builds an outline in pixel coordinates (y down) and fills it with
anti-aliased coverage. `path:mask()` returns a `Mask` and the `left`, `top` of its bounds.

Path semantics that the rasterizer depends on, and that a rewrite of the path representation must
keep:

- **Rasterizing finalizes.** `path:mask()` closes the open contour, as `close` does, and
  `path:fill()` calls `mask()`, so it finalizes too. A contour of fewer than three points is
  dropped when it closes, and a path with nothing left gives a 0 by 0 mask at 0, 0.
- **Bounds read closed contours only.** `path:bounds()` covers the contours already closed, and
  is `0, 0, 0, 0` when there are none. An open contour is not counted until it closes.
- **`path:pen()`** returns a table of five functions, `moveTo`, `lineTo`, `quadTo`, `cubicTo` and
  `close`, that forward to the path and return nothing. A font reader or vector format draws
  through it.
- **`path.new(tolerance?)`** makes an empty path, flattening curves to within `tolerance` pixels,
  a quarter pixel by default. Every path carries the metatable the module exports as `path.Path`.

## Ownership and return values

Each function either makes a new image or mask, or changes its argument and returns it. Consumers
chain on the return value of the second kind, so it must stay `self`.

Changes its argument and returns `self`:

- `Image`: `fill`, `set`, `rect`, `rectOver`, `polygon`, `polygonOver`, `circle`, `over`,
  `overMask`, `copyAlpha`, `darken`, `screen`, `line`, `strokeRect`, `roundRect`, `grayscale`,
  `threshold`, `colorize`, `transparent`, `opaque`, `setAlpha`, `polynomial`, `contrastStretch`,
  `sigmoidalContrast`.
- `magick`: `modulate`, `emboss`, `tint`, each on the image it is given.
- `Path`: every builder (`moveTo`, `lineTo`, `quadTo`, `cubicTo`, `close`, `polygon`, `rect`,
  `circle`, `ring`, `roundRect`, `frame`, `line`, `polyline`, `append`). `append` adds the closed
  contours of another path to this one.

Makes a new image:

- `magick.new`, `magick.fromRGBA`, `magick.tile`, `magick.noise`, `magick.randomNoise`,
  `magick.verticalGradient`, `magick.maskToImage`, `magick.paintMask`, `magick.gaussianBlur`,
  `magick.mathCompose`, `magick.montage`, `magick.shadowed`, `magick.addGaussianNoise`, and every
  `magick.read*` codec.
- `clone`, `crop`, `extent`, `trim`, `rotate90`, `rotate`, `resize`, `resizeFit`, `roll`, `scale`.
- `Path:transformed(scale, dx, dy)`: a **new** `Path` whose closed contours are copied with each
  point moved to `point * scale + offset`. An open contour is **not** copied: a contour not yet
  closed is left out of the result entirely, and the result's bounds do not include it. The
  source is unchanged. Close a contour before transforming it.

Makes a new mask: `alphaMask`, `magick.dilateMask`, `magick.blurMask`, `magick.subtractMask`.

`magick.mask(width, height, bytes)` **wraps** `bytes` and does not copy: a later write to the
buffer changes the mask. `magick.fromRGBA(width, height, bytes)` **copies** the bytes, so the
image does not change when the buffer does. `clone` copies.

`magick.png(image)` and `magick.dds(image)` return the encoded file as a `buffer`.
`magick.write`, `magick.writePNG` and `magick.writeDDS` write a file and return its path as a
string.

## Errors

- **Argument errors** raise a string prefixed `magick:`. Those written with `error(..., 2)` name
  the caller's line; those written with `assert` name the package's own line. The message is what
  is contract. The messages the suites pin, and so keep, are:
  - `magick: integer image size required`: a size that is negative or not whole.
  - `magick: expected #rgb, #rrggbb, or #rrggbbaa`: a color string it cannot read.
  - `magick: RGBA byte length does not match geometry`: `fromRGBA` given the wrong length.
  - `magick: mask byte length mismatch`: `magick.mask` given the wrong length.
  - `magick: mask geometry mismatch`: `copyAlpha` given a mask of another size.
  - `magick: unknown alpha composite mode <mode>`: `copyAlpha` with a mode other than `dstin`,
    `dstout` or `copy`.
  - `magick: screen needs a whole offset`.
  - `magick: montage requires images`.
  - `magick: unsupported input format .<ext>` and `... output format .<ext>`: `read` and `write`
    take PNG, DDS, BMP and TGA to read and PNG and DDS to write.
  - Codec errors: `magick: not a PNG`, `not a BMP`, `not a DDS`, `truncated TGA`, `truncated PNG
    chunk`, `unsupported PNG color type <n>`, and the rest the codec suites name.
- **Path errors** name the call: `magick: path.<call> needs a moveTo first`.
- **File errors from `write`** come back as the filesystem's own message, raised at level 0.
- **Capabilities.** Reading a file by path needs `filesystem.read`, writing one needs
  `filesystem.write`. A runtime that does not grant them fails with the capability error, not a
  magick one. A missing file under a granted `filesystem.read` currently fails inside `readPNG`
  with a Luau type error (`invalid argument #1 to 'len'`). That message is not a promise; do not
  match on it.

Reads and writes outside an image are not errors: `get` returns four zeros, and `set` stores
nothing.

## Legacy compositing as implemented

These are kept on purpose. Each is pinned by a golden or a `compat` example.

- **Straight-alpha `over`.** A destination pixel's color is the alpha-weighted blend of the source
  and destination, and its alpha is the union `a_s + a_d * (1 - a_s)`, in bytes. A clear source
  pixel leaves the destination exactly as it was.
  `magick.new(1, 1, '#ff0000'):over(magick.new(1, 1, '#00ff0080'))` gives `127, 128, 0, 255`.
- **Rounding.** Colors round half up. `set` clamps each channel to a byte, then rounds.
- **Channels past a byte carry.** `magick.new(1, 1, { 300, 0, 0 })` is `44, 1, 0, 255`: 300 packs
  as 44 with 1 carried into green. A fraction is dropped when the pixel is stored.
- **`overMask` with a mask of another size** composites the overlap of the mask and the image and
  raises no error. `copyAlpha` does refuse it. Both are kept.
- **Offsets.** `over` and `darken` accept a fractional offset, and the result at a half pixel is
  pinned by a golden (`over by half a pixel`). The rule is not documented, so do not rely on a
  particular rounding. `screen` refuses a fractional offset.
- **`paintMask` and `overMask` scale** the mask's coverage by the color's alpha, so a half-covered
  byte under an opaque color is half opaque.
- **Fill rules differ by module.** `Image:polygon` fills by even-odd, `Image:circle` by each pixel's
  center, and `@magick/path` by the winding the contours add up to, clamped to whole. In a path, a
  `ring` or `frame` winds its inner contour the other way and so is a hole.

## Undocumented but exported

These have no doc comment or are not in the README, and consumers call some of them. They are
contract as listed here, not as a promise that they are the best shape.

- `magick.color`: colors as channels; used by `st4sh-scripts` for settings.
- `magick.Image`: the metatable `Image`. Its methods are the `Image` methods above.
- `magick.new`, `magick.fromRGBA`, `Image.fill`, `Image.clone`, `magick.writeDDS`,
  `magick.writePNG`, `magick.verticalGradient`: exported with no doc comment.
- `magick.stats`: returns `{ width, height, mean, nonzeroAlpha }`, where `mean` is the array
  `{ red, green, blue, alpha }` of each channel's average.
- `Image:median()`: the gray level half of the pixels lie at or below.
- `Image:get(column, row)` returns four numbers. `Image:set(column, row, red, green, blue, alpha)`
  takes a pixel and returns the image.

The types `Image`, `Mask`, `Color` and `Source` are exported as Luau types, not values. Consumers
use `magick.Color`, `magick.Source` and `magick.Mask` as type annotations.

## What consumers call

These are the consumers the contract is written for: `st4sh-scripts` (the Morrowind UI, H3, and
the cod3x and atlas generators) and `dream_propaganda` (the poster and banner templates). The
methods they call most, counted as occurrences of each call across `st4sh-scripts/src`,
`st4sh-scripts/tests` and `dream_propaganda/src` at the time of writing, are `over` (47), `new` (34), `rectOver` (24), `rect` (20), `crop` (19), `write`
(16), `strokeRect` (14), `line` (14), `fill` (14), `read` (13), `circle` (12), `roundRect` (10),
`resize` (9), `polygon` (9), `frame` (8), `clone` (8), `transformed` (7), `png` (7), `paintMask`
(6), `blurMask` (6), `grayscale` (6), `tile` (5), `ring` (4), `polygonOver` (4), `pen` (4),
`maskToImage` (4), `mask` (4), `copyAlpha` (4), `rotate90` (3), `rotate` (3), `resizeFit` (3),
`noise` (3), `color` (3), `addGaussianNoise` (3), `screen` (2), `scale` (2), `shadowed` (2),
`get` (2), `bounds` (2), `append` (2).

`st4sh-scripts`' Morrowind UI is the source of the pinned call shapes in `tests/compat.jsl`:
`color`, a spiral resized and cropped into a frame, `paintMask` with a color and with a tile,
`resizeFit`, and `noise` from a seed. H3 contributes `montage`, `polygonOver`, `rectOver`,
`shadowed` offset under a crowbar, and `threshold` on random noise.

The methods in that count that are not on this package's surface, such as `:measure` and
`:outline`, belong to the font package. They are not part of this contract.

## Breaking-change candidates

Each of these would break a consumer, so none happens inside 0.1.x:

- making `fromRGBA` share its bytes, or `magick.mask` copy them;
- making `new` ignore a color, or `get` read anything but zeros outside the image;
- changing `over` to premultiplied alpha, or changing a rounding rule;
- making `overMask` refuse a mismatched mask, or `copyAlpha` accept one;
- changing the `paintMask` alpha scaling, or the fill winding of a shape;
- removing or renaming `magick.color` or any name in the consumer list above;
- changing an error message a suite pins;
- making `Path:transformed` change its source, or `mask` and `fill` leave an open contour open;
- making `Path:bounds` count an open contour, or `color(nil)` and `color({})` mean the same thing.

A change that needs any of these goes into a new minor version as an opt-in, with the old
behavior kept under its old name.

## Where the proof lives

- `tests/basic.jsl`: every operation on seeded fixtures, held to the goldens in
  `tests/goldens.jsl` (the geometry and CRC-32 of each result, as imported).
- `tests/png.jsl`, `tests/path.jsl`, `tests/resample.jsl`: the codecs, paths and resampling.
- `tests/compat.jsl`: the examples in this document, and the consumer call shapes.
- `tests/style.jsl`: `@jess/style` over the payload.
- `bench/bench.jsl`: every workload, held to its fingerprint; methodology and the reference table
  are in `BENCHMARKS.md`.
