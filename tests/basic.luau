--!strict
--!native
-- The raster half of @magick, pinned: every drawing, compositing, geometry, mask and tone
-- operation run on seeded fixtures and held to the fingerprint the package gave as imported.
local goldens = require './goldens'
local magick = require '@magick'
local support = require './support'
local test = require '@jess/test'

local expect = test.expect
local suite = test.new()
local pin, settle, unused = support.goldens(goldens.basic)
local pixels, noisy, sprite, coverage = support.pixels, support.noisy, support.sprite, support.coverage

type Image = support.Image

suite.afterEach(settle)

--- A mask of one value.
local function flat(width: number, height: number, value: number): support.Mask
  local covered = buffer.create(width * height)

  buffer.fill(covered, 0, value)

  return magick.mask(width, height, covered)
end

--- A mask that is clear but for one byte in twelve, each of any value.
local function speckled(width: number, height: number, seed: number): support.Mask
  local random = support.generator(seed)
  local covered = buffer.create(width * height)

  for offset = 0, width * height - 1 do
    if random(12) == 0 then buffer.writeu8(covered, offset, 1 + random(255)) end
  end

  return magick.mask(width, height, covered)
end

--- The Gaussian blur written the plain way: every channel of a pixel is the weighted sum of the
--- pixels within three sigmas of it along its row, rounded to a byte, and then the same along its
--- column, with a pixel past an edge taken for the edge's.
local function plainBlur(image: Image, sigma: number): Image
  local spread = math.max(0.01, sigma)
  local radius = math.max(1, math.ceil(spread * 3))
  local weights: { number } = {}
  local total = 0

  for offset = -radius, radius do
    local weight = math.exp(-(offset * offset) / (2 * spread * spread))

    table.insert(weights, weight)
    total += weight
  end

  for index = 1, #weights do
    weights[index] /= total
  end

  local function pass(source: Image, alongRow: boolean): Image
    local out = magick.new(source.width, source.height)

    for row = 0, source.height - 1 do
      for column = 0, source.width - 1 do
        local sums = { 0, 0, 0, 0 }

        for offset = -radius, radius do
          local fromColumn = if alongRow then math.clamp(column + offset, 0, source.width - 1) else column
          local fromRow = if alongRow then row else math.clamp(row + offset, 0, source.height - 1)
          local channels = { source:get(fromColumn, fromRow) }

          for channel = 1, 4 do
            sums[channel] += channels[channel] * weights[offset + radius + 1]
          end
        end

        out:set(column, row, sums[1], sums[2], sums[3], sums[4])
      end
    end

    return out
  end

  return pass(pass(image, true), false)
end

suite.describe('colors', function()
  suite.it('reads tables, hex strings and nothing', function()
    local named = {}
    named.r, named.g, named.b, named.a = 9, 8, 7, 6

    expect(magick.color(nil)).toEqual { 0, 0, 0, 0 }
    expect(magick.color {}).toEqual { 0, 0, 0, 255 }
    expect(magick.color { 1, 2, 3 }).toEqual { 1, 2, 3, 255 }
    expect(magick.color { 1, 2, 3, 4 }).toEqual { 1, 2, 3, 4 }
    expect(magick.color(named)).toEqual { 9, 8, 7, 6 }
    expect(magick.color '#abc').toEqual { 170, 187, 204, 255 }
    expect(magick.color 'abc').toEqual { 170, 187, 204, 255 }
    expect(magick.color '#0a141E').toEqual { 10, 20, 30, 255 }
    expect(magick.color '01020304').toEqual { 1, 2, 3, 4 }
    -- Alpha digits that are not hex are taken for no alpha at all.
    expect(magick.color '#010203zz').toEqual { 1, 2, 3, 255 }
  end)

  suite.it('refuses what is not a color', function()
    expect(function() magick.color(5) end).toThrow 'magick: color must be a table or hex string'
    expect(function() magick.color '#12345' end).toThrow 'magick: expected #rgb, #rrggbb, or #rrggbbaa'
    expect(function() magick.color '' end).toThrow 'magick: expected #rgb, #rrggbb, or #rrggbbaa'
    expect(function() magick.color '#gg0000' end).toThrow 'magick: invalid color'
  end)
end)

