--!native
--!optimize 2
-- Pure-Luau raster subset used by the Morrowind UI generator port.
-- Semantics are intentionally ImageMagick-shaped, not a full CLI clone.
local bytes = require '@dream/bytes'
local dataPlane = require '@dream/data'

local Magick = {}
local Image = {}
Image.__index = Image

type Pixels = { width: number, height: number, data: buffer }

--- RGBA pixels, four bytes each, in rows from the top.
export type Image = typeof(setmetatable({} :: Pixels, Image))

--- One byte of coverage a pixel, in rows from the top.
export type Mask = { width: number, height: number, data: buffer }

--- `#rgb`, `#rrggbb` or `#rrggbbaa`, with or without the `#`, or channels by position or by
--- name, where a color channel left out is 0 and an alpha left out is 255.
export type Color = string | { number } | { r: number?, g: number?, b: number?, a: number? }

--- What a shape is filled from: a color, or an image repeated as a tile.
export type Source = Color | Image

--- A channel as the byte it is stored as: clamped, and rounded half up. The clamp comes first and
--- by `math.clamp`, not by comparing, so a loop that rounds a channel has no branch in it.
local function clamp8(value: number): number
  return math.floor(math.clamp(value, 0, 255) + 0.5)
end

local function colorTable(color: Color?): { number }
  -- `false` is not a color and is refused below; only nothing at all is the clear color.
  if type(color) == 'nil' then return { 0, 0, 0, 0 } end

  if type(color) == 'table' then
    local fields = color :: { [number | string]: number? }

    return { fields[1] or fields.r or 0, fields[2] or fields.g or 0, fields[3] or fields.b or 0, fields[4] or fields.a or 255 }
  end

  if type(color) ~= 'string' then error('magick: color must be a table or hex string', 2) end

  local digits = if string.sub(color, 1, 1) == '#' then string.sub(color, 2) else color

  if #digits == 3 then
    local red, green, blue = string.sub(digits, 1, 1), string.sub(digits, 2, 2), string.sub(digits, 3, 3)

    digits = red .. red .. green .. green .. blue .. blue
  end

  if #digits ~= 6 and #digits ~= 8 then error('magick: expected #rgb, #rrggbb, or #rrggbbaa', 2) end

  local red = tonumber(string.sub(digits, 1, 2), 16)
  local green = tonumber(string.sub(digits, 3, 4), 16)
  local blue = tonumber(string.sub(digits, 5, 6), 16)
  -- Alpha digits that are not hex leave the color opaque.
  local alpha = #digits == 8 and tonumber(string.sub(digits, 7, 8), 16) or 255

  if not red or not green or not blue then error('magick: invalid color', 2) end

  return { red, green, blue, alpha }
end

Magick.color = colorTable

--- The pixel a color packs to. A channel that is not a byte is not clamped: its excess carries
--- into the channels above it, and a fraction is dropped when the pixel is stored.
local function packed(channels: { number }): number
  return channels[1] + channels[2] * 256 + channels[3] * 65536 + channels[4] * 16777216
end

--- Repeats the `size` bytes at `offset` until `length` bytes from `offset` hold them. Each copy
--- doubles what is filled, so a fill is a handful of block copies however long it is.
local function replicate(target: buffer, offset: number, size: number, length: number)
  local filled = size

  while filled < length do
    local step = math.min(filled, length - filled)

    buffer.copy(target, offset + filled, target, offset, step)
    filled += step
  end
end

function Image.fill(self: Image, color: Color?): Image
  local pixels = self.data
  local length = buffer.len(pixels)
  local pixel = packed(colorTable(color))

  if length < 4 then return self end

  buffer.writeu32(pixels, 0, pixel)
  replicate(pixels, 0, 4, length - length % 4)

  return self
end

function Magick.new(width: number, height: number, color: Color?): Image
  assert(
    width >= 0 and height >= 0 and width == math.floor(width) and height == math.floor(height),
    'magick: integer image size required'
  )

  local image = setmetatable({ width = width, height = height, data = buffer.create(width * height * 4) }, Image)
  local channels = colorTable(color)

  if channels[1] ~= 0 or channels[2] ~= 0 or channels[3] ~= 0 or channels[4] ~= 0 then image:fill(channels) end

  return image
end

function Magick.fromRGBA(width: number, height: number, data: buffer): Image
  if buffer.len(data) ~= width * height * 4 then error('magick: RGBA byte length does not match geometry', 2) end

  local out = Magick.new(width, height)

  buffer.copy(out.data, 0, data, 0, buffer.len(data))

  return out
end

function Image.clone(self: Image): Image
  return Magick.fromRGBA(self.width, self.height, self.data)
end

--- The channels of the pixel at a column and a row, or four zeros outside the image.
function Image.get(self: Image, column: number, row: number): (number, number, number, number)
  local {width, height, data} = self

  if column < 0 or row < 0 or column >= width or row >= height then return 0, 0, 0, 0 end

  local offset = (row * width + column) * 4

  return buffer.readu8(data, offset),
    buffer.readu8(data, offset + 1),
    buffer.readu8(data, offset + 2),
    buffer.readu8(data, offset + 3)
end

--- Stores a pixel, each channel clamped and rounded to a byte; a pixel outside the image is not
--- stored.
function Image.set(self: Image, column: number, row: number, red: number, green: number, blue: number, alpha: number): Image
  local {width, height, data} = self

  if column < 0 or row < 0 or column >= width or row >= height then return self end

  local offset = (row * width + column) * 4

  buffer.writeu8(data, offset, clamp8(red))
  buffer.writeu8(data, offset + 1, clamp8(green))
  buffer.writeu8(data, offset + 2, clamp8(blue))
  buffer.writeu8(data, offset + 3, clamp8(alpha))

  return self
end

--- The image `source` is, when it is one to repeat as a tile and not a color: a table with pixels
--- and a width.
local function tileOf(source: unknown): Image?
  if type(source) ~= 'table' then return nil end

  local fields = source :: { [string]: unknown }

  if fields.data == nil or fields.width == nil then return nil end

  return source :: Image
end

local function sampleTile(tile: Image, column: number, row: number): (number, number, number, number)
  local wrappedColumn, wrappedRow = column % tile.width, row % tile.height

  if wrappedColumn < 0 then wrappedColumn += tile.width end
  if wrappedRow < 0 then wrappedRow += tile.height end

  return tile:get(wrappedColumn, wrappedRow)
end

local function sourcePixel(source: Source?, column: number, row: number): (number, number, number, number)
  local tile = tileOf(source)

  if tile then return sampleTile(tile, column, row) end

  local channels = colorTable(source :: Color?)

  return channels[1], channels[2], channels[3], channels[4]
end

--- Whether a tile's pixels can be copied a run at a time into `target`: it is an image made here,
--- of at least a pixel, whose buffer holds exactly its rows and is not the one being drawn on.
--- Anything else is sampled pixel by pixel through its own `get`.
local function repeatable(tile: Image, target: buffer): boolean
  local {width, height, data} = tile

  return getmetatable(tile) == Image
    and data ~= target
    and width >= 1
    and height >= 1
    and width % 1 == 0
    and height % 1 == 0
    and buffer.len(data) == width * height * 4
end

--- Fills the rectangle between two corners, both inside it, clipped to the image.
function Image.rect(self: Image, x0: number, y0: number, x1: number, y1: number, source: Source?): Image
  if x0 > x1 then x0, x1 = x1, x0 end
  if y0 > y1 then y0, y1 = y1, y0 end

  local left, top = math.max(0, math.floor(x0)), math.max(0, math.floor(y0))
  local right, bottom = math.min(self.width - 1, math.floor(x1)), math.min(self.height - 1, math.floor(y1))

  if left > right or top > bottom then return self end

  local tile = tileOf(source)
  local pixels, stride = self.data, self.width * 4
  local first, span = top * stride + left * 4, (right - left + 1) * 4

  if tile and repeatable(tile, pixels) then
    local {width: tileWidth, height: tileHeight, data: tilePixels} = tile
    local phase = left % tileWidth
    local lead = math.min((tileWidth - phase) * 4, span)

    for row = top, bottom do
      local at = row * stride + left * 4

      -- A row repeats the one a tile's height above it.
      if row - top >= tileHeight then
        buffer.copy(pixels, at, pixels, at - tileHeight * stride, span)
        continue
      end

      local from = (row % tileHeight) * tileWidth * 4
      local done = lead

      buffer.copy(pixels, at, tilePixels, from + phase * 4, lead)

      while done < span do
        local run = math.min(tileWidth * 4, span - done)

        buffer.copy(pixels, at + done, tilePixels, from, run)
        done += run
      end
    end

    return self
  end

  if tile then
    for row = top, bottom do
      for column = left, right do
        local red, green, blue, alpha = sampleTile(tile, column, row)

        self:set(column, row, red, green, blue, alpha)
      end
    end

    return self
  end

  buffer.writeu32(pixels, first, packed(colorTable(source :: Color?)))
  replicate(pixels, first, 4, span)

  for row = top + 1, bottom do
    buffer.copy(pixels, row * stride + left * 4, pixels, first, span)
  end

  return self
end

local Scratch = buffer.create(4)

--- The pixel `set` stores for four channels: each clamped and rounded to its own byte.
local function stored(red: number, green: number, blue: number, alpha: number): number
  buffer.writeu8(Scratch, 0, clamp8(red))
  buffer.writeu8(Scratch, 1, clamp8(green))
  buffer.writeu8(Scratch, 2, clamp8(blue))
  buffer.writeu8(Scratch, 3, clamp8(alpha))

  return buffer.readu32(Scratch, 0)
end

--- Stores what a shape's source gives for a column and a row: the pixel of a tile, sampled
--- through its `get`, or the source's color. The color is read here, at a pixel the shape
--- covers, so a shape that covers nothing never refuses its color; the pixel it packs to is
--- returned for the shape to store itself from then on.
local function paint(image: Image, offset: number, column: number, row: number, source: Source?, tile: Image?): number?
  if tile then
    local red, green, blue, alpha = sampleTile(tile, column, row)

    image:set(column, row, red, green, blue, alpha)

    return nil
  end

  local channels = colorTable(source :: Color?)
  local pixel = stored(channels[1], channels[2], channels[3], channels[4])

  buffer.writeu32(image.data, offset, pixel)

  return pixel
end

--- Fills a polygon by the even-odd rule: a pixel is inside when an odd number of edges cross its
--- row to the right of its center.
function Image.polygon(self: Image, points: { { number } }, source: Source?): Image
  local {width, height, data} = self
  local left, top, right, bottom = width - 1, height - 1, 0, 0

  for _, point in points do
    left, top = math.min(left, point[1]), math.min(top, point[2])
    right, bottom = math.max(right, point[1]), math.max(bottom, point[2])
  end

  left, top = math.max(0, math.floor(left)), math.max(0, math.floor(top))
  right, bottom = math.min(width - 1, math.ceil(right)), math.min(height - 1, math.ceil(bottom))

  if left > right then return self end

  local tile = tileOf(source)
  local tilePixels = if tile and repeatable(tile, data) then tile.data else nil
  local tileWidth, tileHeight = if tile then tile.width else 0, if tile then tile.height else 0
  local count = #points
  local crossings: { number } = table.create(count)
  local color: number? = nil

  for row = top, bottom do
    local level = row + 0.5
    local crossed, last = 0, count

    for index = 1, count do
      local fromColumn, fromRow = points[index][1], points[index][2]
      local toColumn, toRow = points[last][1], points[last][2]

      if (fromRow > level) ~= (toRow > level) then
        local rise = if toRow - fromRow == 0 then 1e-12 else toRow - fromRow

        crossed += 1
        crossings[crossed] = (toColumn - fromColumn) * (level - fromRow) / rise + fromColumn
      end

      last = index
    end

    local offset = (row * width + left) * 4

    for column = left, right do
      local center = column + 0.5
      local inside = false

      for index = 1, crossed do
        if center < crossings[index] then inside = not inside end
      end

      if not inside then
        offset += 4
        continue
      end

      if color then
        buffer.writeu32(data, offset, color)
      elseif tilePixels then
        buffer.writeu32(data, offset, buffer.readu32(tilePixels, (row % tileHeight * tileWidth + column % tileWidth) * 4))
      else
        color = paint(self, offset, column, row, source, tile)
      end

      offset += 4
    end
  end

  return self
