# Benchmarks

`bench/bench.luau` times @magick through its public API on images the size of a UI texture or a
page's picture: 512 by 512 for most rows and 256 by 256 for the heavier ones, a 64 by 64 tile,
and codec inputs built byte by byte so that a decoder meets the filters and layouts other
encoders write. Ten rows are small on purpose: glyphs of 12 by 16, an icon of 16 by 16 and
rectangles one to three pixels wide, where what an operation sets up before its first pixel is
most of what it costs. Each workload is warmed up, sized to about a tenth of a second a batch,
and reported as the median of seven batches with a full collection before each. Every result is
held, outside the time, to the fingerprint the package gave as imported (the CRC-32 of the
pixels, or of the file), so a path that stopped doing the work, or does other work, fails
instead of posting a time.

```sh
jess run --package jpk/magick jpk/magick/bench/bench.luau [filter]
```

It refuses a build without the verified toolchain.

## l3i 2.0: before and after

2026-10-13, Intel Core i7-10870H @ 2.20GHz, a verified release build of Jess on l3i 2.0.2 (Luau
0.742). Base is `7dba003`, the package as imported with its pinning tests, given this bench as
it now is; head is `e6f929c`. Same binary for both, by turns (base, head, head, base, base,
head) inside one hold of the machine's bench lock, each run as

```sh
systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 \
  target/l3i2/jess run --package <the base's export, or jpk/magick> --package-path jpk <its bench/bench.luau>
```

Each cell is the median of the three runs' medians. Other agents' work shared the machine, so a
difference under about 5 percent is noise and reads "no change". The second set of columns is
the same A/B run again with `MALLOC_TRIM_THRESHOLD_` and `MALLOC_MMAP_THRESHOLD_` at 1 GiB on
both sides: a workload that allocates a megabyte a call flips between two speeds with glibc's
trimming, and with the heap kept those rows show the package and not the allocator. `clone` is
the plain case: its code did not change, and with the heap kept it reads 67.7 against 67.1 µs.

This table was measured twice, by the agent that made the change and again by the one that
reviewed it; the 75 rows both measured agree within noise. `get and set every pixel` is the
loosest row: its head runs read 4.0 to 5.3 ms, so it is 1.2x to 1.3x.