suite.describe('images', function()
  suite.it('makes clear and filled images of a whole size', function()
    local clear = magick.new(5, 3)

    expect(clear.width).toBe(5)
    expect(clear.height).toBe(3)
    expect(buffer.len(clear.data)).toBe(60)
    expect(getmetatable(clear)).toBe(magick.Image)
    pin('new clear', pixels(clear))
    pin('new hex', pixels(magick.new(5, 3, '#10203040')))
    pin('new table', pixels(magick.new(2, 2, { 1, 2, 3 })))
    pin('new empty', pixels(magick.new(0, 0, '#ffffff')))
    pin('new without rows', pixels(magick.new(4, 0, '#ffffff')))
    expect(function() magick.new(1.5, 2) end).toThrow 'magick: integer image size required'
    expect(function() magick.new(2, -1) end).toThrow 'magick: integer image size required'
    expect(function() magick.new(2, 2, 'ffff') end).toThrow 'magick: expected #rgb'
  end)

  suite.it('copies pixels in and clones them', function()
    local source = noisy(4, 3, 11)
    local copy = magick.fromRGBA(4, 3, source.data)
    local clone = source:clone()

    expect(copy.data ~= source.data).toBe(true)
    expect(clone.data ~= source.data).toBe(true)
    expect(getmetatable(clone)).toBe(magick.Image)
    pin('fromRGBA', pixels(copy))
    pin('clone', pixels(clone))
    expect(function() magick.fromRGBA(4, 4, source.data) end).toThrow 'magick: RGBA byte length does not match geometry'
  end)

  suite.it('fills with a color, packed as given', function()
    local image = noisy(7, 5, 3)

    expect(image:fill '#11223344').toBe(image)
    pin('fill hex', pixels(image))
    pin('fill table', pixels(noisy(7, 5, 3):fill { 9, 8, 7 }))
    pin('fill nothing', pixels(noisy(7, 5, 3):fill(nil)))
    pin('fill empty', pixels(magick.new(0, 3):fill '#ffffff'))
    -- A channel that is not a byte is not clamped: the pixel is packed by arithmetic, so the
    -- excess carries into the channels above and a fraction is dropped.
    pin('fill carried', pixels(noisy(7, 5, 3):fill { 300.75, 2, 3, 4 }))
    pin('fill borrowed', pixels(noisy(7, 5, 3):fill { -1, 0, 0, 255 }))
    pin('fill wrapped', pixels(noisy(7, 5, 3):fill { 0, 0, 0, 300 }))
    pin('fill negative', pixels(noisy(7, 5, 3):fill { -5, 0, 0, 0 }))
  end)

  suite.it('reads and writes one pixel, rounding and clamping, and ignores the outside', function()
    local image = magick.new(3, 2)

    expect(image:set(1, 1, 10.4, 10.5, -3, 300)).toBe(image)
    expect({ image:get(1, 1) }).toEqual { 10, 11, 0, 255 }
    image:set(2, 0, 254.5, 0.49, 0.5, 127.5)
    expect({ image:get(2, 0) }).toEqual { 255, 0, 1, 128 }
    expect({ image:get(3, 0) }).toEqual { 0, 0, 0, 0 }
    expect({ image:get(-1, 0) }).toEqual { 0, 0, 0, 0 }
    expect({ image:get(0, 2) }).toEqual { 0, 0, 0, 0 }
    expect({ image:get(0, -1) }).toEqual { 0, 0, 0, 0 }
    expect(image:set(3, 0, 1, 1, 1, 1)).toBe(image)
    image:set(0, -1, 1, 1, 1, 1)
    image:set(-1, 1, 1, 1, 1, 1)
    image:set(0, 2, 1, 1, 1, 1)
    pin('set', pixels(image))
  end)

  suite.it('measures an image', function()
    local stats = magick.stats(noisy(9, 7, 13))

    expect(stats.width).toBe(9)
    expect(stats.height).toBe(7)
    pin('stats covered', tostring(stats.nonzeroAlpha))
    pin('stats mean', string.format('%.17g %.17g %.17g %.17g', table.unpack(stats.mean)))
    expect(magick.stats(magick.new(0, 0))).toEqual { width = 0, height = 0, mean = { 0, 0, 0, 0 }, nonzeroAlpha = 0 }
    expect(magick.stats(magick.new(2, 2, '#04080c10'))).toEqual {
      width = 2,
      height = 2,
      mean = { 4, 8, 12, 16 },
      nonzeroAlpha = 4,
    }
  end)
end)

suite.describe('drawing', function()
  suite.it('fills rectangles with a color', function()
    local canvas = noisy(12, 9, 5)

    expect(canvas:rect(2, 1, 6, 4, '#ff000080')).toBe(canvas)
    canvas:rect(10, 8, 7, 6, { 1, 2, 3, 4 })
    canvas:rect(-5, -5, 1.9, 0.2, '#00ff00')
    canvas:rect(20, 20, 30, 30, '#ffffff')
    canvas:rect(20, 20, 30, 30, 'no color')
    pin('rect colors', pixels(canvas))
    pin('rect whole', pixels(noisy(12, 9, 5):rect(-1, -1, 12, 9, '#01020304')))
    pin('rect nothing', pixels(noisy(12, 9, 5):rect(3, 3, 5, 5, nil)))
    pin('rect carried', pixels(noisy(12, 9, 5):rect(0, 0, 3, 3, { 300.75, -2, 3, 4 })))
    expect(function() canvas:rect(0, 0, 1, 1, 'no color') end).toThrow 'magick: invalid color'
  end)

  suite.it('fills rectangles from a tile', function()
    local tile = noisy(4, 3, 6)
    local itself = noisy(6, 6, 8)

    pin('rect tiled', pixels(noisy(12, 9, 5):rect(1, 1, 10, 7, tile)))
    pin('rect tiled clipped', pixels(magick.new(11, 7):rect(-3, -2, 30, 30, noisy(5, 2, 7))))
    pin('rect tiled small', pixels(noisy(12, 9, 5):rect(5, 4, 6, 4, tile)))
    pin('rect tiled wide', pixels(noisy(12, 9, 5):rect(2, 2, 9, 6, noisy(20, 15, 9))))
    pin('rect tiled itself', pixels(itself:rect(1, 1, 4, 4, itself)))
    pin('tile', pixels(magick.tile(10, 7, tile)))
    pin('tile exact', pixels(magick.tile(8, 6, tile)))
    pin('tile empty', pixels(magick.tile(0, 0, tile)))
  end)

  suite.it('fills polygons', function()
    local triangle = { { 1, 1 }, { 10, 3 }, { 4, 8 } }
    local concave = { { 0, 0 }, { 11, 0 }, { 11, 8 }, { 6, 3 }, { 0, 8 } }
    local canvas = noisy(12, 9, 5)

    expect(canvas:polygon(triangle, '#336699')).toBe(canvas)
    pin('polygon triangle', pixels(canvas))
    pin('polygon concave tiled', pixels(noisy(12, 9, 5):polygon(concave, noisy(3, 3, 4))))
    pin('polygon outside', pixels(noisy(12, 9, 5):polygon({ { -4, -4 }, { 20, 2 }, { 5, 30 } }, '#ffffff80')))
    pin('polygon empty', pixels(noisy(12, 9, 5):polygon({}, '#ffffff')))
    pin('polygon clamped', pixels(noisy(12, 9, 5):polygon(triangle, { 300, 1.5, -2, 127.5 })))
    pin('polygon nothing', pixels(noisy(12, 9, 5):polygon(triangle, nil)))
    pin('polygon uncovered', pixels(noisy(12, 9, 5):polygon({}, 'no color')))
    expect(function() canvas:polygon(triangle, 'no color') end).toThrow 'magick: invalid color'
    pin('polygonOver', pixels(noisy(12, 9, 5):polygonOver(concave, '#33669980')))
    pin('polygonOver tiled', pixels(noisy(12, 9, 5):polygonOver(triangle, noisy(3, 3, 4))))
  end)

  suite.it('fills circles and ellipses', function()
    local canvas = noisy(12, 9, 5)

    expect(canvas:circle(6, 4, 3, nil, '#ff8800')).toBe(canvas)
    pin('circle', pixels(canvas))
    pin('ellipse tiled', pixels(noisy(12, 9, 5):circle(5.5, 4.5, 4, 2, noisy(3, 3, 4))))
    pin('circle clipped', pixels(noisy(12, 9, 5):circle(0, 0, 5, 5, { 1, 2, 3, 128 })))
    pin('circle clamped', pixels(noisy(12, 9, 5):circle(6, 4, 4, 3, { 300, 1.5, -2, 127.5 })))
    pin('circle of nothing', pixels(noisy(12, 9, 5):circle(6, 4, 0, 0, '#ffffff')))
    pin('circle outside', pixels(noisy(12, 9, 5):circle(-50, -50, 1, 1, 'no color')))
    expect(function() canvas:circle(6, 4, 3, 3, 'no color') end).toThrow 'magick: invalid color'
  end)

  suite.it('composites rectangles over what is there', function()
    local canvas = noisy(12, 9, 5)

    expect(canvas:rectOver(2, 1, 8, 6, '#ff000080')).toBe(canvas)
    pin('rectOver', pixels(canvas))
    pin('rectOver swapped clipped', pixels(noisy(12, 9, 5):rectOver(30, 30, -2, 3.7, '#00ff00c0')))
    pin('rectOver tiled', pixels(noisy(12, 9, 5):rectOver(1, 1, 10, 7, noisy(4, 3, 6))))
    pin('rectOver clear', pixels(noisy(12, 9, 5):rectOver(1, 1, 10, 7, '#ffffff00')))
    pin('rectOver opaque', pixels(noisy(12, 9, 5):rectOver(1, 1, 10, 7, '#102030')))
    pin('rectOver outside', pixels(noisy(12, 9, 5):rectOver(20, 20, 30, 30, 'no color')))
    expect(function() canvas:rectOver(0, 0, 1, 1, 'no color') end).toThrow 'magick: invalid color'
  end)

  suite.it('draws lines and outlines', function()
    local canvas = noisy(16, 12, 5)

    expect(canvas:line(1, 1, 14, 9, '#ffffff')).toBe(canvas)
    canvas:line(14, 2, 2, 10, '#ff0000', 3)
    canvas:line(5, 5, 5, 5, '#00ff00', 2)
    canvas:line(-4, 6, 20, 6.5, noisy(3, 3, 4), 2.4)
    pin('line', pixels(canvas))
    pin('strokeRect', pixels(noisy(16, 12, 5):strokeRect(2, 2, 13, 9, '#abcdef')))
    pin('strokeRect wide', pixels(noisy(16, 12, 5):strokeRect(1, 1, 14, 10, noisy(3, 3, 4), 3)))
    pin('roundRect', pixels(noisy(16, 12, 5):roundRect(1, 1, 14, 10, 3, '#abcdef80')))
    pin('roundRect square', pixels(noisy(16, 12, 5):roundRect(1, 1, 14, 10, nil, '#abcdef')))
    pin('roundRect outline', pixels(noisy(16, 12, 5):roundRect(1, 1, 14, 10, 3, '#abcdef', 2)))
  end)
end)

