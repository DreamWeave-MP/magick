# Benchmarks

`bench/bench.luau` times @magick through its public API on images the size of a UI texture or a
page's picture: 512 by 512 for most rows and 256 by 256 for the heavier ones, a 64 by 64 tile,
and codec inputs built byte by byte so that a decoder meets the filters and layouts other
encoders write. Each workload is warmed up, sized to about a tenth of a second a batch, and
reported as the median of seven batches with a full collection before each. Every result is
held, outside the time, to the fingerprint the package gave as imported (the CRC-32 of the
pixels, or of the file), so a path that stopped doing the work, or does other work, fails
instead of posting a time.

```sh
jess run --package jpk/magick jpk/magick/bench/bench.luau [filter]
```

It refuses a build without the verified toolchain.

## l3i 2.0: before and after

2026-10-12, Intel Core i7-10870H @ 2.20GHz, a verified release build of Jess on l3i 2.0.2 (Luau
0.742). Base is `7dba003`, the package as imported with this bench and its pinning tests added;
head is `2eea8e0`. Same binary for both, base then head, three rounds back to back inside one
hold of the machine's bench lock, each run as

```sh
systemd-run --user --scope -q -p MemoryMax=3G -p MemorySwapMax=0 \
  target/l3i2/jess run --package <the base's export, or jpk/magick> --package-path jpk <its bench/bench.luau>
```

Each cell is the median of the three runs' medians. Other agents' work shared the machine, so a
difference under about 5 percent is noise and reads "no change". The second set of columns is
the same A/B run again with `MALLOC_TRIM_THRESHOLD_` and `MALLOC_MMAP_THRESHOLD_` at 1 GiB on
both sides: a workload that allocates a megabyte a call flips between two speeds with glibc's
trimming, and with the heap kept those rows show the package and not the allocator. `clone` is
the plain case: its code did not change, its three base rounds read 80, 219 and 245 µs, and
with the heap kept it reads 72 against 67.