| Workload | Base | Head | Base / head | Base, heap kept | Head, heap kept | Base / head |
|---|---:|---:|---:|---:|---:|---:|
| new filled | 680.3 µs | 218.4 µs | 3.11x | 652.7 µs | 63.5 µs | 10.3x |
| fill | 644.9 µs | 62.8 µs | 10.3x | 652.5 µs | 62.1 µs | 10.5x |
| rect color | 491.6 µs | 63.4 µs | 7.76x | 490.1 µs | 64.5 µs | 7.60x |
| rect tiled | 15.75 ms | 80.6 µs | 196x | 16.41 ms | 81.7 µs | 201x |
| tile | 25.00 ms | 259.4 µs | 96.4x | 24.94 ms | 97.1 µs | 257x |
| polygon | 17.94 ms | 632.2 µs | 28.4x | 17.59 ms | 644.3 µs | 27.3x |
| polygon tiled | 8.62 ms | 914.1 µs | 9.43x | 8.63 ms | 917.1 µs | 9.41x |
| polygonOver | 21.69 ms | 1.54 ms | 14.1x | 21.28 ms | 1.52 ms | 14.0x |
| circle | 10.54 ms | 288.8 µs | 36.5x | 10.10 ms | 289.8 µs | 34.8x |
| rectOver color | 20.44 ms | 1.27 ms | 16.1x | 19.30 ms | 1.29 ms | 15.0x |
| rectOver tiled | 7.04 ms | 236.9 µs | 29.7x | 6.91 ms | 233.1 µs | 29.7x |
| roundRect | 2.75 ms | 102.8 µs | 26.8x | 2.57 ms | 100.3 µs | 25.6x |
| line and strokeRect | 477.3 µs | 114.7 µs | 4.16x | 470.3 µs | 109.9 µs | 4.28x |
| get and set every pixel | 5.23 ms | 4.00 ms | 1.31x | 5.30 ms | 4.50 ms | 1.18x |
| over opaque | 1.33 ms | 342.8 µs | 3.87x | 1.32 ms | 342.3 µs | 3.84x |
| over sprite | 1.52 ms | 1.19 ms | 1.28x | 1.52 ms | 1.16 ms | 1.32x |
| over soft | 6.52 ms | 4.85 ms | 1.35x | 6.37 ms | 4.74 ms | 1.34x |
| over offset | 4.85 ms | 3.58 ms | 1.35x | 4.81 ms | 3.59 ms | 1.34x |
| overMask opaque color | 1.31 ms | 1.18 ms | 1.11x | 1.32 ms | 1.18 ms | 1.12x |
| overMask soft color | 5.05 ms | 4.00 ms | 1.26x | 5.17 ms | 4.08 ms | 1.27x |
| copyAlpha dstin | 8.25 ms | 427.9 µs | 19.3x | 8.68 ms | 441.6 µs | 19.6x |
| copyAlpha copy | 7.44 ms | 102.5 µs | 72.6x | 7.95 ms | 101.7 µs | 78.2x |
| darken | 6.44 ms | 589.4 µs | 10.9x | 6.76 ms | 588.9 µs | 11.5x |
| mathCompose | 11.99 ms | 1.44 ms | 8.35x | 11.62 ms | 1.41 ms | 8.23x |
| extent | 7.26 ms | 4.88 ms | 1.49x | 7.07 ms | 4.76 ms | 1.49x |
| montage | 349.0 µs | 133.6 µs | 2.61x | 341.7 µs | 129.8 µs | 2.63x |
| clone | 226.9 µs | 206.6 µs | 1.10x | 67.7 µs | 67.1 µs | no change |
| crop | 65.4 µs | 66.4 µs | no change | 35.8 µs | 35.9 µs | no change |
| trim | 9.87 ms | 248.8 µs | 39.7x | 10.15 ms | 230.1 µs | 44.1x |
| rotate90 | 22.96 ms | 1.15 ms | 20.0x | 23.10 ms | 1.07 ms | 21.6x |
| rotate | 14.81 ms | 2.71 ms | 5.46x | 14.71 ms | 2.75 ms | 5.35x |
| resize nearest | 3.33 ms | 285.1 µs | 11.7x | 3.27 ms | 281.0 µs | 11.6x |
| resize down | 5.04 ms | 2.20 ms | 2.29x | 5.16 ms | 2.24 ms | 2.30x |
| resize up | 14.55 ms | 6.38 ms | 2.28x | 14.88 ms | 6.49 ms | 2.29x |
| roll | 23.09 ms | 262.1 µs | 88.1x | 24.28 ms | 106.5 µs | 228x |
| alphaMask | 763.3 µs | 386.5 µs | 1.97x | 756.5 µs | 379.5 µs | 1.99x |
| maskToImage | 2.26 ms | 1.06 ms | 2.13x | 2.28 ms | 1.04 ms | 2.19x |
| paintMask color | 10.22 ms | 265.2 µs | 38.5x | 9.90 ms | 263.7 µs | 37.6x |
| paintMask tiled | 2.99 ms | 759.7 µs | 3.94x | 2.98 ms | 766.6 µs | 3.88x |
| dilateMask 1 | 6.33 ms | 596.1 µs | 10.6x | 6.14 ms | 583.8 µs | 10.5x |
| dilateMask 3 | 27.05 ms | 1.71 ms | 15.8x | 27.70 ms | 1.76 ms | 15.7x |
| blurMask | 7.22 ms | 4.31 ms | 1.67x | 7.37 ms | 4.36 ms | 1.69x |
| subtractMask | 566.8 µs | 121.3 µs | 4.67x | 583.7 µs | 119.4 µs | 4.89x |
| modulate | 5.69 ms | 725.6 µs | 7.84x | 5.81 ms | 734.6 µs | 7.91x |
| emboss | 10.10 ms | 998.2 µs | 10.1x | 10.18 ms | 993.4 µs | 10.3x |
| tint | 5.85 ms | 1.00 ms | 5.84x | 5.93 ms | 1.02 ms | 5.84x |
| grayscale | 2.35 ms | 1.42 ms | 1.65x | 2.35 ms | 1.44 ms | 1.63x |
| threshold | 2.11 ms | 1.45 ms | 1.45x | 2.11 ms | 1.48 ms | 1.43x |
| colorize | 6.47 ms | 1.42 ms | 4.56x | 6.41 ms | 1.43 ms | 4.48x |
| transparent | 15.28 ms | 1.13 ms | 13.5x | 15.30 ms | 1.12 ms | 13.7x |
| opaque | 15.55 ms | 1.18 ms | 13.2x | 15.32 ms | 1.15 ms | 13.3x |
| setAlpha | 20.51 ms | 103.8 µs | 198x | 20.31 ms | 104.5 µs | 194x |
| polynomial | 6.62 ms | 1.40 ms | 4.71x | 6.55 ms | 1.43 ms | 4.57x |
| contrastStretch | 8.83 ms | 880.5 µs | 10.0x | 8.90 ms | 892.3 µs | 9.97x |
| sigmoidalContrast | 8.95 ms | 353.9 µs | 25.3x | 8.85 ms | 356.0 µs | 24.9x |
| median | 3.46 ms | 522.4 µs | 6.63x | 3.35 ms | 539.7 µs | 6.20x |
| stats | 10.89 ms | 1.38 ms | 7.92x | 11.08 ms | 1.36 ms | 8.16x |
| noise | 6.70 ms | 1.97 ms | 3.39x | 6.58 ms | 2.02 ms | 3.27x |
| randomNoise | 4.40 ms | 615.5 µs | 7.15x | 4.56 ms | 615.7 µs | 7.41x |
| addGaussianNoise | 13.70 ms | 4.77 ms | 2.87x | 13.85 ms | 4.85 ms | 2.86x |
| verticalGradient | 769.3 µs | 225.7 µs | 3.41x | 742.9 µs | 200.1 µs | 3.71x |
| gaussianBlur 1.5 | 19.49 ms | 8.20 ms | 2.38x | 19.74 ms | 8.43 ms | 2.34x |
| gaussianBlur 12 | 108.52 ms | 46.93 ms | 2.31x | 111.49 ms | 47.55 ms | 2.34x |
| shadowed | 65.14 ms | 8.00 ms | 8.15x | 66.74 ms | 8.14 ms | 8.20x |
| overMask glyphs | 21.3 µs | 19.9 µs | 1.07x | 21.4 µs | 19.7 µs | 1.08x |
| overMask soft glyphs | 39.5 µs | 33.1 µs | 1.19x | 38.5 µs | 32.6 µs | 1.18x |
| maskToImage glyph | 2.12 µs | 1.76 µs | 1.20x | 2.03 µs | 1.75 µs | 1.16x |
| paintMask glyph | 15.0 µs | 5.40 µs | 2.79x | 14.4 µs | 5.28 µs | 2.74x |
| threshold icon | 1.81 µs | 1.70 µs | 1.07x | 1.79 µs | 1.70 µs | 1.05x |
| colorize icon | 6.61 µs | 2.90 µs | 2.28x | 6.56 µs | 2.89 µs | 2.27x |
| polynomial icon | 6.01 µs | 2.97 µs | 2.02x | 5.94 µs | 2.97 µs | 2.00x |
| strokeRect border | 2.79 µs | 2.68 µs | no change | 2.73 µs | 2.66 µs | no change |
| rect columns | 9.39 µs | 8.50 µs | 1.10x | 9.23 µs | 8.42 µs | 1.10x |
| verticalGradient icon | 2.13 µs | 1.89 µs | 1.12x | 2.06 µs | 1.84 µs | 1.12x |
| png | 6.56 ms | 6.46 ms | no change | 6.64 ms | 6.50 ms | no change |
| png stored | 1.43 ms | 1.41 ms | no change | 1.38 ms | 1.38 ms | no change |
| readPNG unfiltered | 8.34 ms | 915.2 µs | 9.11x | 8.38 ms | 888.8 µs | 9.43x |
| readPNG filtered rgba | 9.74 ms | 2.01 ms | 4.85x | 9.86 ms | 1.96 ms | 5.03x |
| readPNG filtered rgb | 8.02 ms | 1.76 ms | 4.56x | 8.19 ms | 1.75 ms | 4.69x |
| readPNG filtered gray | 4.72 ms | 974.0 µs | 4.85x | 4.75 ms | 964.0 µs | 4.93x |
| dds | 10.36 ms | 638.3 µs | 16.2x | 10.32 ms | 601.9 µs | 17.1x |
| readDDS | 12.91 ms | 643.5 µs | 20.1x | 13.59 ms | 608.8 µs | 22.3x |
| readBMP | 13.06 ms | 919.8 µs | 14.2x | 13.15 ms | 870.8 µs | 15.1x |
| readTGA | 15.68 ms | 647.3 µs | 24.2x | 15.58 ms | 622.1 µs | 25.0x |
| readTGA packets | 14.67 ms | 1.82 ms | 8.06x | 14.92 ms | 1.67 ms | 8.95x |