end

--- Fills an ellipse about a center: a pixel is inside when its center is.
function Image.circle(self: Image, cx: number, cy: number, rx: number, ry: number?, source: Source?): Image
  local {width, height, data} = self
  local radiusY = ry or rx
  local left, right = math.max(0, math.floor(cx - rx)), math.min(width - 1, math.ceil(cx + rx))
  local top, bottom = math.max(0, math.floor(cy - radiusY)), math.min(height - 1, math.ceil(cy + radiusY))
  local tile = tileOf(source)
  local tilePixels = if tile and repeatable(tile, data) then tile.data else nil
  local tileWidth, tileHeight = if tile then tile.width else 0, if tile then tile.height else 0
  local color: number? = nil

  for row = top, bottom do
    local down = (row + 0.5 - cy) / radiusY
    local offset = (row * width + left) * 4

    for column = left, right do
      local across = (column + 0.5 - cx) / rx
      local inside = across * across + down * down <= 1

      if not inside then
        offset += 4
        continue
      end

      if color then
        buffer.writeu32(data, offset, color)
      elseif tilePixels then
        buffer.writeu32(data, offset, buffer.readu32(tilePixels, (row % tileHeight * tileWidth + column % tileWidth) * 4))
      else
        color = paint(self, offset, column, row, source, tile)
      end

      offset += 4
    end
  end

  return self
end

local function overPixel(
  underRed: number,
  underGreen: number,
  underBlue: number,
  underAlpha: number,
  red: number,
  green: number,
  blue: number,
  alpha: number
): (number, number, number, number)
  local opacity, underOpacity = alpha / 255, underAlpha / 255
  local covered = opacity + underOpacity * (1 - opacity)

  if covered <= 0 then return 0, 0, 0, 0 end

  return clamp8((red * opacity + underRed * underOpacity * (1 - opacity)) / covered),
    clamp8((green * opacity + underGreen * underOpacity * (1 - opacity)) / covered),
    clamp8((blue * opacity + underBlue * underOpacity * (1 - opacity)) / covered),
    clamp8(covered * 255)
end

--- The least pixel that is opaque and the least that is not clear, as numbers: alpha is a pixel's
--- high byte.
local Opaque, Faint = 0xff000000, 0x01000000

--- Composites the pixels `first..last` of a run over what is there, one at a time: a pixel is
--- read after the one before it is written, which an image laid over itself depends on.
local function blend(from: buffer, sourceAt: number, to: buffer, at: number, first: number, last: number)
  for _ = first, last do
    local pixel = buffer.readu32(from, sourceAt)
    local alpha = bit32.rshift(pixel, 24)

    if alpha == 255 then
      buffer.writeu32(to, at, pixel)
    elseif alpha ~= 0 then
      local under = buffer.readu32(to, at)
      local red, green, blue =
        bit32.band(pixel, 255), bit32.band(bit32.rshift(pixel, 8), 255), bit32.band(bit32.rshift(pixel, 16), 255)
      local underRed, underGreen, underBlue =
        bit32.band(under, 255), bit32.band(bit32.rshift(under, 8), 255), bit32.band(bit32.rshift(under, 16), 255)
      local opacity, underOpacity = alpha / 255, bit32.rshift(under, 24) / 255
      local covered = opacity + underOpacity * (1 - opacity)

      if covered > 0 then
        local outRed = clamp8((red * opacity + underRed * underOpacity * (1 - opacity)) / covered)
        local outGreen = clamp8((green * opacity + underGreen * underOpacity * (1 - opacity)) / covered)
        local outBlue = clamp8((blue * opacity + underBlue * underOpacity * (1 - opacity)) / covered)

        buffer.writeu32(to, at, outRed + outGreen * 256 + outBlue * 65536 + clamp8(covered * 255) * 16777216)
      end
    end

    sourceAt += 4
    at += 4
  end
end

--- Composites `source` over the image, its top left corner at an offset from the image's.
function Image.over(self: Image, source: Image, dx: number?, dy: number?): Image
  local across, down = dx or 0, dy or 0
  local left, top = math.max(0, -across), math.max(0, -down)
  local right, bottom = math.min(source.width, self.width - across), math.min(source.height, self.height - down)

  if left >= right or top >= bottom then return self end

  local from, to = source.data, self.data
  local sourceWidth, width = source.width, self.width
  -- A row is tested and copied whole only between two buffers and at a whole offset: an image
  -- laid over itself is composited pixel by pixel.
  local wholeRows = from ~= to and across % 1 == 0 and down % 1 == 0

  for row = top, bottom - 1 do
    local sourceAt = (row * sourceWidth + left) * 4
    local at = ((row + down) * width + (left + across)) * 4

    if wholeRows then
      -- The first pixel says which of the two a row can still be, so a mixed row costs one look.
      local lead = buffer.readu32(from, sourceAt)
      local first, last = row * sourceWidth + left + 1, row * sourceWidth + right

      if lead >= Opaque and all[for pixel in from[first:last, 'u32'] => pixel >= Opaque] then
        buffer.copy(to, at, from, sourceAt, (right - left) * 4)
        continue
      end

      if lead < Faint and not any[for pixel in from[first:last, 'u32'] => pixel >= Faint] then continue end
    end

    blend(from, sourceAt, to, at, left, right - 1)
  end

  return self
end

function Image:overMask(mask,color,dx,dy)
    dx=dx or 0; dy=dy or 0
    local c=colorTable(color); local sx0=math.max(0,-dx); local sy0=math.max(0,-dy)
    local sx1=math.min(mask.width,self.width-dx); local sy1=math.min(mask.height,self.height-dy)
    if sx0>=sx1 or sy0>=sy1 then return self end
    local md=mask.data; local dd=self.data; local mw=mask.width; local dw=self.width; local opaqueSource=c[4]==255; local alphaScale=c[4]/255; local rgb=c[1]+c[2]*256+c[3]*65536; local opaquePixel=rgb+4278190080
    for sy=sy0,sy1-1 do
        local x=sx0; local mo=sy*mw+sx0; local doff=((sy+dy)*dw+(sx0+dx))*4
        while x<sx1 do
            if x+4<=sx1 then
                local maskWord=buffer.readu32(md,mo)
                if maskWord==0 then x+=4; mo+=4; doff+=16; continue end
                if opaqueSource and maskWord==4294967295 then
                    buffer.writeu32(dd,doff,opaquePixel); buffer.writeu32(dd,doff+4,opaquePixel); buffer.writeu32(dd,doff+8,opaquePixel); buffer.writeu32(dd,doff+12,opaquePixel)
                    x+=4; mo+=4; doff+=16; continue
                end
            end
            local maskAlpha=buffer.readu8(md,mo); local sa=if opaqueSource then maskAlpha else clamp8(maskAlpha*alphaScale)
            if sa==255 then
                buffer.writeu32(dd,doff,opaquePixel)
            elseif sa~=0 then
                local dp=buffer.readu32(dd,doff); local da=bit32.rshift(dp,24)
                local dr=bit32.band(dp,255); local dg=bit32.band(bit32.rshift(dp,8),255); local db=bit32.band(bit32.rshift(dp,16),255)
                local af=sa/255
                local rr,gg,bb,aa
                if da==255 then
                    local inv=1-af; rr=clamp8(c[1]*af+dr*inv); gg=clamp8(c[2]*af+dg*inv); bb=clamp8(c[3]*af+db*inv); aa=255
                else
                    local daf=da/255; local oa=af+daf*(1-af); rr=clamp8((c[1]*af+dr*daf*(1-af))/oa); gg=clamp8((c[2]*af+dg*daf*(1-af))/oa); bb=clamp8((c[3]*af+db*daf*(1-af))/oa); aa=clamp8(oa*255)
                end
                buffer.writeu32(dd,doff,rr+gg*256+bb*65536+aa*16777216)
            end
            x+=1; mo+=1; doff+=4
        end
    end
    return self
end

--- Composites the alpha of `mask`, an image of this one's size, into this one's: `dstin` keeps
--- what the mask covers, `dstout` what it leaves, and `copy` takes the mask's alpha as it is.
function Image.copyAlpha(self: Image, mask: Image, mode: string): Image
  assert(self.width == mask.width and self.height == mask.height, 'magick: mask geometry mismatch')

  local count = self.width * self.height
  local pixels, maskPixels = self.data, mask.data

  if count == 0 then return self end

  if mode == 'copy' then
    dataPlane.scale(maskPixels, 'u8@4', 3, count, 1, pixels, 3)

    return self
  end

  if mode ~= 'dstin' and mode ~= 'dstout' then
    error('magick: unknown alpha composite mode ' .. tostring(mode), 2)
  end

  -- What the mask keeps of a pixel's alpha is its own alpha or what that lacks of opaque: one
  -- sum of whole numbers either way, so the loop does not choose per pixel.
  local base, sign = if mode == 'dstin' then 0 else 255, if mode == 'dstin' then 1 else -1

  for offset = 3, count * 4 - 1, 4 do
    local kept = base + sign * buffer.readu8(maskPixels, offset)

    buffer.writeu8(pixels, offset, clamp8(buffer.readu8(pixels, offset) * kept / 255))
  end

  return self
end

--- A copy of a rectangle of the image, clear where the rectangle is outside it.
function Image.crop(self: Image, width: number, height: number, left: number, top: number): Image
  local out = Magick.new(width, height)

  if width <= 0 or height <= 0 then return out end

  local firstColumn, firstRow = math.max(0, left), math.max(0, top)
  local endColumn, endRow = math.min(self.width, left + width), math.min(self.height, top + height)

  if firstColumn >= endColumn or firstRow >= endRow then return out end

  local span = (endColumn - firstColumn) * 4

  for row = firstRow, endRow - 1 do
    local to, from = ((row - top) * width + (firstColumn - left)) * 4, (row * self.width + firstColumn) * 4

    buffer.copy(out.data, to, self.data, from, span)
  end

  return out
end

--- A new image of a size, filled with a background, with this one laid over it at an offset.
function Image.extent(self: Image, width: number, height: number, dx: number?, dy: number?, background: Color?): Image
  return Magick.new(width, height, background):over(self, dx or 0, dy or 0)
end