| Workload | Base | Head | Base / head | Base, heap kept | Head, heap kept | Base / head |
|---|---:|---:|---:|---:|---:|---:|
| new filled | 714.5 µs | 226.1 µs | 3.16x | 658.8 µs | 61.5 µs | 10.7x |
| fill | 703.4 µs | 63.6 µs | 11.1x | 655.6 µs | 60.6 µs | 10.8x |
| rect color | 501.6 µs | 62.4 µs | 8.04x | 498.4 µs | 62.1 µs | 8.02x |
| rect tiled | 16.48 ms | 81.9 µs | 201x | 16.35 ms | 82.5 µs | 198x |
| tile | 25.47 ms | 281.1 µs | 90.6x | 24.96 ms | 97.3 µs | 257x |
| polygon | 18.24 ms | 631.7 µs | 28.9x | 17.88 ms | 643.4 µs | 27.8x |
| polygon tiled | 8.83 ms | 913.1 µs | 9.67x | 8.71 ms | 906.0 µs | 9.61x |
| polygonOver | 21.78 ms | 1.58 ms | 13.8x | 21.33 ms | 1.50 ms | 14.2x |
| circle | 10.59 ms | 290.7 µs | 36.4x | 10.28 ms | 287.6 µs | 35.8x |
| rectOver color | 20.18 ms | 1.29 ms | 15.7x | 19.59 ms | 1.27 ms | 15.4x |
| rectOver tiled | 7.05 ms | 237.1 µs | 29.8x | 6.99 ms | 237.6 µs | 29.4x |
| roundRect | 2.75 ms | 101.0 µs | 27.2x | 2.62 ms | 101.1 µs | 25.9x |
| line and strokeRect | 505.5 µs | 136.3 µs | 3.71x | 478.8 µs | 141.2 µs | 3.39x |
| get and set every pixel | 5.38 ms | 4.09 ms | 1.32x | 5.53 ms | 4.05 ms | 1.36x |
| over opaque | 1.36 ms | 344.7 µs | 3.95x | 1.34 ms | 345.1 µs | 3.89x |
| over sprite | 1.58 ms | 1.20 ms | 1.31x | 1.53 ms | 1.19 ms | 1.29x |
| over soft | 6.69 ms | 4.99 ms | 1.34x | 6.28 ms | 4.80 ms | 1.31x |
| over offset | 4.97 ms | 3.69 ms | 1.35x | 4.66 ms | 3.67 ms | 1.27x |
| overMask opaque color | 1.37 ms | 1.17 ms | 1.17x | 1.32 ms | 1.18 ms | 1.11x |
| overMask soft color | 5.46 ms | 4.09 ms | 1.34x | 5.09 ms | 4.00 ms | 1.27x |
| copyAlpha dstin | 8.30 ms | 445.1 µs | 18.6x | 8.42 ms | 439.7 µs | 19.1x |
| copyAlpha copy | 7.85 ms | 102.6 µs | 76.5x | 7.74 ms | 102.7 µs | 75.3x |
| darken | 6.74 ms | 603.3 µs | 11.2x | 6.77 ms | 594.4 µs | 11.4x |
| mathCompose | 12.57 ms | 1.48 ms | 8.51x | 12.04 ms | 1.44 ms | 8.35x |
| extent | 7.40 ms | 5.36 ms | 1.38x | 6.91 ms | 4.86 ms | 1.42x |
| montage | 362.0 µs | 135.3 µs | 2.67x | 348.9 µs | 131.1 µs | 2.66x |
| clone | 218.5 µs | 237.3 µs | 0.92x | 71.9 µs | 67.3 µs | 1.07x |
| crop | 68.7 µs | 70.5 µs | no change | 40.1 µs | 35.3 µs | 1.14x |
| trim | 10.11 ms | 245.5 µs | 41.2x | 9.84 ms | 230.7 µs | 42.7x |
| rotate90 | 22.85 ms | 1.14 ms | 20.0x | 22.71 ms | 1.07 ms | 21.3x |
| rotate | 15.03 ms | 2.81 ms | 5.34x | 14.45 ms | 2.77 ms | 5.21x |
| resize nearest | 3.37 ms | 290.8 µs | 11.6x | 3.37 ms | 279.9 µs | 12.0x |
| resize down | 5.47 ms | 2.30 ms | 2.38x | 5.03 ms | 2.19 ms | 2.30x |
| resize up | 15.88 ms | 6.66 ms | 2.38x | 14.72 ms | 6.29 ms | 2.34x |
| roll | 23.68 ms | 292.4 µs | 81.0x | 23.62 ms | 99.9 µs | 236x |
| alphaMask | 763.3 µs | 388.4 µs | 1.97x | 763.1 µs | 382.8 µs | 1.99x |
| maskToImage | 2.29 ms | 1.07 ms | 2.14x | 2.24 ms | 1.02 ms | 2.19x |
| paintMask color | 10.06 ms | 275.0 µs | 36.6x | 10.25 ms | 258.2 µs | 39.7x |
| paintMask tiled | 2.98 ms | 793.3 µs | 3.76x | 2.97 ms | 749.4 µs | 3.97x |
| dilateMask 1 | 6.71 ms | 626.6 µs | 10.7x | 6.20 ms | 606.5 µs | 10.2x |
| dilateMask 3 | 29.09 ms | 1.83 ms | 15.9x | 26.92 ms | 1.77 ms | 15.2x |
| blurMask | 7.66 ms | 4.52 ms | 1.69x | 7.42 ms | 4.36 ms | 1.70x |
| subtractMask | 606.7 µs | 127.5 µs | 4.76x | 581.4 µs | 122.1 µs | 4.76x |
| modulate | 5.73 ms | 752.8 µs | 7.61x | 5.80 ms | 730.7 µs | 7.94x |
| emboss | 10.23 ms | 1.04 ms | 9.83x | 10.05 ms | 995.3 µs | 10.1x |
| tint | 5.96 ms | 1.04 ms | 5.73x | 5.90 ms | 1.01 ms | 5.83x |
| grayscale | 2.32 ms | 1.49 ms | 1.55x | 2.38 ms | 1.42 ms | 1.68x |
| threshold | 2.12 ms | 1.54 ms | 1.38x | 2.12 ms | 1.46 ms | 1.46x |
| colorize | 6.41 ms | 1.47 ms | 4.34x | 6.48 ms | 1.43 ms | 4.54x |
| transparent | 14.99 ms | 1.17 ms | 12.8x | 14.80 ms | 1.11 ms | 13.3x |
| opaque | 15.60 ms | 1.23 ms | 12.7x | 15.11 ms | 1.17 ms | 12.9x |
| setAlpha | 20.40 ms | 105.7 µs | 193x | 19.89 ms | 101.6 µs | 196x |
| polynomial | 6.56 ms | 1.44 ms | 4.55x | 6.46 ms | 1.42 ms | 4.55x |
| contrastStretch | 8.95 ms | 921.7 µs | 9.71x | 8.87 ms | 894.4 µs | 9.92x |
| sigmoidalContrast | 9.38 ms | 370.5 µs | 25.3x | 9.10 ms | 355.3 µs | 25.6x |
| median | 3.52 ms | 558.6 µs | 6.31x | 3.47 ms | 540.3 µs | 6.43x |
| stats | 11.26 ms | 1.42 ms | 7.91x | 10.72 ms | 1.37 ms | 7.85x |
| noise | 6.61 ms | 2.08 ms | 3.17x | 6.61 ms | 2.02 ms | 3.27x |
| randomNoise | 4.47 ms | 652.2 µs | 6.86x | 4.35 ms | 604.6 µs | 7.19x |
| addGaussianNoise | 13.71 ms | 5.18 ms | 2.65x | 13.72 ms | 4.94 ms | 2.78x |
| verticalGradient | 771.4 µs | 235.4 µs | 3.28x | 746.2 µs | 199.1 µs | 3.75x |
| gaussianBlur 1.5 | 19.58 ms | 8.52 ms | 2.30x | 19.49 ms | 8.24 ms | 2.36x |
| gaussianBlur 12 | 111.23 ms | 49.14 ms | 2.26x | 110.36 ms | 47.07 ms | 2.34x |
| shadowed | 67.82 ms | 8.43 ms | 8.04x | 65.36 ms | 7.96 ms | 8.21x |
| png | 6.63 ms | 6.71 ms | no change | 6.53 ms | 6.60 ms | no change |
| png stored | 1.44 ms | 1.45 ms | no change | 1.41 ms | 1.37 ms | no change |
| readPNG unfiltered | 8.37 ms | 914.8 µs | 9.15x | 8.36 ms | 879.7 µs | 9.50x |
| readPNG filtered rgba | 9.78 ms | 2.03 ms | 4.80x | 9.81 ms | 1.97 ms | 4.99x |
| readPNG filtered rgb | 8.03 ms | 1.83 ms | 4.39x | 8.13 ms | 1.77 ms | 4.59x |
| readPNG filtered gray | 4.73 ms | 1.01 ms | 4.69x | 4.80 ms | 977.1 µs | 4.91x |
| dds | 10.38 ms | 642.6 µs | 16.1x | 10.14 ms | 626.3 µs | 16.2x |
| readDDS | 13.26 ms | 651.6 µs | 20.4x | 12.89 ms | 618.6 µs | 20.8x |
| readBMP | 13.20 ms | 919.0 µs | 14.4x | 12.98 ms | 892.8 µs | 14.5x |
| readTGA | 15.57 ms | 666.4 µs | 23.4x | 15.16 ms | 630.8 µs | 24.0x |
| readTGA packets | 15.19 ms | 1.81 ms | 8.41x | 14.72 ms | 1.67 ms | 8.81x |