suite.describe('compositing', function()
  suite.it('lays one image over another', function()
    local base = noisy(14, 10, 21)

    expect(base:over(sprite(9, 8, 22), 3, 1)).toBe(base)
    pin('over inside', pixels(base))
    pin('over clipped low', pixels(noisy(14, 10, 21):over(noisy(9, 8, 23), -4, -3)))
    pin('over clipped high', pixels(noisy(14, 10, 21):over(noisy(9, 8, 23), 10, 7)))
    pin('over in place', pixels(noisy(14, 10, 21):over(noisy(9, 8, 23))))
    pin('over outside', pixels(noisy(14, 10, 21):over(noisy(9, 8, 23), 14, 0)))
    pin('over above', pixels(noisy(14, 10, 21):over(noisy(9, 8, 23), 0, -8)))
    pin('over onto clear', pixels(magick.new(14, 10):over(noisy(14, 10, 24))))
    pin('over onto opaque', pixels(magick.new(14, 10, '#102030'):over(noisy(14, 10, 24))))
    pin('over a larger image', pixels(noisy(5, 4, 26):over(noisy(14, 10, 24), -3, -2)))
    pin('over an opaque image', pixels(noisy(14, 10, 21):over(magick.new(6, 5, '#445566'), 2, 2)))
    pin('over a clear image', pixels(noisy(14, 10, 21):over(magick.new(6, 5), 2, 2)))
    pin('over a sprite', pixels(magick.new(20, 16, '#20406080'):over(sprite(16, 12, 27), 2, 2)))
  end)

  suite.it('lays an image over itself pixel by pixel', function()
    local smeared = noisy(8, 8, 25)
    local same = noisy(8, 8, 25)
    local opaque = noisy(8, 8, 25):setAlpha(255)

    pin('over itself, moved', pixels(smeared:over(smeared, 1, 1)))
    pin('over itself, in place', pixels(same:over(same)))
    pin('over its opaque self, moved', pixels(opaque:over(opaque, 2, 0)))
  end)

  suite.it('paints a color through a mask', function()
    local mask = coverage(13, 9, 31)
    local base = noisy(16, 12, 32)

    expect(base:overMask(mask, '#ff0000', 2, 1)).toBe(base)
    pin('overMask opaque', pixels(base))
    pin('overMask soft', pixels(noisy(16, 12, 32):overMask(mask, '#00ff0080', 2, 1)))
    pin('overMask onto opaque', pixels(magick.new(16, 12, '#101010'):overMask(mask, '#abcdef')))
    pin('overMask soft onto opaque', pixels(magick.new(16, 12, '#101010'):overMask(mask, '#abcdef40')))
    pin('overMask clipped low', pixels(noisy(16, 12, 32):overMask(mask, '#abcdef', -5, -4)))
    pin('overMask clipped high', pixels(noisy(16, 12, 32):overMask(mask, '#abcdef90', 9, 8)))
    pin('overMask outside', pixels(noisy(16, 12, 32):overMask(mask, '#abcdef', 16, 0)))
    pin('overMask full', pixels(noisy(16, 12, 32):overMask(flat(9, 5, 255), '#abcdef', 3, 3)))
    pin('overMask full soft', pixels(noisy(16, 12, 32):overMask(flat(9, 5, 255), '#abcdef70', 3, 3)))
    pin('overMask empty', pixels(noisy(16, 12, 32):overMask(flat(9, 5, 0), '#abcdef', 3, 3)))
    pin('overMask clear color', pixels(noisy(16, 12, 32):overMask(mask, { 1, 2, 3, 0 })))
    pin('overMask wide', pixels(noisy(40, 6, 33):overMask(coverage(37, 5, 34), '#fedcba', 1, 0)))
  end)

  suite.it('paints through a mask in one alpha after another as in each alone', function()
    local mask = coverage(13, 9, 31)
    local colors: { magick.Color } = { '#f0e0c090', '#f0e0c0', '#10203040', '#f0e0c090', { 1, 2, 3, 300 }, '#f0e0c0' }
    local alone = { 'soft', 'opaque', 'faint', 'soft', 'beyond a byte', 'opaque' }

    for index, color in colors do
      local painted = pixels(noisy(16, 12, 32):overMask(mask, color, 1, 1))

      if index <= 3 or index == 5 then pin(`overMask alone {alone[index]}`, painted) end

      expect(painted).toBe(goldens.basic[`overMask alone {alone[index]}`])
    end
  end)

  suite.it('composites alpha from another image', function()
    for _, mode in { 'dstin', 'dstout', 'copy' } do
      local image = noisy(9, 7, 41)

      expect(image:copyAlpha(noisy(9, 7, 42), mode)).toBe(image)
      pin(`copyAlpha {mode}`, pixels(image))
    end

    expect(function() noisy(9, 7, 41):copyAlpha(noisy(9, 7, 42), 'screen') end).toThrow 'magick: unknown alpha composite mode screen'
    expect(function() noisy(9, 7, 41):copyAlpha(noisy(9, 7, 42)) end).toThrow 'magick: unknown alpha composite mode nil'
    expect(function() noisy(9, 7, 41):copyAlpha(noisy(9, 6, 42), 'copy') end).toThrow 'magick: mask geometry mismatch'
    pin('copyAlpha empty', pixels(magick.new(0, 0):copyAlpha(magick.new(0, 0), 'screen')))
  end)

  suite.it('keeps the darker of two images', function()
    local base = noisy(12, 9, 43)

    expect(base:darken(noisy(7, 6, 44), 2, 1)).toBe(base)
    pin('darken', pixels(base))
    pin('darken clipped', pixels(noisy(12, 9, 43):darken(noisy(7, 6, 44), -3, 6)))
    pin('darken in place', pixels(noisy(12, 9, 43):darken(noisy(12, 9, 45))))
    pin('darken outside', pixels(noisy(12, 9, 43):darken(noisy(7, 6, 44), 12, 9)))
  end)

  suite.it('combines two images by a polynomial', function()
    local left, right = noisy(9, 7, 46), noisy(9, 7, 47)

    pin('mathCompose', pixels(magick.mathCompose(left, right)))
    pin('mathCompose difference', pixels(magick.mathCompose(left, right, 0, 1, -1, 0.5)))
    pin('mathCompose product', pixels(magick.mathCompose(left, right, 1, 0, 0, 0)))
    pin('mathCompose all', pixels(magick.mathCompose(left, right, 0.7, -0.4, 1.3, 0.11)))
    pin('mathCompose left', pixels(left))
    expect(function() magick.mathCompose(left, noisy(9, 6, 47)) end).toThrow 'magick: geometry mismatch'
  end)

  suite.it('lays images out in a grid', function()
    local tiles = { noisy(5, 4, 48), sprite(5, 4, 49), noisy(5, 4, 50), noisy(3, 6, 51), noisy(5, 4, 52) }

    pin('montage row', pixels(magick.montage(tiles)))
    pin('montage columns', pixels(magick.montage(tiles, 2)))
    pin('montage grid', pixels(magick.montage(tiles, 3, 3)))
    pin('montage short', pixels(magick.montage(tiles, 2, 1)))
    expect(function() magick.montage {} end).toThrow 'magick: montage requires images'
  end)
end)

