--!strict
--!native
-- What the raster and codec suites share: seeded fixtures, fingerprints of what an operation
-- left behind, and the goldens every operation is held to, which were recorded from the package
-- as it was imported.
local bytes = require '@dream/bytes'
local magick = require '@magick'
local test = require '@jess/test'

export type Image = typeof(magick.new(1, 1))
export type Mask = typeof(magick.mask(1, 1, buffer.create(1)))
export type Random = (bound: number) -> number

--- A xorshift32 generator: `random(bound)` is in `0..bound-1`.
local function generator(seed: number): Random
  local state = seed

  return function(bound: number): number
    state = bit32.bxor(state, bit32.lshift(state, 13))
    state = bit32.bxor(state, bit32.rshift(state, 17))
    state = bit32.bxor(state, bit32.lshift(state, 5))

    return state % bound
  end
end

--- `length` bytes of noise.
local function noise(length: number, seed: number): string
  local random = generator(seed)
  local out = buffer.create(length)

  for offset = 0, length - 1 do
    buffer.writeu8(out, offset, random(256))
  end

  return buffer.tostring(out)
end

--- Noise in every channel: a quarter of the pixels are clear, a quarter opaque, the rest
--- anything, and a clear pixel keeps its color.
local function noisy(width: number, height: number, seed: number): Image
  local random = generator(seed)
  local pixels = buffer.create(width * height * 4)

  for offset = 0, buffer.len(pixels) - 4, 4 do
    local kind = random(4)
    local alpha = if kind == 0 then 0 elseif kind == 1 then 255 else random(256)

    buffer.writeu8(pixels, offset, random(256))
    buffer.writeu8(pixels, offset + 1, random(256))
    buffer.writeu8(pixels, offset + 2, random(256))
    buffer.writeu8(pixels, offset + 3, alpha)
  end

  return magick.fromRGBA(width, height, pixels)
end

--- A sprite: a clear margin, a soft band inside it, and an opaque body of noise, so whole rows
--- and long runs are clear or opaque.
local function sprite(width: number, height: number, seed: number): Image
  local random = generator(seed)
  local pixels = buffer.create(width * height * 4)

  for row = 0, height - 1 do
    for column = 0, width - 1 do
      local edge = math.min(column, row, width - 1 - column, height - 1 - row)
      local alpha = if edge < 2 then 0 elseif edge < 4 then 64 + random(128) else 255
      local offset = (row * width + column) * 4

      buffer.writeu8(pixels, offset, random(256))
      buffer.writeu8(pixels, offset + 1, random(256))
      buffer.writeu8(pixels, offset + 2, random(256))
      buffer.writeu8(pixels, offset + 3, alpha)
    end
  end

  return magick.fromRGBA(width, height, pixels)
end

--- A coverage mask: runs of clear, of full and of soft bytes, up to nine long.
local function coverage(width: number, height: number, seed: number): Mask
  local random = generator(seed)
  local count = width * height
  local covered = buffer.create(count)
  local offset = 0

  while offset < count do
    local kind = random(3)

    for _ = 1, math.min(1 + random(9), count - offset) do
      buffer.writeu8(covered, offset, if kind == 0 then 0 elseif kind == 1 then 255 else random(256))
      offset += 1
    end
  end

  return magick.mask(width, height, covered)
end

--- The length of some bytes and their CRC-32.
local function digest(data: buffer | string): string
  local length = if type(data) == 'string' then #data else buffer.len(data)

  return `{length}:{string.format('%08x', bytes.crc32(data))}`
end

--- The geometry of an image or a mask and the CRC-32 of its bytes.
local function pixels(image: Image | Mask): string
  return `{image.width}x{image.height}:{string.format('%08x', bytes.crc32(image.data))}`
end

--- Holds named observations to their goldens. `pin` notes a miss instead of raising, and
--- `settle`, run after each case, fails the case with every miss written as a line of the golden
--- table, so one run of a suite says what all of its goldens would have to be. `unused` names the
--- goldens nothing was held to.
local function goldens(
  recorded: { [string]: string }
): ((name: string, observed: string) -> (), () -> (), () -> { string })
  local misses: { string } = {}
  local seen: { [string]: boolean } = {}

  local function pin(name: string, observed: string)
    assert(not seen[name], `the golden '{name}' is pinned twice`)
    seen[name] = true

    if recorded[name] ~= observed then table.insert(misses, `['{name}'] = '{observed}',`) end
  end

  local function settle()
    local missed = table.concat(misses, '\n')

    table.clear(misses)
    test.expect(missed).toBe ''
  end

  local function unused(): { string }
    local names: { string } = {}

    for name in recorded do
      if not seen[name] then table.insert(names, name) end
    end

    table.sort(names)

    return names
  end

  return pin, settle, unused
end

return table.freeze {
  coverage = coverage,
  digest = digest,
  generator = generator,
  goldens = goldens,
  noise = noise,
  noisy = noisy,
  pixels = pixels,
  sprite = sprite,
}