--- The image cropped to the box of its pixels that are not clear, or one clear pixel when it has
--- none.
function Image.trim(self: Image): Image
  local {width, height, data} = self
  local top, bottom = height, height - 1

  for row = 0, height - 1 do
    local first, last = row * width + 1, (row + 1) * width

    if any[for pixel in data[first:last, 'u32'] => pixel >= Faint] then
      top = row
      break
    end
  end

  if top == height then return Magick.new(1, 1) end

  for row = height - 1, top, -1 do
    local first, last = row * width + 1, (row + 1) * width

    if any[for pixel in data[first:last, 'u32'] => pixel >= Faint] then
      bottom = row
      break
    end
  end

  -- The row at the top has a pixel that is not clear, so both walks stop inside the image.
  local rows, alphaDown = bottom - top + 1, `u8@{width * 4}`
  local left, right = 0, width - 1

  while not dataPlane.any(data, alphaDown, (top * width + left) * 4 + 3, rows, 'ne', 0) do
    left += 1
  end

  while not dataPlane.any(data, alphaDown, (top * width + right) * 4 + 3, rows, 'ne', 0) do
    right -= 1
  end

  return self:crop(right - left + 1, rows, left, top)
end

--- A quarter turn, clockwise or counterclockwise.
function Image.rotate90(self: Image, clockwise: boolean?): Image
  local {width, height, data} = self
  local out = Magick.new(height, width)

  if width == 0 or height == 0 then return out end

  -- A row becomes a column: its pixels are scattered down the output a row of the output apart,
  -- in order when the turn is clockwise and from the bottom up when it is not.
  local order, down = buffer.create(width * 4), `u32@{height * 4}`

  into(order, 'u32')[for column in range(0, width - 1) => if clockwise then column else width - 1 - column]

  for row = 0, height - 1 do
    local to = if clockwise then height - 1 - row else row

    dataPlane.scatter(data, down, row * width * 4, width, order, out.data, to * 4, width)
  end

  return out
end

--- A value between four corners: across the upper pair and the lower pair, then down between
--- the two.
local function between(
  upperLeft: number,
  upperRight: number,
  lowerLeft: number,
  lowerRight: number,
  across: number,
  down: number
): number
  local upper = upperLeft + (upperRight - upperLeft) * across
  local lower = lowerLeft + (lowerRight - lowerLeft) * across

  return upper + (lower - upper) * down
end

--- A copy of another size: each pixel is the nearest one of this image, or else the blend of the
--- four around where its center falls.
function Image.resize(self: Image, width: number, height: number, nearest: boolean?): Image
  local out = Magick.new(width, height)
  local {width: sourceWidth, height: sourceHeight, data: from} = self
  local to = out.data

  if width == 0 or height == 0 or sourceWidth == 0 or sourceHeight == 0 then return out end

  if nearest then
    local columns = buffer.create(width * 4)
    local previous = -1

    into(columns, 'u32')[
      for column in range(0, width - 1)
      => math.max(0, math.min(sourceWidth - 1, math.floor((column + 0.5) * sourceWidth / width - 0.5 + 0.5)))
    ]

    for row = 0, height - 1 do
      local sourceRow = math.max(0, math.min(sourceHeight - 1, math.floor((row + 0.5) * sourceHeight / height - 0.5 + 0.5)))

      if sourceRow == previous then
        buffer.copy(to, row * width * 4, to, (row - 1) * width * 4, width * 4)
      else
        dataPlane.gather(from, 'u32', sourceRow * sourceWidth * 4, sourceWidth, columns, to, row * width * 4)
        previous = sourceRow
      end
    end

    return out
  end

  -- Where each column of the output falls is the same on every row: the byte offsets of the
  -- pixels to its left and right within a row, and how far it is from the left one.
  local lefts, rights, weights = buffer.create(width * 4), buffer.create(width * 4), buffer.create(width * 8)

  for column = 0, width - 1 do
    local center = (column + 0.5) * sourceWidth / width - 0.5
    local left = math.floor(center)
    local across = center - left

    if left < 0 then
      left, across = 0, 0
    end

    buffer.writeu32(lefts, column * 4, left * 4)
    buffer.writeu32(rights, column * 4, math.min(sourceWidth - 1, left + 1) * 4)
    buffer.writef64(weights, column * 8, across)
  end

  for row = 0, height - 1 do
    local center = (row + 0.5) * sourceHeight / height - 0.5
    local top = math.floor(center)
    local down = center - top

    if top < 0 then
      top, down = 0, 0
    end

    local upper, lower = top * sourceWidth * 4, math.min(sourceHeight - 1, top + 1) * sourceWidth * 4
    local offset = row * width * 4

    for column = 0, width - 1 do
      local left, right = buffer.readu32(lefts, column * 4), buffer.readu32(rights, column * 4)
      local across = buffer.readf64(weights, column * 8)
      local upperLeft, upperRight, lowerLeft, lowerRight = upper + left, upper + right, lower + left, lower + right
      local red = clamp8(between(
        buffer.readu8(from, upperLeft),
        buffer.readu8(from, upperRight),
        buffer.readu8(from, lowerLeft),
        buffer.readu8(from, lowerRight),
        across,
        down
      ))
      local green = clamp8(between(
        buffer.readu8(from, upperLeft + 1),
        buffer.readu8(from, upperRight + 1),
        buffer.readu8(from, lowerLeft + 1),
        buffer.readu8(from, lowerRight + 1),
        across,
        down
      ))
      local blue = clamp8(between(
        buffer.readu8(from, upperLeft + 2),
        buffer.readu8(from, upperRight + 2),
        buffer.readu8(from, lowerLeft + 2),
        buffer.readu8(from, lowerRight + 2),
        across,
        down
      ))
      local alpha = clamp8(between(
        buffer.readu8(from, upperLeft + 3),
        buffer.readu8(from, upperRight + 3),
        buffer.readu8(from, lowerLeft + 3),
        buffer.readu8(from, lowerRight + 3),
        across,
        down
      ))

      buffer.writeu32(to, offset, red + green * 256 + blue * 65536 + alpha * 16777216)
      offset += 4
    end
  end

  return out
end

--- A turn by any angle about the center, into an image large enough to hold it: each pixel is
--- the blend of the four around where it came from, and clear where it came from outside.
function Image.rotate(self: Image, angleDegrees: number): Image
  local {width, height, data: from} = self
  local angle = angleDegrees * math.pi / 180
  local cosine, sine = math.cos(angle), math.sin(angle)
  local outWidth = math.max(1, math.ceil(math.abs(width * cosine) + math.abs(height * sine)) + 2)
  local outHeight = math.max(1, math.ceil(math.abs(width * sine) + math.abs(height * cosine)) + 1)
  local out = Magick.new(outWidth, outHeight)
  local centerX, centerY = (width - 1) / 2, (height - 1) / 2
  local outCenterX, outCenterY = (outWidth - 1) / 2, (outHeight - 1) / 2
  local to = out.data

  for row = 0, outHeight - 1 do
    local dy = row - outCenterY

    for column = 0, outWidth - 1 do
      local dx = column - outCenterX
      local sourceX, sourceY = cosine * dx + sine * dy + centerX, -sine * dx + cosine * dy + centerY

      if not (sourceX >= 0 and sourceY >= 0 and sourceX <= width - 1 and sourceY <= height - 1) then continue end

      local left, top = math.floor(sourceX), math.floor(sourceY)
      local across, down = sourceX - left, sourceY - top
      local upper, lower = top * width * 4, math.min(height - 1, top + 1) * width * 4
      local nearer, farther = left * 4, math.min(width - 1, left + 1) * 4
      local upperLeft, upperRight, lowerLeft, lowerRight = upper + nearer, upper + farther, lower + nearer, lower + farther
      local red = clamp8(between(
        buffer.readu8(from, upperLeft),
        buffer.readu8(from, upperRight),
        buffer.readu8(from, lowerLeft),
        buffer.readu8(from, lowerRight),
        across,
        down
      ))
      local green = clamp8(between(
        buffer.readu8(from, upperLeft + 1),
        buffer.readu8(from, upperRight + 1),
        buffer.readu8(from, lowerLeft + 1),
        buffer.readu8(from, lowerRight + 1),
        across,
        down
      ))
      local blue = clamp8(between(
        buffer.readu8(from, upperLeft + 2),
        buffer.readu8(from, upperRight + 2),
        buffer.readu8(from, lowerLeft + 2),
        buffer.readu8(from, lowerRight + 2),
        across,
        down
      ))
      local alpha = clamp8(between(
        buffer.readu8(from, upperLeft + 3),
        buffer.readu8(from, upperRight + 3),
        buffer.readu8(from, lowerLeft + 3),
        buffer.readu8(from, lowerRight + 3),
        across,
        down
      ))

      buffer.writeu32(to, (row * outWidth + column) * 4, red + green * 256 + blue * 65536 + alpha * 16777216)
    end
  end

  return out
end

--- Where a seeded generator starts: a whole number in `1..2^31-2`.
local function seeded(seed: number?): number
  local state = math.floor(seed or 1) % 2147483647

  return if state <= 0 then 1 else state
end

--- The next two standard normal deviates of the generator (Lehmer's, by 48271, turned to
--- deviates as Box and Muller do), and its state after them. The first is the one a caller that
--- wants one at a time takes first.
local function deviates(state: number): (number, number, number)
  local first = state * 48271 % 2147483647
  local second = first * 48271 % 2147483647
  local reach = math.sqrt(-2 * math.log(math.max(1e-12, first / 2147483647)))
  local turn = 2 * math.pi * (second / 2147483647)

  return reach * math.cos(turn), reach * math.sin(turn), second
end

--- An image of a color with seeded Gaussian noise in its color channels.
function Magick.noise(width: number, height: number, color: Color?, seed: number?, attenuate: number?): Image
  local channels = colorTable(color)
  local out = Magick.new(width, height)
  local pixels, length = out.data, width * height * 4
  local state = seeded(seed or 1)
  -- ImageMagick's Gaussian noise on a flat color behaves multiplicatively: zero channels stay
  -- exactly zero and nonzero channels share almost the same per-pixel factor.  At attenuate=.25
  -- the measured sigma is ~7.84% of the channel value.
  local sigma = (attenuate or 0.25) * 0.3137254901960784
  local red, green, blue, alpha = channels[1], channels[2], channels[3], clamp8(channels[4])

  -- A pixel takes one deviate and they come two at a time, so pixels are made in pairs.
  for offset = 0, length - 4, 8 do
    local first, second
    first, second, state = deviates(state)

    local factor = 1 + first * sigma

    buffer.writeu8(pixels, offset, clamp8(red * factor))
    buffer.writeu8(pixels, offset + 1, clamp8(green * factor))
    buffer.writeu8(pixels, offset + 2, clamp8(blue * factor))
    buffer.writeu8(pixels, offset + 3, alpha)

    if offset + 4 < length then
      factor = 1 + second * sigma
      buffer.writeu8(pixels, offset + 4, clamp8(red * factor))
      buffer.writeu8(pixels, offset + 5, clamp8(green * factor))
      buffer.writeu8(pixels, offset + 6, clamp8(blue * factor))
      buffer.writeu8(pixels, offset + 7, alpha)
    end
  end

  return out
end

--- Wraps bytes of coverage, a byte a pixel, as a mask of a size. The mask shares the buffer.
function Magick.mask(width: number, height: number, covered: buffer): Mask
  if buffer.len(covered) ~= width * height then error('magick: mask byte length mismatch', 2) end

  return { width = width, height = height, data = covered }
end