suite.describe('geometry', function()
  suite.it('crops and extends', function()
    local source = noisy(11, 8, 51)

    pin('crop inside', pixels(source:crop(5, 4, 2, 1)))
    pin('crop low', pixels(source:crop(6, 6, -2, -3)))
    pin('crop high', pixels(source:crop(6, 6, 8, 5)))
    pin('crop outside', pixels(source:crop(3, 3, 20, 20)))
    pin('crop whole', pixels(source:crop(11, 8, 0, 0)))
    pin('crop no columns', pixels(source:crop(0, 4, 1, 1)))
    expect(function() source:crop(-1, 2, 0, 0) end).toThrow 'magick: integer image size required'
    pin('extent', pixels(source:extent(15, 12, 2, 3, '#204060')))
    pin('extent clipped', pixels(source:extent(6, 5, -3, -2)))
    pin('extent in place', pixels(source:extent(11, 8)))
    pin('crop source', pixels(source))
  end)

  suite.it('trims the clear border', function()
    local dot = magick.new(6, 6)
    dot:set(4, 2, 1, 1, 1, 9)

    pin('trim sprite', pixels(sprite(12, 10, 52):trim()))
    pin('trim noise', pixels(noisy(12, 10, 53):trim()))
    pin('trim clear', pixels(magick.new(5, 5):trim()))
    pin('trim dot', pixels(dot:trim()))
    pin('trim empty', pixels(magick.new(0, 0):trim()))
    pin('trim opaque', pixels(magick.new(4, 3, '#010203'):trim()))
  end)

  suite.it('turns by quarter turns and by any angle', function()
    local source = noisy(7, 4, 54)

    pin('rotate90 clockwise', pixels(source:rotate90(true)))
    pin('rotate90 counter', pixels(source:rotate90(false)))
    pin('rotate90', pixels(source:rotate90()))
    pin('rotate90 empty', pixels(magick.new(0, 3):rotate90(true)))

    for _, angle in { 0, 30, 45, 90, -5, 180, 271.5 } do
      pin(`rotate {angle}`, pixels(noisy(11, 8, 55):rotate(angle)))
    end

    pin('rotate dot', pixels(magick.new(1, 1, '#11223344'):rotate(33)))
    pin('rotate90 source', pixels(source))
  end)

  suite.it('resizes to the nearest pixel and by blending', function()
    local source = noisy(11, 8, 56)

    pin('resize nearest up', pixels(source:resize(22, 17, true)))
    pin('resize nearest down', pixels(source:resize(5, 3, true)))
    pin('resize nearest tall', pixels(source:resize(7, 20, true)))
    pin('resize up', pixels(source:resize(22, 17)))
    pin('resize down', pixels(source:resize(5, 3)))
    pin('resize same', pixels(source:resize(11, 8)))
    pin('resize to a dot', pixels(source:resize(1, 1)))
    pin('resize to nothing', pixels(source:resize(0, 5)))
    pin('resize nothing', pixels(magick.new(0, 0):resize(4, 4)))
    pin('resize a dot', pixels(magick.new(1, 1, '#11223344'):resize(3, 2)))
    pin('resizeFit', pixels(source:resizeFit(20, 20)))
    pin('resizeFit nearest', pixels(source:resizeFit(4, 30, true)))
    pin('resizeFit small', pixels(source:resizeFit(0.2, 0.2)))
  end)

  suite.it('rolls around the edges', function()
    local source = noisy(7, 5, 57)

    pin('roll', pixels(source:roll(3, 2)))
    pin('roll back', pixels(source:roll(-4, -1)))
    pin('roll far', pixels(source:roll(25, 17)))
    pin('roll by fractions', pixels(source:roll(2.7, -1.2)))
    pin('roll nowhere', pixels(source:roll()))
    pin('roll empty', pixels(magick.new(0, 0):roll(1, 1)))
    pin('roll source', pixels(source))
  end)
end)