The package was written as a `get` and a `set` for each pixel, with a color parsed again for
each pixel of a shape and a closure made for each pixel of a blend. Most of the table is that
going away: an operation reads and writes whole pixels in the buffer, and what does not depend
on the pixel is worked out once.

- **Block copies.** A fill is doubling copies of its first pixel (`fill` 10x, `rect` 8x, a
  gradient's rows 3.4x); a tile, a roll and a rectangle of a tile are copies of runs of rows
  (90x to 250x); `over` copies a row that is all opaque and skips one that is all clear, each
  found by one data-plane test over the row's pixels (`over opaque` 3.9x, `montage` 2.6x).
- **The data plane.** `setAlpha` is one strided `fill` (200x) and `copyAlpha` in copy mode one
  strided `scale` (73x); a quarter turn scatters each row down a column (20x) and a
  nearest-pixel resize gathers each row through one index vector (12x); `trim` asks `any` of
  whole rows and columns (40x); `stats` is four sums and a count (7.9x); the PNG filters that
  add the pixel before or the row above are one `add` a row.
- **Tables.** A curve over a channel (`colorize`, `polynomial`, `contrastStretch`,
  `sigmoidalContrast`: 4.6x to 25x), a mask painted in a color and a threshold are tables of
  256 entries for the most part, looked up per pixel.
- **No branch in the loop.** Native Luau pays for a branch far more than for arithmetic: the
  clamp of a channel went through `math.clamp`, a choice between two results became a
  multiplication by 0 or 1, and a blend of bytes, which cannot leave a byte's range, is rounded
  with no clamp at all. That alone is the 1.3x of `over soft` and of `overMask`, and half of the
  2.3x of the bilinear resize. Measured on its own at 256 by 256, in one paired run, the clamp
  through `math.clamp` against the comparing one it replaced, everything else as it is at head:
  `modulate` 715 µs against 2.03 ms, `emboss` 981 µs against 2.19 ms, `tint` 988 µs against
  1.92 ms, `mathCompose` 1.43 against 3.14 ms, `copyAlpha` 431 against 968 µs. It is also the
  one change a caller can tell on a channel that is not a number: `set` given a string refuses
  it in `math.clamp`'s words where it refused it in the comparison's, and takes a string of
  digits for its number where it refused that too.
- **The blur** sums a whole row of sums at a time, four taps to a pass, where it summed every
  tap of one pixel before the next (2.3x); a shadow blurs only the alpha it uses (8x).
- **Codecs.** A decoded row is copied or converted whole, where every pixel went through `set`:
  PNG 4.6x to 9.1x, of which what is left is `inflate`; DDS, BMP and TGA 8x to 24x.

What did not move: `png` is `deflate` (stored without it, the same file takes 1.4 ms of the
6.5), `crop` and `clone` were block copies already, and `get` and `set` themselves are bounded
by the call (1.2x to 1.3x, from the clamp).
The smallest gains are where the arithmetic is the work: compositing soft pixels, `overMask`,
`blurMask`, `grayscale` and `threshold`.

Tried and not kept: the blur through the data plane (`scale` and `add` over rows of f64 measured
3.7 ns a tap against the 1.2 ns of the loop that shipped); `over` testing runs of 64 pixels
inside a mixed row (the tests cost more than they saved, and soft images lost 14 percent); a
compositing loop without branches (29 ns a pixel against 25 for soft pixels and 6 for a sprite's);
a typed slice for `alphaMask` (slower than the loop it replaced); and Paeth by a carried local a
channel (slower than reading the three neighbors).

## Small images

A table of 256 entries filled for one call, and a copy that is a call, are what make a texture
fast and what made a glyph slow. As first moved onto l3i 2.0 (`80f6a62`) the package had no
small rows in its bench, and on them it was slower than the import. Review added the ten rows
and measured, three rounds by turns under the lock (medians, base then that head):

| Workload | Base | `80f6a62` | Base / head | What it was |
|---|---:|---:|---:|---|
| overMask glyphs (16 glyphs) | 21.3 µs | 54.6 µs | 0.39x | a table of 256 alphas filled for every glyph |
| overMask soft glyphs | 38.7 µs | 68.7 µs | 0.56x | the same |
| maskToImage glyph | 2.08 µs | 3.34 µs | 0.62x | a table of 256 pixels for 192 |
| threshold icon | 1.81 µs | 4.98 µs | 0.36x | 766 sums tested for 256 pixels |
| colorize icon | 6.63 µs | 8.31 µs | 0.80x | three tables of 256 for 256 pixels |
| verticalGradient icon | 2.14 µs | 3.25 µs | 0.66x | four copies to double one pixel into a row of 16 |
| strokeRect border | 2.79 µs | 5.49 µs | 0.51x | a copy of four bytes for every row of a side |
| rect columns | 10.1 µs | 18.7 µs | 0.54x | the same, twelve bytes |

Each has its own commit after `80f6a62`, and the main table above is the result: `overMask`
keeps its table from one call to the next and fills it again only for another alpha; a
threshold's table is one fill from the sum where white begins, found by halving; `colorize` and
`maskToImage` work an image of under 1024 pixels out a pixel at a time; a fill of up to 64
pixels, and a rectangle up to eight wide, store their pixels one by one. None of it moved a
large row. Both modules side by side in one process, at 8 by 8, 16 by 16, 32 by 32 and 64 by 64,
over 65 operations: at 16 and up nothing is slower than the import; at 8 by 8 three still are,
by a fraction of a microsecond: `threshold` (0.52 against 0.75 µs: its table is 766 bytes
whatever the image), `polynomial` (1.67 against 2.12 µs: a table of 256 for 64 pixels) and
`over` of an opaque image (0.74 against 0.81 µs: a data-plane call a row).

## One dependent's generators

`st4sh-scripts` has no tests, and `dreamweave-mod-template` names a test file it does not have,
so three of `st4sh-scripts`' generators were run against the base and the head, five rounds by
turns under the bench lock: the Morrowind UI generator (318 DDS files), COD3X (4 PNG files) and
the H3 chrome sources (12 files) from one 640 by 600 PNG as their material. All 334 files are
byte for byte the same. Medians: the UI generator 0.75 s with the base and 0.42 s with the head;
COD3X 0.13 and 0.12 s, no change; H3 0.85 and 0.29 s; the whole process 1.82 s and 0.92 s.

## Cold load

Requiring the module in a fresh process, eleven rounds by turns under the bench lock, median:

| | Require |
|---|---:|
| Base | 25.0 ms |
| Head | 34.0 ms |

The module is three times the code it was, compiled natively when it loads, and that is most of
the 9 ms: a script that requires @magick for one small operation is slower by it. The rest is
the dialect: thirteen buffer sinks, a comprehension, a reducer and a slice, 0.1 to 0.2 ms each
as measured at `2eea8e0` (32.5 ms with them, 29.4 ms with each written as a loop), kept because
each is one table of 256 entries or a kernel said in a line. Eleven reductions over buffer
slices were not kept: they measured 0.53 ms of load each (5.9 ms together; the module took
38.4 ms to require with them), and the explicit data-plane call each lowers to is as fast or
faster once the module is loaded. Record patterns cost nothing to load.