--- Stores, for each of `count` bytes of coverage, the pixel `shades` holds for its value: 256
--- pixels, four bytes each.
local function shade(covered: buffer, count: number, shades: buffer, pixels: buffer)
  for index = 0, count - 1 do
    buffer.writeu32(pixels, index * 4, buffer.readu32(shades, buffer.readu8(covered, index) * 4))
  end
end

--- An image of a color, white when none is given, with the mask's coverage scaled by the color's
--- alpha as its own.
function Magick.maskToImage(mask: Mask, color: Color?): Image
  local channels = colorTable(color or '#ffffff')
  local {width, height, data: covered} = mask
  local out = Magick.new(width, height)
  local hue, alphaScale = channels[1] + channels[2] * 256 + channels[3] * 65536, channels[4] / 255
  local shades = buffer.create(256 * 4)

  into(shades, 'u32')[for value in range(0, 255) => hue + clamp8(value * alphaScale) * 16777216]
  shade(covered, width * height, shades, out.data)

  return out
end

--- An image filled from a color or a tile wherever the mask covers, the mask's coverage scaling
--- the alpha of what it is filled from, and clear wherever it does not.
function Magick.paintMask(mask: Mask, source: Source?): Image
  local {width, height, data: covered} = mask
  local count = width * height
  local out = Magick.new(width, height)
  local pixels = out.data
  local tile = tileOf(source)

  if tile and repeatable(tile, pixels) then
    local {width: tileWidth, height: tileHeight, data: tilePixels} = tile

    for row = 0, height - 1 do
      local from, start = row % tileHeight * tileWidth * 4, row * width

      for column = 0, width - 1 do
        local cover = buffer.readu8(covered, start + column)
        local pixel = buffer.readu32(tilePixels, from + column % tileWidth * 4)
        local alpha = clamp8(bit32.rshift(pixel, 24) * cover / 255)

        -- A pixel the mask leaves out stays clear, color and all: its pixel is multiplied away.
        buffer.writeu32(pixels, (start + column) * 4, math.min(cover, 1) * (bit32.band(pixel, 0xffffff) + alpha * 16777216))
      end
    end

    return out
  end

  if tile then
    for row = 0, height - 1 do
      for column = 0, width - 1 do
        local cover = buffer.readu8(covered, row * width + column)

        if cover ~= 0 then
          local red, green, blue, alpha = sampleTile(tile, column, row)

          out:set(column, row, red, green, blue, clamp8(alpha * cover / 255))
        end
      end
    end

    return out
  end

  -- A mask that covers nothing never reads its color, so it never refuses one either.
  if not any[for cover in covered[1:count] => cover ~= 0] then return out end

  local channels = colorTable(source :: Color?)
  local shades = buffer.create(256 * 4)

  for cover = 1, 255 do
    local pixel = stored(channels[1], channels[2], channels[3], clamp8(channels[4] * cover / 255))

    buffer.writeu32(shades, cover * 4, pixel)
  end

  shade(covered, count, shades, pixels)

  return out
end

--- Raises each of `count` bytes of `target` from `at` to the byte of `source` as far from
--- `from`, where that one is greater: four bytes a turn, then what is left.
local function raise(target: buffer, at: number, source: buffer, from: number, count: number)
  local whole = count - count % 4

  for index = 0, whole - 4, 4 do
    local to, of = at + index, from + index

    buffer.writeu8(target, to, math.max(buffer.readu8(target, to), buffer.readu8(source, of)))
    buffer.writeu8(target, to + 1, math.max(buffer.readu8(target, to + 1), buffer.readu8(source, of + 1)))
    buffer.writeu8(target, to + 2, math.max(buffer.readu8(target, to + 2), buffer.readu8(source, of + 2)))
    buffer.writeu8(target, to + 3, math.max(buffer.readu8(target, to + 3), buffer.readu8(source, of + 3)))
  end

  for index = whole, count - 1 do
    buffer.writeu8(target, at + index, math.max(buffer.readu8(target, at + index), buffer.readu8(source, from + index)))
  end
end

--- A mask whose every byte is the greatest of the bytes within a radius of it, along its row and
--- its column.
function Magick.dilateMask(mask: Mask, radius: number): Mask
  local {width, height, data: covered} = mask
  local reach = math.max(0, math.floor(radius))
  local count = width * height
  local alongRows, out = buffer.create(count), buffer.create(count)

  -- The greatest in a square is the greatest of the greatest in each of its rows, and the
  -- greatest in a run is what a byte is raised to by each neighbor in reach, a whole row of
  -- bytes at a time.
  buffer.copy(alongRows, 0, covered, 0, count)

  for row = 0, height - 1 do
    local start = row * width

    for distance = 1, math.min(reach, width - 1) do
      raise(alongRows, start, covered, start + distance, width - distance)
      raise(alongRows, start + distance, covered, start, width - distance)
    end
  end

  buffer.copy(out, 0, alongRows, 0, count)

  for row = 0, height - 1 do
    local start = row * width

    for distance = 1, math.min(reach, height - 1) do
      if row + distance < height then raise(out, start, alongRows, start + distance * width, width) end
      if row >= distance then raise(out, start, alongRows, start - distance * width, width) end
    end
  end

  return Magick.mask(width, height, out)
end

--- A mask whose every byte is the mean of the bytes within a radius of it along its row, and
--- then along its column, each mean rounded; a byte past an edge is taken for the edge's.
function Magick.blurMask(mask: Mask, radius: number): Mask
  local {width, height, data: covered} = mask
  local reach = math.max(0, math.floor(radius + 0.5))
  local count = buffer.len(covered)

  if reach == 0 then return Magick.mask(width, height, covered[1:count]) end

  local alongRows, out = buffer.create(width * height), buffer.create(width * height)
  local span = reach * 2 + 1

  for row = 0, height - 1 do
    local start = row * width
    local total = 0

    for offset = -reach, reach do
      total += buffer.readu8(covered, start + math.max(0, math.min(width - 1, offset)))
    end

    for column = 0, width - 1 do
      local entering = buffer.readu8(covered, start + math.min(width - 1, column + reach + 1))
      local leaving = buffer.readu8(covered, start + math.max(0, column - reach))

      buffer.writeu8(alongRows, start + column, clamp8(total / span))
      total += entering - leaving
    end
  end

  for column = 0, width - 1 do
    local total = 0

    for offset = -reach, reach do
      total += buffer.readu8(alongRows, math.max(0, math.min(height - 1, offset)) * width + column)
    end

    for row = 0, height - 1 do
      local entering = buffer.readu8(alongRows, math.min(height - 1, row + reach + 1) * width + column)
      local leaving = buffer.readu8(alongRows, math.max(0, row - reach) * width + column)

      buffer.writeu8(out, row * width + column, clamp8(total / span))
      total += entering - leaving
    end
  end

  return Magick.mask(width, height, out)
end

--- A mask of what one mask covers beyond another: the difference of their bytes, or nothing
--- where the second covers more.
function Magick.subtractMask(mask: Mask, removed: Mask): Mask
  assert(mask.width == removed.width and mask.height == removed.height, 'magick: mask geometry mismatch')

  local count = mask.width * mask.height
  local covered, taken = mask.data, removed.data
  local out = buffer.create(count)
  local whole = count - count % 4

  for index = 0, whole - 4, 4 do
    local first = math.max(0, buffer.readu8(covered, index) - buffer.readu8(taken, index))
    local second = math.max(0, buffer.readu8(covered, index + 1) - buffer.readu8(taken, index + 1))
    local third = math.max(0, buffer.readu8(covered, index + 2) - buffer.readu8(taken, index + 2))
    local fourth = math.max(0, buffer.readu8(covered, index + 3) - buffer.readu8(taken, index + 3))

    buffer.writeu32(out, index, first + second * 256 + third * 65536 + fourth * 16777216)
  end

  for index = whole, count - 1 do
    buffer.writeu8(out, index, math.max(0, buffer.readu8(covered, index) - buffer.readu8(taken, index)))
  end

  return Magick.mask(mask.width, mask.height, out)
end

--- Scales an image's brightness and its saturation, each a percentage, in place.
function Magick.modulate(image: Image, brightness: number?, saturation: number?): Image
  local bright, vivid = (brightness or 100) / 100, (saturation or 100) / 100
  local pixels = image.data

  for offset = 0, image.width * image.height * 4 - 4, 4 do
    local pixel = buffer.readu32(pixels, offset)
    local red, green, blue =
      bit32.band(pixel, 255), bit32.band(bit32.rshift(pixel, 8), 255), bit32.band(bit32.rshift(pixel, 16), 255)
    local gray = 0.2126 * red + 0.7152 * green + 0.0722 * blue

    buffer.writeu8(pixels, offset, clamp8((gray + (red - gray) * vivid) * bright))
    buffer.writeu8(pixels, offset + 1, clamp8((gray + (green - gray) * vivid) * bright))
    buffer.writeu8(pixels, offset + 2, clamp8((gray + (blue - gray) * vivid) * bright))
  end

  return image
end

--- Embosses an image in place: each color channel gains the difference between the pixel below
--- and to the right of it and the one above and to the left, times a strength.
function Magick.emboss(image: Image, strength: number?): Image
  local force = strength or 1
  local {width, height, data: pixels} = image
  -- A copy with a clear pixel all around it, so a neighbor past an edge is read like any other.
  local paddedWidth = width + 2
  local padded = buffer.create(paddedWidth * (height + 2) * 4)
  local diagonal = (paddedWidth + 1) * 4

  for row = 0, height - 1 do
    buffer.copy(padded, ((row + 1) * paddedWidth + 1) * 4, pixels, row * width * 4, width * 4)
  end

  for row = 0, height - 1 do
    local offset, center = row * width * 4, ((row + 1) * paddedWidth + 1) * 4

    for _ = 0, width - 1 do
      local pixel = buffer.readu32(padded, center)
      local before, after = buffer.readu32(padded, center - diagonal), buffer.readu32(padded, center + diagonal)
      local red = bit32.band(pixel, 255) + (bit32.band(after, 255) - bit32.band(before, 255)) * force
      local green = bit32.band(bit32.rshift(pixel, 8), 255)
        + (bit32.band(bit32.rshift(after, 8), 255) - bit32.band(bit32.rshift(before, 8), 255)) * force
      local blue = bit32.band(bit32.rshift(pixel, 16), 255)
        + (bit32.band(bit32.rshift(after, 16), 255) - bit32.band(bit32.rshift(before, 16), 255)) * force

      buffer.writeu8(pixels, offset, clamp8(red))
      buffer.writeu8(pixels, offset + 1, clamp8(green))
      buffer.writeu8(pixels, offset + 2, clamp8(blue))
      offset += 4
      center += 4
    end
  end

  return image
end

--- How light a pixel is by the sum of its color channels: their mean, as a share of full.
local Lights = buffer.create(766 * 8)

into(Lights, 'f64')[for total in range(0, 765) => total / 3 / 255]

--- Tints an image in place: each color channel moves a percentage of the way to a color's, the
--- color dimmed to how light the pixel is.
function Magick.tint(image: Image, color: Color?, amount: number?): Image
  local channels, share = colorTable(color), (amount or 100) / 100
  local pixels = image.data

  for offset = 0, image.width * image.height * 4 - 4, 4 do
    local pixel = buffer.readu32(pixels, offset)
    local red, green, blue =
      bit32.band(pixel, 255), bit32.band(bit32.rshift(pixel, 8), 255), bit32.band(bit32.rshift(pixel, 16), 255)
    local light = buffer.readf64(Lights, (red + green + blue) * 8)

    buffer.writeu8(pixels, offset, clamp8(red + (channels[1] * light - red) * share))
    buffer.writeu8(pixels, offset + 1, clamp8(green + (channels[2] * light - green) * share))
    buffer.writeu8(pixels, offset + 2, clamp8(blue + (channels[3] * light - blue) * share))
  end

  return image