suite.describe('masks', function()
  suite.it('wraps bytes as a mask and paints through one', function()
    local covered = buffer.create(12)
    local mask = magick.mask(4, 3, covered)
    local soft = coverage(9, 7, 61)

    expect(mask.data).toBe(covered)
    expect(mask.width).toBe(4)
    expect(mask.height).toBe(3)
    expect(function() magick.mask(4, 4, covered) end).toThrow 'magick: mask byte length mismatch'
    pin('maskToImage', pixels(magick.maskToImage(soft)))
    pin('maskToImage soft', pixels(magick.maskToImage(soft, '#11223380')))
    pin('maskToImage clear', pixels(magick.maskToImage(soft, { 4, 5, 6, 0 })))
    pin('paintMask', pixels(magick.paintMask(soft, '#804020c0')))
    pin('paintMask tiled', pixels(magick.paintMask(soft, noisy(4, 4, 62))))
    pin('paintMask uncovered', pixels(magick.paintMask(flat(5, 4, 0), 'no color')))
    expect(function() magick.paintMask(soft, 'no color') end).toThrow 'magick: invalid color'
    pin('alphaMask', pixels(noisy(9, 7, 63):alphaMask()))
    pin('alphaMask empty', pixels(magick.new(0, 0):alphaMask()))
  end)

  suite.it('grows, blurs and subtracts masks', function()
    local soft = coverage(13, 9, 64)

    for _, radius in { 0, 1, 2.9, 30, -3 } do
      pin(`dilateMask {radius}`, pixels(magick.dilateMask(soft, radius)))
    end

    for _, radius in { 0, 0.4, 1, 2.6, 30 } do
      pin(`blurMask {radius}`, pixels(magick.blurMask(soft, radius)))
    end

    for radius = 1, 4 do
      pin(`dilateMask speckled {radius}`, pixels(magick.dilateMask(speckled(21, 15, 66), radius)))
      pin(`blurMask speckled {radius}`, pixels(magick.blurMask(speckled(21, 15, 66), radius)))
    end

    pin('dilateMask one row', pixels(magick.dilateMask(speckled(30, 1, 67), 2)))
    pin('dilateMask one column', pixels(magick.dilateMask(speckled(1, 30, 68), 2)))
    pin('dilateMask empty', pixels(magick.dilateMask(magick.mask(0, 0, buffer.create(0)), 2)))
    pin('blurMask one row', pixels(magick.blurMask(speckled(30, 1, 67), 2)))
    pin('blurMask empty', pixels(magick.blurMask(magick.mask(0, 0, buffer.create(0)), 2)))

    expect(magick.blurMask(soft, 0).data ~= soft.data).toBe(true)
    pin('subtractMask', pixels(magick.subtractMask(soft, coverage(13, 9, 65))))
    pin('subtractMask itself', pixels(magick.subtractMask(soft, soft)))
    pin('mask source', pixels(soft))
    expect(function() magick.subtractMask(soft, coverage(13, 8, 65)) end).toThrow 'magick: mask geometry mismatch'
  end)
end)

