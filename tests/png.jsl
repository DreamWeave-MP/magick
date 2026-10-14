--!strict
--!native
-- The codec half of @magick, pinned: PNG out and in (every filter on every color type), DDS out
-- and in, BMP and TGA in, and the files `read` and `write` choose a codec for. The inputs are
-- built here byte by byte, so a decoder is held to bytes no encoder of this package wrote.
local bytes = require '@dream/bytes'
local goldens = require './goldens'
local magick = require '@magick'
local support = require './support'
local test = require '@jess/test'

local expect = test.expect
local suite = test.new()
local pin, settle, unused = support.goldens(goldens.png)
local pixels, digest, noisy, noise = support.pixels, support.digest, support.noisy, support.noise

local Signature = '\137PNG\r\n\26\n'

--- How many bytes a pixel of each PNG color type takes at eight bits a sample.
local Channels = { [0] = 1, [2] = 3, [4] = 2, [6] = 4 }

suite.afterEach(settle)

--- A file of the suite's own under the harness's scratch root.
local function scratch(name: string): string
  local root = assert(rawget(_G, 'scratchRoot') :: string?, 'the case needs a scratchRoot')
  local folder = jess.fs.join(root, 'magick-codecs')

  jess.fs.createDir(folder)

  return jess.fs.join(folder, name)
end