end

local function write32(buf,o,v) buffer.writeu32(buf,o,v) end

function Magick.dds(img)
    local size=128+img.width*img.height*4; local out=buffer.create(size)
    buffer.writestring(out,0,"DDS ")
    write32(out,4,124); write32(out,8,0x100F); write32(out,12,img.height); write32(out,16,img.width); write32(out,20,img.width*4); write32(out,24,0); write32(out,28,1)
    -- ImageMagick leaves an identifying stamp in DDS_HEADER.reserved1; harmless but useful for oracle parity.
    write32(out,32,0x47414D49); write32(out,36,0x47414D45); write32(out,40,0x004B4349)
    write32(out,76,32); write32(out,80,0x41); write32(out,84,0); write32(out,88,32); write32(out,92,0x00FF0000); write32(out,96,0x0000FF00); write32(out,100,0x000000FF); write32(out,104,0xFF000000); write32(out,108,0x1000)
    local p=128
    for y=0,img.height-1 do for x=0,img.width-1 do local r,g,b,a=img:get(x,y); buffer.writeu8(out,p,b); buffer.writeu8(out,p+1,g); buffer.writeu8(out,p+2,r); buffer.writeu8(out,p+3,a); p+=4 end end
    return out
end

function Magick.readDDS(bytes)
    if buffer.len(bytes)<128 or buffer.readstring(bytes,0,4)~="DDS " then error("magick: not a DDS",2) end
    local h=buffer.readu32(bytes,12); local w=buffer.readu32(bytes,16); local bits=buffer.readu32(bytes,88)
    if bits~=32 then error("magick: only uncompressed 32-bit DDS is supported",2) end
    local out=Magick.new(w,h); local p=128
    for y=0,h-1 do for x=0,w-1 do local b=buffer.readu8(bytes,p); local g=buffer.readu8(bytes,p+1); local r=buffer.readu8(bytes,p+2); local a=buffer.readu8(bytes,p+3); out:set(x,y,r,g,b,a); p+=4 end end
    return out
end

function Magick.writeDDS(path,img)
    jess.fs.write(path,Magick.dds(img))
    return path
end

export type Stats = { width: number, height: number, mean: { number }, nonzeroAlpha: number }

--- The size of an image, the mean of each of its channels, and how many pixels are not clear.
function Magick.stats(image: Image): Stats
  local {width, height, data} = image
  local count = width * height
  local divisor = if count == 0 then 1 else count
  local red = sum[for value in data[1:count, 'u8@4'] => value]
  local green = sum[for value in data[1:count, 'u8@4+1'] => value]
  local blue = sum[for value in data[1:count, 'u8@4+2'] => value]
  local alpha = sum[for value in data[1:count, 'u8@4+3'] => value]

  return {
    width = width,
    height = height,
    mean = { red / divisor, green / divisor, blue / divisor, alpha / divisor },
    nonzeroAlpha = #[for value in data[1:count, 'u8@4+3'] if value ~= 0 => value],
  }
end


-- -----------------------------------------------------------------------------
-- General-purpose raster/codec extensions (v0.2)
-- -----------------------------------------------------------------------------

local function copyBuffer(src, offset, length)
    local out = buffer.create(length)
    buffer.copy(out, 0, src, offset or 0, length)
    return out
end

local function concatBuffers(parts)
    local total = 0
    for _,p in parts do total += buffer.len(p) end
    local out = buffer.create(total)
    local o = 0
    for _,p in parts do local n=buffer.len(p); buffer.copy(out,o,p,0,n); o+=n end
    return out
end

local function pngChunk(kind, payload)
    local n = buffer.len(payload)
    local out = buffer.create(12+n)
    bytes.writeu32be(out,0,n)
    buffer.writestring(out,4,kind)
    if n>0 then buffer.copy(out,8,payload,0,n) end
    local crcInput=buffer.create(4+n)
    buffer.writestring(crcInput,0,kind)
    if n>0 then buffer.copy(crcInput,4,payload,0,n) end
    bytes.writeu32be(out,8+n,bytes.crc32(crcInput))
    return out
end

function Magick.png(img, level)
    local ihdr=buffer.create(13)
    bytes.writeu32be(ihdr,0,img.width); bytes.writeu32be(ihdr,4,img.height)
    buffer.writeu8(ihdr,8,8); buffer.writeu8(ihdr,9,6); buffer.writeu8(ihdr,10,0); buffer.writeu8(ihdr,11,0); buffer.writeu8(ihdr,12,0)
    local row=img.width*4+1
    local raw=buffer.create(row*img.height)
    for y=0,img.height-1 do
        local ro=y*row; buffer.writeu8(raw,ro,0)
        buffer.copy(raw,ro+1,img.data,y*img.width*4,img.width*4)
    end
    local compressed=bytes.deflate(raw,{format="zlib",level=level or 6})
    local sig=buffer.create(8); buffer.writestring(sig,0,"\137PNG\r\n\26\n")
    return concatBuffers({sig,pngChunk("IHDR",ihdr),pngChunk("IDAT",compressed),pngChunk("IEND",buffer.create(0))})
end

local function paeth(a,b,c)
    local p=a+b-c; local pa=math.abs(p-a); local pb=math.abs(p-b); local pc=math.abs(p-c)
    if pa<=pb and pa<=pc then return a elseif pb<=pc then return b else return c end
end