suite.describe('tone', function()
  suite.it('modulates, embosses and tints in place', function()
    local image = noisy(9, 7, 71)

    expect(magick.modulate(image)).toBe(image)
    pin('modulate', pixels(image))
    pin('modulate gray', pixels(magick.modulate(noisy(9, 7, 71), 150, 0)))
    pin('modulate vivid', pixels(magick.modulate(noisy(9, 7, 71), 80, 130)))
    expect(magick.emboss(image)).toBe(image)
    pin('emboss', pixels(image))
    pin('emboss strong', pixels(magick.emboss(noisy(9, 7, 71), 2.5)))
    expect(magick.tint(image, '#ff8040')).toBe(image)
    pin('tint', pixels(image))
    pin('tint half', pixels(magick.tint(noisy(9, 7, 71), { 10, 200, 30 }, 50)))
  end)

  suite.it('grays, thresholds and colorizes in place', function()
    local image = noisy(9, 7, 72)

    expect(image:grayscale()).toBe(image)
    pin('grayscale', pixels(image))
    expect(image:threshold(0.5)).toBe(image)
    pin('threshold', pixels(image))
    pin('threshold level', pixels(noisy(9, 7, 72):threshold(100)))
    pin('threshold one', pixels(noisy(9, 7, 72):threshold(1)))
    pin('threshold none', pixels(noisy(9, 7, 72):threshold(0)))
    expect(image:colorize '#336699').toBe(image)
    pin('colorize', pixels(image))
    pin('colorize part', pixels(noisy(9, 7, 72):colorize({ 250.5, 3, 128 }, 40)))
    pin('colorize beyond', pixels(noisy(9, 7, 72):colorize('#ff0080', 180)))
  end)

  suite.it('thresholds every mean at a cut on it, beside it and beyond every one', function()
    --- An image of 766 pixels, one for each sum three channels can have.
    local function sums(): Image
      local image = magick.new(766, 1)

      for total = 0, 765 do
        local red = math.min(total, 255)
        local green = math.min(total - red, 255)

        image:set(total, 0, red, green, total - red - green, total % 256)
      end

      return image
    end

    local levels = { 85, 85.00000000000001, 84.99999999999999, 1 / 3, 0.2, 254.9, 255, 255.1, 1.0000001, -4, 0 / 0 }

    for index, level in levels do
      local image, plain = sums():threshold(level), sums()
      local cut = if level <= 1 then level * 255 else level

      for total = 0, 765 do
        local red, green, blue, alpha = plain:get(total, 0)
        local white = if (red + green + blue) / 3 >= cut then 255 else 0

        plain:set(total, 0, white, white, white, alpha)
      end

      expect(pixels(image)).toBe(pixels(plain))
      pin(`threshold cut {index}`, pixels(image))
    end
  end)

  suite.it('colorizes and shades an image of many pixels as it does its halves, which are few', function()
    local wide, soft = noisy(48, 30, 130), coverage(48, 30, 131)
    local color: magick.Color = { 250.5, 3, 128, 100 }
    local colorized = wide:clone():colorize(color, 40)
    local shaded = magick.maskToImage(soft, color)
    local upper, lower = magick.mask(48, 15, soft.data[1:720]), magick.mask(48, 15, soft.data[721:1440])

    expect(pixels(colorized:crop(24, 30, 0, 0))).toBe(pixels(wide:crop(24, 30, 0, 0):colorize(color, 40)))
    expect(pixels(colorized:crop(24, 30, 24, 0))).toBe(pixels(wide:crop(24, 30, 24, 0):colorize(color, 40)))
    expect(pixels(shaded:crop(48, 15, 0, 0))).toBe(pixels(magick.maskToImage(upper, color)))
    expect(pixels(shaded:crop(48, 15, 0, 15))).toBe(pixels(magick.maskToImage(lower, color)))
    pin('colorize many pixels', pixels(colorized))
    pin('maskToImage many pixels', pixels(shaded))
  end)

  suite.it('swaps colors and sets alpha', function()
    local image = noisy(9, 7, 73)
    image:set(2, 2, 10, 20, 30, 200)
    image:set(5, 3, 10, 20, 30, 0)
    image:set(6, 6, 10, 20, 31, 255)

    expect(image:transparent '#0a141e').toBe(image)
    pin('transparent', pixels(image))
    image:set(1, 1, 10, 20, 30, 77)
    expect(image:opaque('#0a141e', { 1, 2, 3 })).toBe(image)
    pin('opaque', pixels(image))
    pin('opaque clamped', pixels(image:clone():opaque({ 1, 2, 3 }, { 300, 1.5, -4 })))
    pin('transparent unmatched', pixels(image:clone():transparent { 10.5, 20, 30 }))

    for _, value in { 0.5, 1, 200, 0, -4, 1.5, 999 } do
      local faded = noisy(9, 7, 73)

      expect(faded:setAlpha(value)).toBe(faded)
      pin(`setAlpha {value}`, pixels(faded))
    end
  end)

  suite.it('stretches contrast', function()
    local image = noisy(9, 7, 74)
    local level = magick.new(4, 4, '#404040')

    expect(image:polynomial(1.5, -0.2)).toBe(image)
    pin('polynomial', pixels(image))
    pin('polynomial lift', pixels(noisy(9, 7, 74):polynomial(0.5, 0.25)))
    expect(image:contrastStretch()).toBe(image)
    pin('contrastStretch', pixels(image))
    pin('contrastStretch clipped', pixels(noisy(9, 7, 74):contrastStretch(1, 1)))
    pin('contrastStretch uneven', pixels(noisy(9, 7, 74):contrastStretch(10, 20)))
    expect(level:contrastStretch(1, 1)).toBe(level)
    pin('contrastStretch level', pixels(level))
    expect(image:sigmoidalContrast()).toBe(image)
    pin('sigmoidalContrast', pixels(image))
    pin('sigmoidalContrast percent', pixels(noisy(9, 7, 74):sigmoidalContrast(5, 40)))
    pin('sigmoidalContrast low', pixels(noisy(9, 7, 74):sigmoidalContrast(3, 0.3)))
    pin('median', `{noisy(9, 7, 74):median()} {noisy(31, 17, 75):median()} {image:median()}`)
    expect(level:median()).toBe(64)
    expect(magick.new(0, 0):median()).toBe(0)
    expect(magick.new(3, 3):median()).toBe(0)
  end)
end)