local function chunk(kind: string, payload: string): string
  return string.pack('>I4', #payload) .. kind .. payload .. string.pack('>I4', bytes.crc32(kind .. payload))
end

local function header(width: number, height: number, depth: number, colorType: number, interlace: number): string
  return chunk('IHDR', string.pack('>I4I4BBBBB', width, height, depth, colorType, 0, 0, interlace))
end

--- Scanlines of noise for an image of `colorType`: each row's filter is the next of the five,
--- starting from `first`, so every filter meets the first row and every row below it.
local function scanlines(width: number, height: number, colorType: number, first: number, seed: number): string
  local stride = width * Channels[colorType]
  local rows: { string } = {}

  for row = 0, height - 1 do
    rows[row + 1] = string.char((first + row) % 5) .. noise(stride, seed + row)
  end

  return table.concat(rows)
end

--- A PNG around `lines`, its compressed stream cut into `pieces` IDAT chunks.
local function png(width: number, height: number, colorType: number, lines: string, pieces: number?): buffer
  local packed = buffer.tostring(bytes.deflate(lines, { format = 'zlib', level = 6 }))
  local parts = { Signature, header(width, height, 8, colorType, 0), chunk('tEXt', 'Comment\0pinned') }
  local count = pieces or 1
  local size = math.ceil(#packed / count)

  for piece = 1, count do
    table.insert(parts, chunk('IDAT', string.sub(packed, (piece - 1) * size + 1, piece * size)))
  end

  table.insert(parts, chunk('IEND', ''))

  return buffer.fromstring(table.concat(parts))
end

--- A BMP of `bits` a pixel around rows of noise, each padded to four bytes.
local function bmp(
  width: number,
  height: number,
  bits: number,
  topDown: boolean,
  seed: number,
  compression: number?,
  headerSize: number?
): buffer
  local stride = (width * bits // 8 + 3) // 4 * 4
  local body = noise(stride * height, seed)

  return buffer.fromstring(
    'BM'
      .. string.pack('<I4I4I4', 54 + #body, 0, 54)
      .. string.pack('<I4i4i4I2I2I4', headerSize or 40, width, if topDown then -height else height, 1, bits, compression or 0)
      .. string.rep('\0', 20)
      .. body
  )
end

--- A TGA of `imageType` around `body`, after an identification field of `id`.
local function tga(
  width: number,
  height: number,
  imageType: number,
  bits: number,
  descriptor: number,
  body: string,
  id: string?,
  colorMap: number?
): buffer
  local identification = id or ''

  return buffer.fromstring(
    string.pack('<BBB', #identification, colorMap or 0, imageType)
      .. string.rep('\0', 9)
      .. string.pack('<I2I2BB', width, height, bits, descriptor)
      .. identification
      .. body
  )
end

--- Run-length packets of noise covering at least `count` pixels of `size` bytes: runs and
--- literal packets by turns, of any length a packet has, so the last one may run past the image.
local function packets(count: number, size: number, seed: number): string
  local random = support.generator(seed)
  local parts: { string } = {}
  local covered = 0

  while covered < count do
    local length = 1 + random(24)
    local run = random(2) == 0

    table.insert(parts, string.char(if run then 0x80 + length - 1 else length - 1))
    table.insert(parts, noise(if run then size else size * length, seed + covered))
    covered += length
  end

  return table.concat(parts)
end

suite.describe('png', function()
  suite.it('writes a PNG that reads back', function()
    local source = noisy(13, 9, 101)
    local encoded = magick.png(source)

    pin('png', digest(encoded))
    pin('png stored', digest(magick.png(source, 0)))
    pin('png best', digest(magick.png(source, 9)))
    pin('png empty', digest(magick.png(magick.new(0, 0))))
    pin('png without rows', digest(magick.png(magick.new(5, 0))))
    pin('png flat', digest(magick.png(magick.new(64, 64, '#336699'))))
    expect(buffer.readstring(encoded, 0, 8)).toBe(Signature)
    expect(pixels(magick.readPNG(encoded))).toBe(pixels(source))
    expect(pixels(magick.readPNG(magick.png(source, 0)))).toBe(pixels(source))
    expect(pixels(magick.readPNG(magick.png(magick.new(0, 0))))).toBe '0x0:00000000'
    expect(pixels(magick.readPNG(magick.png(magick.new(5, 0))))).toBe '5x0:00000000'
  end)

  suite.it('reads every filter on every color type', function()
    for _, colorType in { 0, 2, 4, 6 } do
      for first = 0, 4 do
        local lines = scanlines(9, 11, colorType, first, 200 + colorType * 10 + first)

        pin(`readPNG type {colorType} from filter {first}`, pixels(magick.readPNG(png(9, 11, colorType, lines, 1 + first % 3))))
      end
    end

    pin('readPNG one column', pixels(magick.readPNG(png(1, 12, 6, scanlines(1, 12, 6, 1, 301)))))
    pin('readPNG one row', pixels(magick.readPNG(png(12, 1, 2, scanlines(12, 1, 2, 4, 302)))))
    pin('readPNG wide', pixels(magick.readPNG(png(67, 6, 6, scanlines(67, 6, 6, 3, 303), 4))))
  end)

  suite.it('reads a PNG that stops early or runs on', function()
    local lines = scanlines(5, 4, 6, 0, 310)
    local packed = buffer.tostring(bytes.deflate(lines, { format = 'zlib', level = 6 }))
    local unended = Signature .. header(5, 4, 8, 6, 0) .. chunk('IDAT', packed)
    local extra = Signature .. header(5, 4, 8, 6, 0) .. chunk('IDAT', packed) .. chunk('IEND', '') .. 'trailing bytes'
    local padded = buffer.tostring(bytes.deflate(lines .. string.rep('\7', 40), { format = 'zlib', level = 6 }))

    pin('readPNG without an end', pixels(magick.readPNG(buffer.fromstring(unended))))
    pin('readPNG past its end', pixels(magick.readPNG(buffer.fromstring(extra))))
    pin('readPNG longer scanlines', pixels(magick.readPNG(buffer.fromstring(Signature .. header(5, 4, 8, 6, 0) .. chunk('IDAT', padded)))))
    -- An image without columns has no bytes to filter, so its filter bytes are never read.
    pin('readPNG without columns', pixels(magick.readPNG(png(0, 3, 6, '\9\9\9'))))
  end)

  suite.it('refuses a PNG it cannot read', function()
    local lines = scanlines(5, 4, 6, 0, 320)
    local packed = buffer.tostring(bytes.deflate(lines, { format = 'zlib', level = 6 }))

    local function read(file: string): () -> ()
      return function() magick.readPNG(buffer.fromstring(file)) end
    end

    expect(read 'PNG').toThrow 'magick: not a PNG'
    expect(read('\137PNG\r\n\26\r' .. header(5, 4, 8, 6, 0))).toThrow 'magick: not a PNG'
    expect(read(Signature .. string.pack('>I4', 900) .. 'IDAT' .. packed .. '0000')).toThrow 'magick: truncated PNG chunk'
    expect(read(Signature .. chunk('IDAT', packed) .. chunk('IEND', ''))).toThrow 'magick: PNG requires 8-bit non-interlaced samples'
    expect(read(Signature .. header(5, 4, 16, 6, 0) .. chunk('IDAT', packed))).toThrow 'magick: PNG requires 8-bit non-interlaced samples'
    expect(read(Signature .. header(5, 4, 8, 6, 1) .. chunk('IDAT', packed))).toThrow 'magick: PNG requires 8-bit non-interlaced samples'
    expect(read(Signature .. header(5, 4, 8, 3, 0) .. chunk('IDAT', packed))).toThrow 'magick: unsupported PNG color type 3'
    expect(read(Signature .. header(5, 5, 8, 6, 0) .. chunk('IDAT', packed))).toThrow 'magick: truncated PNG scanlines'
    expect(read(Signature .. header(5, 4, 8, 6, 0) .. chunk('IDAT', string.sub(packed, 1, #packed - 9)))).toThrow()
    expect(read(Signature .. header(5, 4, 8, 6, 0))).toThrow()
    expect(read(Signature .. header(2, 2, 8, 6, 0) .. chunk('IDAT', packed))).toThrow()
    expect(function() magick.readPNG(png(5, 2, 6, '\0' .. noise(20, 321) .. '\5' .. noise(20, 322))) end).toThrow 'magick: bad PNG filter'
  end)
end)

suite.describe('dds', function()
  suite.it('writes a DDS that reads back', function()
    local source = noisy(13, 9, 401)
    local encoded = magick.dds(source)

    pin('dds', digest(encoded))
    pin('dds empty', digest(magick.dds(magick.new(0, 0))))
    expect(buffer.len(encoded)).toBe(128 + 13 * 9 * 4)
    expect(pixels(magick.readDDS(encoded))).toBe(pixels(source))
    expect(pixels(magick.readDDS(magick.dds(magick.new(0, 0))))).toBe '0x0:00000000'
    pin('readDDS noise', pixels(magick.readDDS(buffer.fromstring('DDS ' .. string.pack('<I4I4I4', 124, 0x100f, 6) .. string.pack('<I4', 7) .. string.rep('\0', 68) .. string.pack('<I4', 32) .. string.rep('\0', 36) .. noise(6 * 7 * 4, 402)))))
  end)

  suite.it('refuses a DDS it cannot read', function()
    local encoded = buffer.tostring(magick.dds(noisy(4, 4, 403)))

    local function read(file: string): () -> ()
      return function() magick.readDDS(buffer.fromstring(file)) end
    end

    expect(read 'DDS ').toThrow 'magick: not a DDS'
    expect(read('DDX ' .. string.sub(encoded, 5))).toThrow 'magick: not a DDS'
    expect(read(string.sub(encoded, 1, 88) .. string.pack('<I4', 24) .. string.sub(encoded, 93))).toThrow 'magick: only uncompressed 32-bit DDS is supported'
    expect(read(string.sub(encoded, 1, #encoded - 1))).toThrow()
  end)
end)

suite.describe('bmp', function()
  suite.it('reads 24-bit and 32-bit rows, bottom up and top down', function()
    pin('readBMP 24', pixels(magick.readBMP(bmp(7, 5, 24, false, 501))))
    pin('readBMP 24 top down', pixels(magick.readBMP(bmp(7, 5, 24, true, 502))))
    pin('readBMP 24 unpadded', pixels(magick.readBMP(bmp(8, 3, 24, false, 503))))
    pin('readBMP 32', pixels(magick.readBMP(bmp(7, 5, 32, false, 504))))
    pin('readBMP 32 top down', pixels(magick.readBMP(bmp(7, 5, 32, true, 505))))
    pin('readBMP larger header', pixels(magick.readBMP(bmp(7, 5, 32, false, 506, 0, 124))))
    pin('readBMP empty', pixels(magick.readBMP(bmp(0, 0, 24, false, 507))))
  end)

  suite.it('refuses a BMP it cannot read', function()
    expect(function() magick.readBMP(buffer.fromstring 'BM') end).toThrow 'magick: not a BMP'
    expect(function() magick.readBMP(buffer.fromstring('MB' .. string.rep('\0', 60))) end).toThrow 'magick: not a BMP'
    expect(function() magick.readBMP(bmp(7, 5, 24, false, 501, 0, 12)) end).toThrow 'magick: unsupported BMP DIB header'
    expect(function() magick.readBMP(bmp(7, 5, 24, false, 501, 1)) end).toThrow 'magick: compressed BMP not supported'
    expect(function() magick.readBMP(bmp(7, 5, 16, false, 501)) end).toThrow 'magick: only 24/32-bit BMP supported'
    expect(function() magick.readBMP(buffer.fromstring(string.sub(buffer.tostring(bmp(7, 5, 24, false, 501)), 1, 100))) end).toThrow()
  end)
end)

suite.describe('tga', function()
  suite.it('reads true color and gray, from any corner', function()
    pin('readTGA 24', pixels(magick.readTGA(tga(7, 5, 2, 24, 0, noise(7 * 5 * 3, 601)))))
    pin('readTGA 32', pixels(magick.readTGA(tga(7, 5, 2, 32, 8, noise(7 * 5 * 4, 602)))))
    pin('readTGA 32 top', pixels(magick.readTGA(tga(7, 5, 2, 32, 0x28, noise(7 * 5 * 4, 603)))))
    pin('readTGA 32 right', pixels(magick.readTGA(tga(7, 5, 2, 32, 0x18, noise(7 * 5 * 4, 604)))))
    pin('readTGA 24 top right', pixels(magick.readTGA(tga(7, 5, 2, 24, 0x30, noise(7 * 5 * 3, 605)))))
    pin('readTGA gray', pixels(magick.readTGA(tga(7, 5, 3, 8, 0, noise(7 * 5, 606)))))
    pin('readTGA gray top', pixels(magick.readTGA(tga(7, 5, 3, 8, 0x20, noise(7 * 5, 607)))))
    pin('readTGA identified', pixels(magick.readTGA(tga(7, 5, 2, 24, 0, noise(7 * 5 * 3, 608), 'made by hand'))))
    pin('readTGA empty', pixels(magick.readTGA(tga(0, 0, 2, 24, 0, ''))))
  end)

  suite.it('reads run-length packets, past the end of a row and of the image', function()
    pin('readTGA packets 24', pixels(magick.readTGA(tga(9, 7, 10, 24, 0, packets(63, 3, 611)))))
    pin('readTGA packets 32 top', pixels(magick.readTGA(tga(9, 7, 10, 32, 0x28, packets(63, 4, 612)))))
    pin('readTGA packets 32 right', pixels(magick.readTGA(tga(9, 7, 10, 32, 0x18, packets(63, 4, 613)))))
    pin('readTGA packets gray', pixels(magick.readTGA(tga(9, 7, 11, 8, 0, packets(63, 1, 614)))))
    pin('readTGA packets gray top right', pixels(magick.readTGA(tga(9, 7, 11, 8, 0x30, packets(63, 1, 615), 'id'))))
  end)

  suite.it('refuses a TGA it cannot read', function()
    local body = noise(7 * 5 * 4, 621)

    expect(function() magick.readTGA(buffer.fromstring 'short') end).toThrow 'magick: truncated TGA'
    expect(function() magick.readTGA(tga(7, 5, 2, 24, 0, body, nil, 1)) end).toThrow 'magick: color-mapped TGA not supported'
    expect(function() magick.readTGA(tga(7, 5, 1, 24, 0, body)) end).toThrow 'magick: unsupported TGA type'
    expect(function() magick.readTGA(tga(7, 5, 3, 16, 0, body)) end).toThrow 'magick: grayscale TGA must be 8-bit'
    expect(function() magick.readTGA(tga(7, 5, 2, 16, 0, body)) end).toThrow 'magick: truecolor TGA must be 24/32-bit'
    expect(function() magick.readTGA(tga(7, 5, 10, 8, 0, body)) end).toThrow 'magick: truecolor TGA must be 24/32-bit'
    expect(function() magick.readTGA(tga(7, 6, 2, 32, 0, body)) end).toThrow()
    expect(function() magick.readTGA(tga(7, 5, 10, 32, 0, '\x85\1\2\3')) end).toThrow()
  end)
end)

suite.describe('files', function()
  suite.it('writes and reads by extension', function()
    local source = noisy(11, 6, 701)
    local asPng, asDds = scratch 'written.PNG', scratch 'written.dds'

    expect(magick.write(asPng, source)).toBe(asPng)
    expect(magick.write(asDds, source)).toBe(asDds)
    pin('write png', digest(jess.fs.readBuffer(asPng)))
    pin('write dds', digest(jess.fs.readBuffer(asDds)))
    expect(pixels(magick.read(asPng))).toBe(pixels(source))
    expect(pixels(magick.read(asDds))).toBe(pixels(source))
    expect(pixels(magick.readPNG(asPng))).toBe(pixels(source))
    expect(magick.writePNG(scratch 'level.png', source, 1)).toBe(scratch 'level.png')
    pin('writePNG level', digest(jess.fs.readBuffer(scratch 'level.png')))
    expect(magick.writeDDS(scratch 'direct.dds', source)).toBe(scratch 'direct.dds')
    expect(digest(jess.fs.readBuffer(scratch 'direct.dds'))).toBe(digest(magick.dds(source)))
  end)

  suite.it('reads BMP and TGA files', function()
    local asBmp, asTga = scratch 'read.bmp', scratch 'read.TGA'

    jess.fs.write(asBmp, bmp(7, 5, 24, false, 711))
    jess.fs.write(asTga, tga(7, 5, 2, 32, 8, noise(7 * 5 * 4, 712)))
    pin('read bmp', pixels(magick.read(asBmp)))
    pin('read tga', pixels(magick.read(asTga)))
    expect(pixels(magick.readBMP(asBmp))).toBe(pixels(magick.read(asBmp)))
    expect(pixels(magick.readTGA(asTga))).toBe(pixels(magick.read(asTga)))
  end)

  suite.it('refuses a format it has no codec for', function()
    local source = noisy(3, 3, 721)

    expect(function() magick.read 'picture.webp' end).toThrow 'magick: unsupported input format .webp'
    expect(function() magick.read 'picture' end).toThrow 'magick: unsupported input format .'
    expect(function() magick.write('picture.bmp', source) end).toThrow 'magick: unsupported output format .bmp'
    expect(function() magick.write('folder.png/picture', source) end).toThrow 'magick: unsupported output format .'
  end)
end)

suite.it('holds every golden to something', function() expect(unused()).toEqual {} end)

return suite