The package was written as a `get` and a `set` for each pixel, with a color parsed again for
each pixel of a shape and a closure made for each pixel of a blend. Most of the table is that
going away: an operation reads and writes whole pixels in the buffer, and what does not depend
on the pixel is worked out once.

- **Block copies.** A fill is doubling copies of its first pixel (`fill` 11x, `rect` 8x, a
  gradient's rows 3.3x); a tile, a roll and a rectangle of a tile are copies of runs of rows
  (80x to 250x); `over` copies a row that is all opaque and skips one that is all clear, each
  found by one data-plane test over the row's pixels (`over opaque` 3.9x, `montage` 2.7x).
- **The data plane.** `setAlpha` is one strided `fill` (190x) and `copyAlpha` in copy mode one
  strided `scale` (76x); a quarter turn scatters each row down a column (20x) and a
  nearest-pixel resize gathers each row through one index vector (12x); `trim` asks `any` of
  whole rows and columns (41x); `stats` is four sums and a count (7.9x); the PNG filters that
  add the pixel before or the row above are one `add` a row.
- **Tables.** A curve over a channel (`colorize`, `polynomial`, `contrastStretch`,
  `sigmoidalContrast`: 4x to 25x), a mask painted in a color and a threshold are tables filled
  once, 256 entries for the most part, and looked up per pixel.
- **No branch in the loop.** Native Luau pays for a branch far more than for arithmetic: the
  clamp of a channel went through `math.clamp`, a choice between two results became a
  multiplication by 0 or 1, and a blend of bytes, which cannot leave a byte's range, is rounded
  with no clamp at all. That alone is the 1.3x of `over soft` and of `overMask`, and half of the
  2.4x of the bilinear resize.
- **The blur** sums a whole row of sums at a time, four taps to a pass, where it summed every
  tap of one pixel before the next (2.3x); a shadow blurs only the alpha it uses (8x).
- **Codecs.** A decoded row is copied or converted whole, where every pixel went through `set`:
  PNG 4.4x to 9.2x, of which what is left is `inflate`; DDS, BMP and TGA 8x to 24x.

What did not move: `png` is `deflate` (6.1 ms of its 6.2), `crop` and `clone` were block copies
already, and `get` and `set` themselves are bounded by the call (1.3x, from the clamp). The
smallest gains are where the arithmetic is the work: compositing soft pixels, `overMask`,
`blurMask`, `grayscale` and `threshold`.

Tried and not kept: the blur through the data plane (`scale` and `add` over rows of f64 measured
3.7 ns a tap against the 1.2 ns of the loop that shipped); `over` testing runs of 64 pixels
inside a mixed row (the tests cost more than they saved, and soft images lost 14 percent); a
compositing loop without branches (29 ns a pixel against 25 for soft pixels and 6 for a sprite's);
a typed slice for `alphaMask` (slower than the loop it replaced); and Paeth by a carried local a
channel (slower than reading the three neighbors).

## One dependent's generators

`st4sh-scripts` has no tests, so its two generators that need no input files were run against
the base and the head, five rounds by turns under the bench lock: the Morrowind UI generator
(318 DDS files) and COD3X (4 PNG files). All 322 files are byte for byte the same. The UI
generator took 0.74 s with the base and 0.42 s with the head (medians; the whole process 960 ms
and 629 ms); COD3X is 0.13 s and 0.12 s.

## Cold load

Requiring the module in a fresh process, eleven rounds by turns under the bench lock, median:

| | Require |
|---|---:|
| Base | 24.0 ms |
| Head | 32.5 ms |
| Head with its 18 dialect pipelines written as loops | 29.4 ms |

A second run of the three read 24.6, 33.0 and 30.9 ms. The module is three times the code it
was, and that is 5 to 6 ms. The other 2 to 3 ms is the dialect: 15 buffer sinks, a
comprehension, a reducer and a slice, 0.1 to 0.2 ms each, kept because each is one table of 256
entries or a kernel said in a line. Eleven reductions over buffer slices were not kept: they
measured 0.53 ms of load each (5.9 ms together; the module took 38.4 ms to require with them),
and the explicit data-plane call each lowers to is as fast or faster once the module is loaded.
Record patterns cost nothing to load.