suite.describe('generators', function()
  suite.it('makes seeded noise', function()
    pin('noise', pixels(magick.noise(9, 7, '#806040')))
    pin('noise seeded', pixels(magick.noise(9, 7, { 200, 0, 90, 128 }, 77, 0.6)))
    pin('noise odd', pixels(magick.noise(5, 3, '#ffffff', 0)))
    pin('randomNoise', pixels(magick.randomNoise(9, 7)))
    pin('randomNoise seeded', pixels(magick.randomNoise(9, 7, 1234.9)))
    pin('randomNoise empty', pixels(magick.randomNoise(0, 4, 3)))
  end)

  suite.it('adds noise to a copy', function()
    local source = noisy(9, 7, 81)

    pin('addGaussianNoise', pixels(magick.addGaussianNoise(source)))
    pin('addGaussianNoise seeded', pixels(magick.addGaussianNoise(source, 3302, 0.2)))
    pin('addGaussianNoise source', pixels(source))
  end)

  suite.it('makes gradients', function()
    pin('verticalGradient', pixels(magick.verticalGradient(6, 9, '#000000', '#ffffff')))
    pin('verticalGradient tables', pixels(magick.verticalGradient(5, 8, { 245, 245, 245, 255 }, { 92, 92.5, 300, 0 })))
    pin('verticalGradient one row', pixels(magick.verticalGradient(6, 1, '#102030', '#ffffff')))
    pin('verticalGradient empty', pixels(magick.verticalGradient(0, 0, '#102030', '#ffffff')))
  end)

  suite.it('blurs with a Gaussian', function()
    local source = noisy(23, 17, 82)

    pin('gaussianBlur', pixels(magick.gaussianBlur(source, 0.8)))
    pin('gaussianBlur wide', pixels(magick.gaussianBlur(noisy(40, 9, 83), 3)))
    pin('gaussianBlur tall', pixels(magick.gaussianBlur(noisy(20, 31, 84), 2.5)))
    pin('gaussianBlur sprite', pixels(magick.gaussianBlur(sprite(26, 20, 85), 1.7)))
    pin('gaussianBlur tiny sigma', pixels(magick.gaussianBlur(source, 0.001)))
    pin('gaussianBlur exact fit', pixels(magick.gaussianBlur(noisy(6, 1, 86), 1)))
    pin('gaussianBlur empty', pixels(magick.gaussianBlur(magick.new(0, 0), 1)))
    pin('gaussianBlur without rows', pixels(magick.gaussianBlur(magick.new(7, 0), 1)))

    local unblurred = magick.gaussianBlur(source, 0)

    expect(unblurred.data ~= source.data).toBe(true)
    pin('gaussianBlur none', pixels(unblurred))
    pin('gaussianBlur negative', pixels(magick.gaussianBlur(source, -2)))
    pin('gaussianBlur source', pixels(source))
  end)

  suite.it('blurs as the plain sums do, an image narrower than the kernel too', function()
    local shapes = {
      { 23, 17, 0.8 },
      { 40, 9, 3 },
      { 4, 4, 1 },
      { 5, 3, 1 },
      { 1, 1, 2 },
      { 3, 20, 2.5 },
      { 40, 2, 1.5 },
      { 17, 30, 2 },
    }

    for index, shape in shapes do
      local source = noisy(shape[1], shape[2], 90 + index)
      local blurred = magick.gaussianBlur(source, shape[3])

      expect(pixels(blurred)).toBe(pixels(plainBlur(source, shape[3])))
      pin(`gaussianBlur {shape[1]}x{shape[2]} by {shape[3]}`, pixels(blurred))
    end
  end)

  suite.it('drops a shadow', function()
    local source = sprite(20, 12, 87)

    pin('shadowed', pixels(magick.shadowed(source)))
    pin('shadowed moved', pixels(magick.shadowed(source, 30, 3, 3, 4)))
    pin('shadowed back', pixels(magick.shadowed(noisy(20, 12, 88), 55, 1.5, -6, -9)))
    pin('shadowed far', pixels(magick.shadowed(source, 100, 2, 40, 1)))
    pin('shadowed source', pixels(source))
  end)
end)

