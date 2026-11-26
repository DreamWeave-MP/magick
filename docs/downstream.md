# Downstream integration (MAG-045)

How the claim in the README was checked, so anyone can check it again. Two things are shown: that the
DreamWeave Mod Template's own suite passes against Magick 0.5, and that the one thing it asks of Magick
(its site generator's `resize_image`: `magick.read`, `Image:resize(width, height, false)`, `magick.write`)
gives the same bytes under 0.1.3 and 0.5.0.

## The template's suite

On the template's local branch `deps/magick-0.5` (its dependency moved from `0.1` to `0.5`), with this
repository at the 0.5.0 head and the template's other dependencies from their checkouts:

```sh
jess package test . --package <magick 0.5.0> --package <dreamweave-site> --package <dreamweave-theme> \
  --package <vfs> --package <dream-archive>
```

Result on 2026-11-26: `passed: 154`, `failed: 0`.

## The image pipeline, byte for byte

A package of one command target, `check`, whose manifest asks for `org.dreamweave.magick` (`"0.1"` for the
first run, `"0.5"` for the second; requirements are caret-only), `include = ["check.jsl"]` and the
`filesystem.read` and `filesystem.write` capabilities:

```luau
--!strict
-- What the DreamWeave site generator asks of its image backend (`resize_image` in
-- dreamweave-site/src/site.jsl): read a file, resize it with the 0.1 bilinear resampler, write it.
local bytes = require '@dream/bytes'
local fs = require '@dream/fs'
local magick = require '@magick'

local folder, out = arg[1], arg[2]
local names = fs.list(folder) or {}

table.sort(names)

for _, entry in names do
  local name = fs.fileName(entry) or ''

  if string.sub(name, -4) ~= '.png' then continue end

  local image = magick.read(fs.join(folder, name))

  for _, size in { { 320, 0 }, { 0, 120 }, { 97, 61 } } do
    local width = if size[1] > 0 then size[1] else math.max(1, math.floor(image.width * size[2] / image.height + 0.5))
    local height = if size[2] > 0 then size[2] else math.max(1, math.floor(image.height * width / image.width + 0.5))
    local target = fs.join(out, `{name}-{width}x{height}.png`)

    magick.write(target, image:resize(width, height, false))
    print(`{name} {width}x{height} {bytes.sha256(fs.readFile(target) :: buffer)}`)
  end
end
return 0
```

Run against each release over the same images, and compare:

```sh
jess package run --trusted --package <magick 0.1.3> --target check . -- in out013 > r013.txt
jess package run --trusted --package <magick 0.5.0> --target check . -- in out050 > r050.txt
diff r013.txt r050.txt
```

Inputs: `gallery/heron.png`, `gallery/valley.png` and `gallery/references/mona-lisa-500.png`, each at
three sizes. All nine SHA-256 digests match:

```text
heron.png 320x400 f385aac576c6e5514727846368ee61eb4ae07a001e2c89f8dadd1c0e19afd90e
heron.png 96x120 92b9401439ba26a5d9ed6d1b8f625b9cd9dc996297ea143340cc0231eaf319e1
heron.png 97x61 1fc499064377ef45bc8896128a55f1195c9e8ac806a938d49f96d78093e4761c
mona-lisa-500.png 320x477 34a5cfb272f5585dad96992863a97654b21bd334b9ebc5160c72ef9052a7df00
mona-lisa-500.png 81x120 6350c37819a7727e464aee108a17d140539071ae9f04c97de6c6ad2488b0951e
mona-lisa-500.png 97x61 3a815123412264346a1a3283d192c787693811596037790b2a68c8773d3cb3ce
valley.png 320x180 21043b1107fe582483513ea33336264c1f2fb90b452f8271fe121ad595766f76
valley.png 213x120 473ffc1ec90032d9e086cea5d3f59be7111295c4904d651c5dea6913d9dc4405
valley.png 97x61 ccd3fecbc358333f3f4d82890fbc7de86088f8f8e617fbecc09f9e39858b5d3f
```