function Magick.readPNG(src)
    if type(src)=="string" then src=jess.fs.readBuffer(src) end
    if buffer.len(src)<8 or buffer.readstring(src,0,8)~="\137PNG\r\n\26\n" then error("magick: not a PNG",2) end
    local p=8; local w,h,bitDepth,colorType,interlace=nil,nil,nil,nil,nil; local idats={}
    while p+12<=buffer.len(src) do
        local n=bytes.readu32be(src,p); local kind=buffer.readstring(src,p+4,4); local dataOff=p+8
        if dataOff+n+4>buffer.len(src) then error("magick: truncated PNG chunk",2) end
        if kind=="IHDR" then
            w=bytes.readu32be(src,dataOff); h=bytes.readu32be(src,dataOff+4); bitDepth=buffer.readu8(src,dataOff+8); colorType=buffer.readu8(src,dataOff+9); interlace=buffer.readu8(src,dataOff+12)
        elseif kind=="IDAT" then
            idats[#idats+1]=copyBuffer(src,dataOff,n)
        elseif kind=="IEND" then break end
        p=dataOff+n+4
    end
    if not w or not h or bitDepth~=8 or interlace~=0 then error("magick: PNG requires 8-bit non-interlaced samples",2) end
    local channels = ({[0]=1,[2]=3,[4]=2,[6]=4})[colorType]
    if not channels then error("magick: unsupported PNG color type "..tostring(colorType),2) end
    local packed=concatBuffers(idats)
    local scan=bytes.inflate(packed,{format="zlib",maxSize=h*(w*channels+1)+64})
    local stride=w*channels; local expected=h*(stride+1)
    if buffer.len(scan)<expected then error("magick: truncated PNG scanlines",2) end
    local recon=buffer.create(h*stride)
    local sp=0
    for y=0,h-1 do
        local f=buffer.readu8(scan,sp); sp+=1
        local row=y*stride; local prev=(y-1)*stride
        for x=0,stride-1 do
            local raw=buffer.readu8(scan,sp); sp+=1
            local a=(x>=channels) and buffer.readu8(recon,row+x-channels) or 0
            local b=(y>0) and buffer.readu8(recon,prev+x) or 0
            local c=(y>0 and x>=channels) and buffer.readu8(recon,prev+x-channels) or 0
            local v
            if f==0 then v=raw elseif f==1 then v=(raw+a)%256 elseif f==2 then v=(raw+b)%256 elseif f==3 then v=(raw+math.floor((a+b)/2))%256 elseif f==4 then v=(raw+paeth(a,b,c))%256 else error("magick: bad PNG filter",2) end
            buffer.writeu8(recon,row+x,v)
        end
    end
    local out=Magick.new(w,h); local rp=0
    for y=0,h-1 do for x=0,w-1 do
        local r,g,b,a
        if colorType==6 then r=buffer.readu8(recon,rp); g=buffer.readu8(recon,rp+1); b=buffer.readu8(recon,rp+2); a=buffer.readu8(recon,rp+3)
        elseif colorType==2 then r=buffer.readu8(recon,rp); g=buffer.readu8(recon,rp+1); b=buffer.readu8(recon,rp+2); a=255
        elseif colorType==0 then r=buffer.readu8(recon,rp); g=r; b=r; a=255
        else r=buffer.readu8(recon,rp); g=r; b=r; a=buffer.readu8(recon,rp+1) end
        out:set(x,y,r,g,b,a); rp+=channels
    end end
    return out
end

function Magick.writePNG(path,img,level) jess.fs.write(path,Magick.png(img,level)); return path end

local function extLower(path)
    local e=string.match(path,"%.([^./\\]+)$"); return e and string.lower(e) or ""
end


function Magick.readBMP(src)
    if type(src)=="string" then src=jess.fs.readBuffer(src) end
    if buffer.len(src)<54 or buffer.readstring(src,0,2)~="BM" then error("magick: not a BMP",2) end
    local pixelOff=buffer.readu32(src,10); local dib=buffer.readu32(src,14)
    if dib<40 then error("magick: unsupported BMP DIB header",2) end
    local w=buffer.readi32(src,18); local hs=buffer.readi32(src,22); local topDown=hs<0; local h=math.abs(hs); local bpp=buffer.readu16(src,28); local compression=buffer.readu32(src,30)
    if compression~=0 then error("magick: compressed BMP not supported",2) end
    if bpp~=24 and bpp~=32 then error("magick: only 24/32-bit BMP supported",2) end
    local bytesPer=bpp/8; local stride=math.floor((w*bytesPer+3)/4)*4; local out=Magick.new(w,h)
    for y=0,h-1 do local sy=topDown and y or (h-1-y); local row=pixelOff+sy*stride
        for x=0,w-1 do local o=row+x*bytesPer; local b=buffer.readu8(src,o); local g=buffer.readu8(src,o+1); local r=buffer.readu8(src,o+2); local a=bpp==32 and buffer.readu8(src,o+3) or 255; out:set(x,y,r,g,b,a) end
    end
    return out
end

function Magick.readTGA(src)
    if type(src)=="string" then src=jess.fs.readBuffer(src) end
    if buffer.len(src)<18 then error("magick: truncated TGA",2) end
    local idLen=buffer.readu8(src,0); local cmap=buffer.readu8(src,1); local imageType=buffer.readu8(src,2); if cmap~=0 then error("magick: color-mapped TGA not supported",2) end
    local w=buffer.readu16(src,12); local h=buffer.readu16(src,14); local bpp=buffer.readu8(src,16); local desc=buffer.readu8(src,17); local top=(bit32.band(desc,0x20)~=0); local right=(bit32.band(desc,0x10)~=0)
    local gray=(imageType==3 or imageType==11); local rle=(imageType==10 or imageType==11)
    if not (imageType==2 or imageType==3 or imageType==10 or imageType==11) then error("magick: unsupported TGA type",2) end
    local bytesPer=bpp/8; if gray then if bpp~=8 then error("magick: grayscale TGA must be 8-bit",2) end else if bpp~=24 and bpp~=32 then error("magick: truecolor TGA must be 24/32-bit",2) end end
    local p=18+idLen; local out=Magick.new(w,h); local index=0
    local function put(px,py,r,g,b,a) local x=right and (w-1-px) or px; local y=top and py or (h-1-py); out:set(x,y,r,g,b,a) end
    local function readPixel()
        if gray then local v=buffer.readu8(src,p); p+=1; return v,v,v,255 else local b=buffer.readu8(src,p); local g=buffer.readu8(src,p+1); local r=buffer.readu8(src,p+2); local a=bpp==32 and buffer.readu8(src,p+3) or 255; p+=bytesPer; return r,g,b,a end
    end
    if not rle then
        for i=0,w*h-1 do local r,g,b,a=readPixel(); put(i%w,math.floor(i/w),r,g,b,a) end
    else
        while index<w*h do local head=buffer.readu8(src,p); p+=1; local count=bit32.band(head,0x7f)+1
            if bit32.band(head,0x80)~=0 then local r,g,b,a=readPixel(); for _=1,count do put(index%w,math.floor(index/w),r,g,b,a); index+=1 end
            else for _=1,count do local r,g,b,a=readPixel(); put(index%w,math.floor(index/w),r,g,b,a); index+=1 end end
        end
    end
    return out
end

function Magick.read(path)
    local e=extLower(path)
    if e=="png" then return Magick.readPNG(path) elseif e=="dds" then return Magick.readDDS(jess.fs.readBuffer(path)) elseif e=="bmp" then return Magick.readBMP(path) elseif e=="tga" then return Magick.readTGA(path) else error("magick: unsupported input format ."..e,2) end
end

function Magick.write(path,img)
    local e=extLower(path)
    if e=="png" then return Magick.writePNG(path,img) elseif e=="dds" then return Magick.writeDDS(path,img) else error("magick: unsupported output format ."..e,2) end
end

--- Composites a rectangle of a color or of a tile over what is there.
function Image.rectOver(self: Image, x0: number, y0: number, x1: number, y1: number, source: Source?): Image
  if x0 > x1 then x0, x1 = x1, x0 end
  if y0 > y1 then y0, y1 = y1, y0 end

  local {width, data} = self
  local left, top = math.max(0, math.floor(x0)), math.max(0, math.floor(y0))
  local right, bottom = math.min(width - 1, math.floor(x1)), math.min(self.height - 1, math.floor(y1))

  if left > right or top > bottom then return self end

  local tile = tileOf(source)

  if tile and repeatable(tile, data) then
    local {width: tileWidth, height: tileHeight, data: tilePixels} = tile

    for row = top, bottom do
      local from = row % tileHeight * tileWidth * 4
      local column = left

      while column <= right do
        local phase = column % tileWidth
        local run = math.min(tileWidth - phase, right - column + 1)

        blend(tilePixels, from + phase * 4, data, (row * width + column) * 4, 1, run)
        column += run
      end
    end

    return self
  end

  if tile then
    for row = top, bottom do
      for column = left, right do
        local red, green, blue, alpha = sampleTile(tile, column, row)

        if alpha > 0 then
          local underRed, underGreen, underBlue, underAlpha = self:get(column, row)

          self:set(column, row, overPixel(underRed, underGreen, underBlue, underAlpha, red, green, blue, alpha))
        end
      end
    end

    return self
  end

  local channels = colorTable(source :: Color?)
  local red, green, blue, alpha = channels[1], channels[2], channels[3], channels[4]

  if not (alpha > 0) then return self end

  local opacity = alpha / 255
  local rest = 1 - opacity
  local redShare, greenShare, blueShare = red * opacity, green * opacity, blue * opacity

  for row = top, bottom do
    local offset = (row * width + left) * 4

    for _ = left, right do
      local under = buffer.readu32(data, offset)
      local underOpacity = bit32.rshift(under, 24) / 255
      local covered = opacity + underOpacity * rest

      if covered <= 0 then
        buffer.writeu32(data, offset, 0)
      else
        local underRed, underGreen, underBlue =
          bit32.band(under, 255), bit32.band(bit32.rshift(under, 8), 255), bit32.band(bit32.rshift(under, 16), 255)

        buffer.writeu8(data, offset, clamp8((redShare + underRed * underOpacity * rest) / covered))
        buffer.writeu8(data, offset + 1, clamp8((greenShare + underGreen * underOpacity * rest) / covered))
        buffer.writeu8(data, offset + 2, clamp8((blueShare + underBlue * underOpacity * rest) / covered))
        buffer.writeu8(data, offset + 3, clamp8(covered * 255))
      end

      offset += 4
    end
  end

  return self
end

--- Composites a polygon over what is there.
function Image.polygonOver(self: Image, points: { { number } }, source: Source?): Image
  return self:over(Magick.new(self.width, self.height):polygon(points, source))
end

--- An image of a size, filled with a tile repeated from its top left corner.
function Magick.tile(width: number, height: number, tile: Source?): Image
  return Magick.new(width, height):rect(0, 0, width - 1, height - 1, tile)
end

--- The alpha of every pixel, as a mask.
function Image.alphaMask(self: Image): Mask
  local {width, height, data} = self
  local count = width * height
  local alphas = buffer.create(count)
  local whole = count - count % 4

  for index = 0, whole - 4, 4 do
    local at = index * 4 + 3
    local first, second, third, fourth =
      buffer.readu8(data, at), buffer.readu8(data, at + 4), buffer.readu8(data, at + 8), buffer.readu8(data, at + 12)

    buffer.writeu32(alphas, index, first + second * 256 + third * 65536 + fourth * 16777216)
  end

  for index = whole, count - 1 do
    buffer.writeu8(alphas, index, buffer.readu8(data, index * 4 + 3))
  end

  return Magick.mask(width, height, alphas)
end

--- Moves every pixel right and down by whole pixels; what leaves an edge comes back in at the
--- opposite one.
function Image.roll(self: Image, dx: number?, dy: number?): Image
  local {width, height, data} = self
  local across, down = math.floor(dx or 0), math.floor(dy or 0)
  local out = Magick.new(width, height)

  if width == 0 or height == 0 then return out end

  local stride = width * 4
  local wrapped = across % width * 4
  local kept = stride - wrapped

  for row = 0, height - 1 do
    local from, to = row * stride, (row + down) % height * stride

    buffer.copy(out.data, to + wrapped, data, from, kept)
    buffer.copy(out.data, to, data, from + kept, wrapped)
  end

  return out
end

--- The gray level of a pixel by the sum of its color channels: their mean, rounded.
local Levels = buffer.create(766)

into(Levels, 'u8')[for total in range(0, 765) => clamp8(total / 3)]

--- Replaces each color channel of the pixels in the first `length` bytes by its entry in a table
--- of 256 bytes, one table a channel; alpha stays as it is.
local function mapColors(pixels: buffer, length: number, reds: buffer, greens: buffer, blues: buffer)
  for offset = 0, length - 4, 4 do
    local pixel = buffer.readu32(pixels, offset)
    local red = buffer.readu8(reds, bit32.band(pixel, 255))
    local green = buffer.readu8(greens, bit32.band(bit32.rshift(pixel, 8), 255))
    local blue = buffer.readu8(blues, bit32.band(bit32.rshift(pixel, 16), 255))

    buffer.writeu32(pixels, offset, red + green * 256 + blue * 65536 + bit32.band(pixel, 0xff000000))
  end
end

--- How many of the first `count` pixels are at each gray level: 256 counts, four bytes each.
local function levels(pixels: buffer, count: number): buffer
  local histogram = buffer.create(256 * 4)

  for offset = 0, count * 4 - 4, 4 do
    local pixel = buffer.readu32(pixels, offset)
    local total = bit32.band(pixel, 255) + bit32.band(bit32.rshift(pixel, 8), 255) + bit32.band(bit32.rshift(pixel, 16), 255)
    local at = buffer.readu8(Levels, total) * 4

    buffer.writeu32(histogram, at, buffer.readu32(histogram, at) + 1)
  end

  return histogram
end

--- Makes every pixel the gray of its luminance; alpha stays.
function Image.grayscale(self: Image): Image
  local pixels = self.data

  for offset = 0, buffer.len(pixels) - 4, 4 do
    local pixel = buffer.readu32(pixels, offset)
    local red, green, blue =
      bit32.band(pixel, 255), bit32.band(bit32.rshift(pixel, 8), 255), bit32.band(bit32.rshift(pixel, 16), 255)
    local gray = clamp8(0.212656 * red + 0.715158 * green + 0.072186 * blue)

    buffer.writeu32(pixels, offset, gray * 65793 + bit32.band(pixel, 0xff000000))
  end

  return self
end

--- Makes every pixel white when the mean of its color channels reaches a level, and black when
--- not; a level up to 1 is a share of full. Alpha stays.
function Image.threshold(self: Image, level: number): Image
  local pixels = self.data
  local cut = if level <= 1 then level * 255 else level
  local whites = buffer.create(766)

  into(whites, 'u8')[for total in range(0, 765) => if total / 3 >= cut then 255 else 0]

  for offset = 0, buffer.len(pixels) - 4, 4 do
    local pixel = buffer.readu32(pixels, offset)
    local total = bit32.band(pixel, 255) + bit32.band(bit32.rshift(pixel, 8), 255) + bit32.band(bit32.rshift(pixel, 16), 255)

    buffer.writeu32(pixels, offset, buffer.readu8(whites, total) * 65793 + bit32.band(pixel, 0xff000000))
  end

  return self
end

--- Moves every color channel a share of the way to a color's; alpha stays.
function Image.colorize(self: Image, color: Color?, amount: number?): Image
  local channels, share = colorTable(color), (amount or 100) / 100
  local reds, greens, blues = buffer.create(256), buffer.create(256), buffer.create(256)

  into(reds, 'u8')[for value in range(0, 255) => clamp8(value + (channels[1] - value) * share)]
  into(greens, 'u8')[for value in range(0, 255) => clamp8(value + (channels[2] - value) * share)]
  into(blues, 'u8')[for value in range(0, 255) => clamp8(value + (channels[3] - value) * share)]
  mapColors(self.data, buffer.len(self.data), reds, greens, blues)

  return self
end

--- Whether a channel is a byte, which is all that a stored channel can equal.
local function isByte(value: number): boolean
  return value >= 0 and value <= 255 and value % 1 == 0
end

--- Makes every pixel of a color clear.
function Image.transparent(self: Image, color: Color?): Image
  local channels = colorTable(color)
  local pixels = self.data

  if not (isByte(channels[1]) and isByte(channels[2]) and isByte(channels[3])) then return self end

  local key = channels[1] + channels[2] * 256 + channels[3] * 65536

  for offset = 0, self.width * self.height * 4 - 4, 4 do
    local pixel = buffer.readu32(pixels, offset)
    -- 0 for a pixel of the color and 1 for any other, so the loop stores every pixel and
    -- chooses nothing.
    local other = math.min(bit32.bxor(bit32.band(pixel, 0xffffff), key), 1)

    buffer.writeu32(pixels, offset, pixel - (1 - other) * bit32.band(pixel, 0xff000000))
  end

  return self
end

--- Gives every pixel of one color another; alpha stays.
function Image.opaque(self: Image, fromColor: Color?, toColor: Color?): Image
  local from, to = colorTable(fromColor), colorTable(toColor)
  local pixels = self.data

  if not (isByte(from[1]) and isByte(from[2]) and isByte(from[3])) then return self end

  local key = from[1] + from[2] * 256 + from[3] * 65536
  local swapped = bit32.band(stored(to[1], to[2], to[3], 0), 0xffffff)

  for offset = 0, self.width * self.height * 4 - 4, 4 do
    local pixel = buffer.readu32(pixels, offset)
    local color = bit32.band(pixel, 0xffffff)
    local other = math.min(bit32.bxor(color, key), 1)

    buffer.writeu32(pixels, offset, pixel + (1 - other) * (swapped - color))
  end

  return self
end

--- Sets every pixel's alpha: a value up to 1 is a share of opaque, a larger one the byte itself.
function Image.setAlpha(self: Image, value: number): Image
  local alpha = if value <= 1 then clamp8(value * 255) else clamp8(value)
  local count = self.width * self.height

  if count > 0 then dataPlane.fill(self.data, 'u8@4+3', 0, count, alpha) end

  return self
end

--- Keeps the darker of each color channel, and the greater alpha, wherever `source`, laid at an
--- offset, is not clear.
function Image.darken(self: Image, source: Image, dx: number?, dy: number?): Image
  local across, down = dx or 0, dy or 0
  local {width, height, data: to} = self
  local {width: sourceWidth, height: sourceHeight, data: from} = source

  -- An offset that is not whole lands between pixels, which only a get and a set per pixel
  -- reproduce.
  if across % 1 ~= 0 or down % 1 ~= 0 then
    for row = 0, sourceHeight - 1 do
      for column = 0, sourceWidth - 1 do
        local toColumn, toRow = column + across, row + down
        local red, green, blue, alpha = source:get(column, row)

        if toRow >= 0 and toRow < height and toColumn >= 0 and toColumn < width and alpha > 0 then
          local underRed, underGreen, underBlue, underAlpha = self:get(toColumn, toRow)

          self:set(
            toColumn,
            toRow,
            math.min(underRed, red),
            math.min(underGreen, green),
            math.min(underBlue, blue),
            math.max(underAlpha, alpha)
          )
        end
      end
    end

    return self
  end

  local left, right = math.max(0, -across), math.min(sourceWidth, width - across) - 1

  for row = math.max(0, -down), math.min(sourceHeight, height - down) - 1 do
    local sourceAt = (row * sourceWidth + left) * 4
    local at = ((row + down) * width + left + across) * 4

    for _ = left, right do
      local pixel, under = buffer.readu32(from, sourceAt), buffer.readu32(to, at)
      local red = math.min(bit32.band(under, 255), bit32.band(pixel, 255))
      local green = math.min(bit32.band(bit32.rshift(under, 8), 255), bit32.band(bit32.rshift(pixel, 8), 255))
      local blue = math.min(bit32.band(bit32.rshift(under, 16), 255), bit32.band(bit32.rshift(pixel, 16), 255))
      local alpha = math.max(bit32.rshift(under, 24), bit32.rshift(pixel, 24))
      local darker = red + green * 256 + blue * 65536 + alpha * 16777216
      -- 1 where the source is not clear and 0 where it is, so a clear pixel stores what was there.
      local covered = math.min(bit32.rshift(pixel, 24), 1)

      buffer.writeu32(to, at, under + covered * (darker - under))
      sourceAt += 4
      at += 4
    end
  end

  return self
end

--- Draws a line as a square of the line's width at every step along it.
function Image.line(self: Image, x0: number, y0: number, x1: number, y1: number, source: Source?, width: number?): Image
  local thickness = math.max(1, math.floor((width or 1) + 0.5))
  local across, down = x1 - x0, y1 - y0
  local steps = math.max(math.abs(across), math.abs(down))
  local reach = (thickness - 1) / 2

  if steps < 1 then steps = 1 end

  for step = 0, steps do
    local along = step / steps
    local column, row = x0 + across * along, y0 + down * along

    self:rect(math.floor(column - reach), math.floor(row - reach), math.floor(column + reach), math.floor(row + reach), source)
  end

  return self
end

--- Draws the outline of a rectangle, its width inside the corners.
function Image.strokeRect(self: Image, x0: number, y0: number, x1: number, y1: number, source: Source?, width: number?): Image
  local thickness = math.max(1, math.floor((width or 1) + 0.5))

  self:rect(x0, y0, x1, y0 + thickness - 1, source)
  self:rect(x0, y1 - thickness + 1, x1, y1, source)
  self:rect(x0, y0 + thickness, x0 + thickness - 1, y1 - thickness, source)
  self:rect(x1 - thickness + 1, y0 + thickness, x1, y1 - thickness, source)

  return self
end

--- Fills a rectangle with rounded corners, or draws its outline when given a width.
function Image.roundRect(
  self: Image,
  x0: number,
  y0: number,
  x1: number,
  y1: number,
  radius: number?,
  source: Source?,
  width: number?
): Image
  local corner = math.max(0, math.floor(radius or 0))

  if width then
    self:strokeRect(x0 + corner, y0, x1 - corner, y1, source, width)
    self:line(x0, y0 + corner, x0, y1 - corner, source, width)
    self:line(x1, y0 + corner, x1, y1 - corner, source, width)

    return self
  end

  self:rect(x0 + corner, y0, x1 - corner, y1, source)
  self:rect(x0, y0 + corner, x1, y1 - corner, source)
  self:circle(x0 + corner, y0 + corner, corner, corner, source)
  self:circle(x1 - corner, y0 + corner, corner, corner, source)
  self:circle(x0 + corner, y1 - corner, corner, corner, source)
  self:circle(x1 - corner, y1 - corner, corner, corner, source)

  return self
end

--- The image resized to fit inside a width and a height, keeping its shape.
function Image.resizeFit(self: Image, maxWidth: number, maxHeight: number, nearest: boolean?): Image
  local {width, height} = self
  local scale = math.min(maxWidth / width, maxHeight / height)

  return self:resize(math.max(1, math.floor(width * scale + 0.5)), math.max(1, math.floor(height * scale + 0.5)), nearest)
end

--- The weights of a Gaussian of a deviation out to three deviations either way, eight bytes
--- each and summing to one, and how many pixels that is to a side. The weights are followed by
--- zeros to a multiple of four, so they can be taken four at a time.
local function gaussianKernel(sigma: number): (buffer, number)
  local spread = math.max(0.01, sigma)
  local radius = math.max(1, math.ceil(spread * 3))
  local weights = [for offset in range(-radius, radius) => math.exp(-(offset * offset) / (2 * spread * spread))]
  local total = sum[for weight in weights => weight]
  local kernel = buffer.create(math.ceil(#weights / 4) * 4 * 8)

  into(kernel, 'f64')[for weight in weights => weight / total]

  return kernel, radius
end

--- Adds to each of `count` sums four terms, in order: the bytes of `source` as far from `first`,
--- `second`, `third` and `fourth`, each times the weight of its tap, the four of `kernel` from
--- `tap`. A sum is read once and stored once for the four, and a term of weight zero leaves it
--- as it was.
local function accumulate(
  sums: buffer,
  count: number,
  source: buffer,
  first: number,
  second: number,
  third: number,
  fourth: number,
  kernel: buffer,
  tap: number
)
  local firstWeight, secondWeight = buffer.readf64(kernel, tap * 8), buffer.readf64(kernel, tap * 8 + 8)
  local thirdWeight, fourthWeight = buffer.readf64(kernel, tap * 8 + 16), buffer.readf64(kernel, tap * 8 + 24)
  local whole = count - count % 4

  for index = 0, whole - 4, 4 do
    local at = index * 8

    buffer.writef64(
      sums,
      at,
      buffer.readf64(sums, at)
        + buffer.readu8(source, first + index) * firstWeight
        + buffer.readu8(source, second + index) * secondWeight
        + buffer.readu8(source, third + index) * thirdWeight
        + buffer.readu8(source, fourth + index) * fourthWeight
    )
    buffer.writef64(
      sums,
      at + 8,
      buffer.readf64(sums, at + 8)
        + buffer.readu8(source, first + index + 1) * firstWeight
        + buffer.readu8(source, second + index + 1) * secondWeight
        + buffer.readu8(source, third + index + 1) * thirdWeight
        + buffer.readu8(source, fourth + index + 1) * fourthWeight
    )
    buffer.writef64(
      sums,
      at + 16,
      buffer.readf64(sums, at + 16)
        + buffer.readu8(source, first + index + 2) * firstWeight
        + buffer.readu8(source, second + index + 2) * secondWeight
        + buffer.readu8(source, third + index + 2) * thirdWeight
        + buffer.readu8(source, fourth + index + 2) * fourthWeight
    )
    buffer.writef64(
      sums,
      at + 24,
      buffer.readf64(sums, at + 24)
        + buffer.readu8(source, first + index + 3) * firstWeight
        + buffer.readu8(source, second + index + 3) * secondWeight
        + buffer.readu8(source, third + index + 3) * thirdWeight
        + buffer.readu8(source, fourth + index + 3) * fourthWeight
    )
  end

  for index = whole, count - 1 do
    buffer.writef64(
      sums,
      index * 8,
      buffer.readf64(sums, index * 8)
        + buffer.readu8(source, first + index) * firstWeight
        + buffer.readu8(source, second + index) * secondWeight
        + buffer.readu8(source, third + index) * thirdWeight
        + buffer.readu8(source, fourth + index) * fourthWeight
    )
  end
end

--- Stores `count` sums as bytes from `at`, each clamped and rounded: four a turn, then what is
--- left.
local function settle(sums: buffer, target: buffer, at: number, count: number)
  local whole = count - count % 4

  for index = 0, whole - 4, 4 do
    local from = index * 8
    local first, second = clamp8(buffer.readf64(sums, from)), clamp8(buffer.readf64(sums, from + 8))
    local third, fourth = clamp8(buffer.readf64(sums, from + 16)), clamp8(buffer.readf64(sums, from + 24))

    buffer.writeu32(target, at + index, first + second * 256 + third * 65536 + fourth * 16777216)
  end

  for index = whole, count - 1 do
    buffer.writeu8(target, at + index, clamp8(buffer.readf64(sums, index * 8)))
  end
end

--- Blurs rows of `width` pixels of `channels` bytes each into `target`, by a Gaussian of a
--- deviation. Every channel of a pixel becomes the weighted sum of the pixels within the kernel
--- along its row, rounded, and then the same along its column; a pixel past an edge is taken for
--- the edge's. A sum adds its terms from the first pixel of the kernel to the last, a whole row
--- of sums at a time.
local function blur(source: buffer, target: buffer, width: number, height: number, channels: number, sigma: number)
  local kernel, radius = gaussianKernel(sigma)
  local stride, last = width * channels, radius * 2

  if stride == 0 or height == 0 then return end

  local alongRows, sums = buffer.create(stride * height), buffer.create(stride * 8)
  -- A row with its first pixel and its last repeated a radius beyond it, so that no sum along
  -- it has an edge to mind.
  local edge, bottom = radius * channels, height - 1
  local padded = buffer.create(stride + edge * 2)

  for row = 0, height - 1 do
    local start = row * stride

    buffer.copy(padded, 0, source, start, channels)
    replicate(padded, 0, channels, edge)
    buffer.copy(padded, edge, source, start, stride)
    buffer.copy(padded, edge + stride, source, start + stride - channels, channels)
    replicate(padded, edge + stride, channels, edge)
    buffer.fill(sums, 0, 0)

    -- A tap past the last has no weight; it reads where the last one does.
    for tap = 0, last, 4 do
      local second, third, fourth = math.min(tap + 1, last), math.min(tap + 2, last), math.min(tap + 3, last)

      accumulate(sums, stride, padded, tap * channels, second * channels, third * channels, fourth * channels, kernel, tap)
    end

    settle(sums, alongRows, start, stride)
  end

  for row = 0, height - 1 do
    buffer.fill(sums, 0, 0)

    for tap = 0, last, 4 do
      local above = row - radius + tap
      local first, second = math.max(0, math.min(bottom, above)), math.max(0, math.min(bottom, above + 1))
      local third, fourth = math.max(0, math.min(bottom, above + 2)), math.max(0, math.min(bottom, above + 3))

      accumulate(sums, stride, alongRows, first * stride, second * stride, third * stride, fourth * stride, kernel, tap)
    end

    settle(sums, target, row * stride, stride)
  end
end

--- A copy of an image blurred by a Gaussian of a deviation in pixels, or as it is when the
--- deviation is none.
function Magick.gaussianBlur(image: Image, sigma: number): Image
  if sigma <= 0 then return image:clone() end

  local {width, height, data} = image
  local out = Magick.new(width, height)

  blur(data, out.data, width, height, 4, sigma)

  return out
end

--- A channel value as a share of full.
local Shares = buffer.create(256 * 8)

into(Shares, 'f64')[for value in range(0, 255) => value / 255]

--- A new image whose color channels are a polynomial of two images' channels as shares of full,
--- `k1 * left * right + k2 * left + k3 * right + k4`; its alpha is the first image's.
function Magick.mathCompose(left: Image, right: Image, k1: number?, k2: number?, k3: number?, k4: number?): Image
  assert(left.width == right.width and left.height == right.height, 'magick: geometry mismatch')

  local out = Magick.new(left.width, left.height)
  local product, first, second, constant = k1 or 0, k2 or 1, k3 or 0, k4 or 0
  local leftPixels, rightPixels, pixels = left.data, right.data, out.data

  for offset = 0, left.width * left.height * 4 - 4, 4 do
    local leftPixel, rightPixel = buffer.readu32(leftPixels, offset), buffer.readu32(rightPixels, offset)
    local leftRed = buffer.readf64(Shares, bit32.band(leftPixel, 255) * 8)
    local leftGreen = buffer.readf64(Shares, bit32.band(bit32.rshift(leftPixel, 8), 255) * 8)
    local leftBlue = buffer.readf64(Shares, bit32.band(bit32.rshift(leftPixel, 16), 255) * 8)
    local rightRed = buffer.readf64(Shares, bit32.band(rightPixel, 255) * 8)
    local rightGreen = buffer.readf64(Shares, bit32.band(bit32.rshift(rightPixel, 8), 255) * 8)
    local rightBlue = buffer.readf64(Shares, bit32.band(bit32.rshift(rightPixel, 16), 255) * 8)

    buffer.writeu8(pixels, offset, clamp8((product * leftRed * rightRed + first * leftRed + second * rightRed + constant) * 255))
    buffer.writeu8(pixels, offset + 1, clamp8((product * leftGreen * rightGreen + first * leftGreen + second * rightGreen + constant) * 255))
    buffer.writeu8(pixels, offset + 2, clamp8((product * leftBlue * rightBlue + first * leftBlue + second * rightBlue + constant) * 255))
    buffer.writeu8(pixels, offset + 3, bit32.rshift(leftPixel, 24))
  end

  return out
end

--- Maps every color channel through a line: a slope, and an intercept as a share of full.
function Image.polynomial(self: Image, slope: number, intercept: number): Image
  local bias = intercept * 255
  local mapped = buffer.create(256)

  into(mapped, 'u8')[for value in range(0, 255) => clamp8(value * slope + bias)]
  mapColors(self.data, buffer.len(self.data), mapped, mapped, mapped)

  return self
end

--- Stretches the color channels so the gray level a share of the pixels lie at or below becomes
--- black and the level a share lie above becomes white, each share a percentage.
function Image.contrastStretch(self: Image, lowPercent: number?, highPercent: number?): Image
  local count = self.width * self.height
  local histogram = levels(self.data, count)
  local lowTarget, highTarget = count * (lowPercent or 0) / 100, count * (1 - (highPercent or 0) / 100)
  local low, high, seen = 0, 255, 0

  for level = 0, 255 do
    seen += buffer.readu32(histogram, level * 4)

    if seen >= lowTarget then
      low = level
      break
    end
  end

  seen = 0

  for level = 0, 255 do
    seen += buffer.readu32(histogram, level * 4)

    if seen >= highTarget then
      high = level
      break
    end
  end

  if high <= low then return self end

  local scale = 255 / (high - low)
  local mapped = buffer.create(256)

  into(mapped, 'u8')[for value in range(0, 255) => clamp8((value - low) * scale)]
  mapColors(self.data, count * 4, mapped, mapped, mapped)

  return self
end

--- Bends the color channels along a sigmoid about a midpoint, a share of full or a percentage.
function Image.sigmoidalContrast(self: Image, contrast: number?, midpoint: number?): Image
  local steepness, middle = contrast or 2, midpoint or 0.5

  if middle > 1 then middle /= 100 end

  local function sigmoid(value: number): number return 1 / (1 + math.exp(steepness * (middle - value))) end

  local low, high = sigmoid(0), sigmoid(1)
  local span = high - low
  local mapped = buffer.create(256)

  into(mapped, 'u8')[for value in range(0, 255) => clamp8((sigmoid(value / 255) - low) / span * 255)]
  mapColors(self.data, self.width * self.height * 4, mapped, mapped, mapped)

  return self
end

--- The gray level half of the pixels lie at or below.
function Image.median(self: Image): number
  local count = self.width * self.height
  local histogram = levels(self.data, count)
  local seen = 0

  for level = 0, 255 do
    seen += buffer.readu32(histogram, level * 4)

    if seen * 2 >= count then return level end
  end

  return 0
end

function Magick.verticalGradient(width: number, height: number, top: Color?, bottom: Color?): Image
  local from, to = colorTable(top), colorTable(bottom)
  local out = Magick.new(width, height)
  local pixels, stride = out.data, width * 4

  if width == 0 then return out end

  for row = 0, height - 1 do
    local along = if height <= 1 then 0 else row / (height - 1)
    local red = clamp8(from[1] + (to[1] - from[1]) * along)
    local green = clamp8(from[2] + (to[2] - from[2]) * along)
    local blue = clamp8(from[3] + (to[3] - from[3]) * along)
    local alpha = clamp8(from[4] + (to[4] - from[4]) * along)
    local at = row * stride

    buffer.writeu32(pixels, at, red + green * 256 + blue * 65536 + alpha * 16777216)
    replicate(pixels, at, 4, stride)
  end

  return out
end

--- An opaque image of seeded gray noise, every level as likely as any other.
function Magick.randomNoise(width: number, height: number, seed: number?): Image
  local out = Magick.new(width, height, '#000000')
  local pixels = out.data
  local state = seeded(seed or 1)

  for offset = 0, width * height * 4 - 4, 4 do
    state = state * 48271 % 2147483647

    local gray = math.floor(state / 2147483647 * 256)

    buffer.writeu8(pixels, offset, gray)
    buffer.writeu8(pixels, offset + 1, gray)
    buffer.writeu8(pixels, offset + 2, gray)
  end

  return out
end

--- A copy of an image with seeded Gaussian noise added to its color channels, its deviation a
--- share of full.
function Magick.addGaussianNoise(image: Image, seed: number?, attenuate: number?): Image
  local out = image:clone()
  local pixels, length = out.data, out.width * out.height * 4
  local state = seeded(seed or 1)
  local sigma = (attenuate or 0.02) * 255

  -- A pixel takes three deviates and they come two at a time, so two pixels take three pairs.
  for offset = 0, length - 4, 8 do
    local first, second, third, fourth
    first, second, state = deviates(state)
    third, fourth, state = deviates(state)

    buffer.writeu8(pixels, offset, clamp8(buffer.readu8(pixels, offset) + first * sigma))
    buffer.writeu8(pixels, offset + 1, clamp8(buffer.readu8(pixels, offset + 1) + second * sigma))
    buffer.writeu8(pixels, offset + 2, clamp8(buffer.readu8(pixels, offset + 2) + third * sigma))

    if offset + 4 < length then
      local fifth, sixth
      fifth, sixth, state = deviates(state)

      buffer.writeu8(pixels, offset + 4, clamp8(buffer.readu8(pixels, offset + 4) + fourth * sigma))
      buffer.writeu8(pixels, offset + 5, clamp8(buffer.readu8(pixels, offset + 5) + fifth * sigma))
      buffer.writeu8(pixels, offset + 6, clamp8(buffer.readu8(pixels, offset + 6) + sixth * sigma))
    end
  end

  return out
end

--- An image with a shadow under it: its alpha blurred by a Gaussian, drawn black at a percentage
--- of opaque and at an offset, in an image large enough for both.
function Magick.shadowed(image: Image, opacity: number?, sigma: number?, dx: number?, dy: number?): Image
  local strength, spread = (opacity or 80) / 100, sigma or 3
  local across, down = dx or 0, dy or 0
  local margin = math.max(1, math.ceil(spread * 2))
  local {width, height, data} = image
  local shadow = Magick.new(width + margin * 2, height + margin * 2)
  local count = shadow.width * shadow.height
  -- The shadow is black, so of the image only its alpha is blurred: one byte a pixel, inside a
  -- margin for the blur to spread into.
  local alphas, shades = buffer.create(count), buffer.create(256 * 4)

  for row = 0, height - 1 do
    local at, from = (row + margin) * shadow.width + margin, row * width * 4 + 3

    for column = 0, width - 1 do
      buffer.writeu8(alphas, at + column, buffer.readu8(data, from + column * 4))
    end
  end

  if not (spread <= 0) then
    local sharp = alphas

    alphas = buffer.create(count)
    blur(sharp, alphas, shadow.width, shadow.height, 1, spread)
  end

  for alpha = 1, 255 do
    buffer.writeu32(shades, alpha * 4, stored(0, 0, 0, alpha * strength))
  end

  shade(alphas, count, shades, shadow.data)

  local shadowLeft, shadowTop = across - margin, down - margin
  local left, top = math.min(0, shadowLeft), math.min(0, shadowTop)
  local right, bottom = math.max(width, shadowLeft + shadow.width), math.max(height, shadowTop + shadow.height)

  return Magick.new(right - left, bottom - top):over(shadow, shadowLeft - left, shadowTop - top):over(image, -left, -top)
end

--- Lays images out in a grid of cells the size of the first, left to right and then down.
function Magick.montage(images: { Image }, columns: number?, rows: number?): Image
  assert(#images > 0, 'magick: montage requires images')

  local across = columns or #images
  local down = rows or math.ceil(#images / across)
  local {width, height} = images[1]
  local out = Magick.new(width * across, height * down)

  for index, image in images do
    out:over(image, (index - 1) % across * width, math.floor((index - 1) / across) * height)
  end

  return out
end

Magick.Image = Image
return Magick