suite.describe('sources the fast paths decline', function()
  --- A tile that is an image in all but its metatable, which only looks the methods up: its
  --- pixels are sampled through its `get`, one at a time.
  local function wrapped(image: Image): Image
    local tile = setmetatable({ width = image.width, height = image.height, data = image.data }, { __index = magick.Image })

    return (tile :: unknown) :: Image
  end

  suite.it('fills from a tile sampled pixel by pixel as from one copied in runs', function()
    local tile = noisy(4, 3, 6)
    local triangle = { { 1, 1 }, { 10, 3 }, { 4, 8 } }
    local soft = coverage(9, 7, 61)

    pin('rect sampled', pixels(noisy(12, 9, 5):rect(1, 1, 10, 7, wrapped(tile))))
    expect(pixels(noisy(12, 9, 5):rect(1, 1, 10, 7, wrapped(tile)))).toBe(pixels(noisy(12, 9, 5):rect(1, 1, 10, 7, tile)))
    pin('polygon sampled', pixels(noisy(12, 9, 5):polygon(triangle, wrapped(tile))))
    expect(pixels(noisy(12, 9, 5):polygon(triangle, wrapped(tile)))).toBe(pixels(noisy(12, 9, 5):polygon(triangle, tile)))
    pin('circle sampled', pixels(noisy(12, 9, 5):circle(5.5, 4.5, 4, 2, wrapped(tile))))
    expect(pixels(noisy(12, 9, 5):circle(5.5, 4.5, 4, 2, wrapped(tile)))).toBe(pixels(noisy(12, 9, 5):circle(5.5, 4.5, 4, 2, tile)))
    pin('rectOver sampled', pixels(noisy(12, 9, 5):rectOver(1, 1, 10, 7, wrapped(tile))))
    expect(pixels(noisy(12, 9, 5):rectOver(1, 1, 10, 7, wrapped(tile)))).toBe(pixels(noisy(12, 9, 5):rectOver(1, 1, 10, 7, tile)))
    pin('paintMask sampled', pixels(magick.paintMask(soft, wrapped(tile))))
    expect(pixels(magick.paintMask(soft, wrapped(tile)))).toBe(pixels(magick.paintMask(soft, tile)))
  end)

  --- A copy of an image with a `get` of its own, which gives the pixel a column and a row over,
  --- wrapping: what `image:roll(-1, -1)` holds.
  local function shifted(image: Image): Image
    local tile = image:clone()
    local fields = (tile :: unknown) :: { get: (Image, number, number) -> (number, number, number, number) }

    fields.get = function(self: Image, column: number, row: number): (number, number, number, number)
      return magick.Image.get(self, (column + 1) % self.width, (row + 1) % self.height)
    end

    return tile
  end

  suite.it('fills from an image that has a get of its own through it', function()
    local tile = noisy(4, 3, 6)
    local own, moved = shifted(tile), tile:roll(-1, -1)
    local triangle = { { 1, 1 }, { 10, 3 }, { 4, 8 } }
    local soft = coverage(9, 7, 61)

    pin('rect through a get', pixels(noisy(12, 9, 5):rect(1, 1, 10, 7, own)))
    expect(pixels(noisy(12, 9, 5):rect(1, 1, 10, 7, own))).toBe(pixels(noisy(12, 9, 5):rect(1, 1, 10, 7, moved)))
    pin('polygon through a get', pixels(noisy(12, 9, 5):polygon(triangle, own)))
    expect(pixels(noisy(12, 9, 5):polygon(triangle, own))).toBe(pixels(noisy(12, 9, 5):polygon(triangle, moved)))
    pin('circle through a get', pixels(noisy(12, 9, 5):circle(5.5, 4.5, 4, 2, own)))
    expect(pixels(noisy(12, 9, 5):circle(5.5, 4.5, 4, 2, own))).toBe(pixels(noisy(12, 9, 5):circle(5.5, 4.5, 4, 2, moved)))
    pin('rectOver through a get', pixels(noisy(12, 9, 5):rectOver(1, 1, 10, 7, own)))
    expect(pixels(noisy(12, 9, 5):rectOver(1, 1, 10, 7, own))).toBe(pixels(noisy(12, 9, 5):rectOver(1, 1, 10, 7, moved)))
    pin('paintMask through a get', pixels(magick.paintMask(soft, own)))
    expect(pixels(magick.paintMask(soft, own))).toBe(pixels(magick.paintMask(soft, moved)))
    pin('tile through a get', pixels(magick.tile(9, 7, own)))
    expect(pixels(magick.tile(9, 7, own))).toBe(pixels(magick.tile(9, 7, moved)))
  end)

  suite.it('takes the alpha and the darker of an image that has a get of its own through it', function()
    local source = noisy(7, 6, 44)
    local own, moved = shifted(source), source:roll(-1, -1)

    for _, mode in { 'dstin', 'dstout', 'copy' } do
      pin(`copyAlpha {mode} through a get`, pixels(noisy(7, 6, 43):copyAlpha(own, mode)))
      expect(pixels(noisy(7, 6, 43):copyAlpha(own, mode))).toBe(pixels(noisy(7, 6, 43):copyAlpha(moved, mode)))
    end

    pin('darken through a get', pixels(noisy(12, 9, 43):darken(own, 2, 1)))
    expect(pixels(noisy(12, 9, 43):darken(own, 2, 1))).toBe(pixels(noisy(12, 9, 43):darken(moved, 2, 1)))
  end)

  suite.it('refuses a mask of coverage where an image is asked for, and leaves the image as it was', function()
    local image, darker = noisy(6, 5, 120), noisy(6, 5, 121)
    local before, beforeDarker = pixels(image), pixels(darker)
    local covered = (coverage(6, 5, 122) :: unknown) :: Image
    local refusal = "attempt to call missing method 'get' of table"

    expect(function() image:copyAlpha(covered, 'dstin') end).toThrow(refusal)
    expect(function() image:copyAlpha(covered, 'copy') end).toThrow(refusal)
    expect(function() darker:darken(covered) end).toThrow(refusal)
    expect(pixels(image)).toBe(before)
    expect(pixels(darker)).toBe(beforeDarker)
  end)

  suite.it('draws an image from itself pixel by pixel', function()
    local polygon, circle, over = noisy(8, 8, 110), noisy(8, 8, 111), noisy(8, 8, 112)
    local alpha, darker = noisy(8, 8, 113), noisy(8, 8, 114)

    pin('polygon from itself', pixels(polygon:polygon({ { 0, 0 }, { 8, 1 }, { 3, 8 } }, polygon)))
    pin('circle from itself', pixels(circle:circle(4, 4, 3, 3, circle)))
    pin('rectOver from itself', pixels(over:rectOver(1, 1, 6, 6, over)))
    pin('copyAlpha from itself', pixels(alpha:copyAlpha(alpha, 'dstin')))
    pin('darken from itself', pixels(darker:darken(darker, 1, 2)))
  end)

  suite.it('lays an image at an offset between pixels as it always has', function()
    pin('over by half a pixel', pixels(noisy(14, 10, 21):over(noisy(9, 8, 23), 0.5, 2)))
    pin('darken by half a pixel', pixels(noisy(12, 9, 43):darken(noisy(7, 6, 44), 2.5, 1)))
  end)

  suite.it('takes channels that are not bytes as it always has', function()
    local keyed = noisy(6, 6, 115)
    keyed:set(2, 2, 44, 1, 0, 200)

    pin('transparent beyond a byte', pixels(keyed:clone():transparent { 300, 0, 0 }))
    pin('opaque beyond a byte', pixels(keyed:clone():opaque({ 300, 0, 0 }, { 1, 2, 3 })))
    pin('opaque between bytes', pixels(keyed:clone():opaque({ 44, 1, 0.5 }, { 1, 2, 3 })))
    pin('maskToImage carried', pixels(magick.maskToImage(coverage(9, 7, 61), { 300.5, 2, 3, 128 })))
    pin('paintMask clamped', pixels(magick.paintMask(coverage(9, 7, 61), { 300, -4, 12.5, 200 })))
    pin('overMask carried', pixels(noisy(16, 12, 32):overMask(coverage(13, 9, 31), { 300.5, -2, 3, 255 }, 1, 1)))
    pin('rectOver beyond a byte', pixels(noisy(12, 9, 5):rectOver(1, 1, 10, 7, { 300, -20, 12.5, 400 })))
    pin('rectOver faint', pixels(noisy(12, 9, 5):rectOver(1, 1, 10, 7, { 10, 20, 30, 0.4 })))
    pin('setAlpha empty', pixels(magick.new(0, 0):setAlpha(0.5)))
    pin('shadowed sharp', pixels(magick.shadowed(sprite(20, 12, 87), 60, 0, 2, 3)))
    pin('rotate90 one row', pixels(noisy(9, 1, 116):rotate90(true)))
    pin('rotate90 one column', pixels(noisy(1, 9, 117):rotate90(false)))
  end)
end)

suite.it('holds every golden to something', function() expect(unused()).toEqual {} end)

return suite
