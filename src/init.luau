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

local function lcg(seed)
    local state = math.floor(seed or 1) % 2147483647
    if state <= 0 then state = 1 end
    return function()
        state = (state * 48271) % 2147483647
        return state / 2147483647
    end
end

function Magick.noise(width,height,color,seed,attenuate)
    local c=colorTable(color); local out=Magick.new(width,height); local random=lcg(seed or 1)
    -- ImageMagick's Gaussian noise on a flat color behaves multiplicatively: zero channels stay
    -- exactly zero and nonzero channels share almost the same per-pixel factor.  At attenuate=.25
    -- the measured sigma is ~7.84% of the channel value.
    local sigma=(attenuate or 0.25)*0.3137254901960784
    local spare=nil
    local function gaussian()
        if spare then local v=spare; spare=nil; return v end
        local u=math.max(1e-12,random()); local v=random(); local m=math.sqrt(-2*math.log(u)); local a=2*math.pi*v; spare=m*math.sin(a); return m*math.cos(a)
    end
    for y=0,height-1 do for x=0,width-1 do local f=1+gaussian()*sigma; out:set(x,y,clamp8(c[1]*f),clamp8(c[2]*f),clamp8(c[3]*f),c[4]) end end
    return out
end

function Magick.mask(width,height,bytes)
    if buffer.len(bytes) ~= width*height then error("magick: mask byte length mismatch",2) end
    return {width=width,height=height,data=bytes}
end

function Magick.maskToImage(mask,color)
    local c=colorTable(color or "#ffffff"); local out=Magick.new(mask.width,mask.height); local od=out.data; local md=mask.data
    local rgb=c[1]+c[2]*256+c[3]*65536; local alphaScale=c[4]/255
    for i=0,mask.width*mask.height-1 do local a=clamp8(buffer.readu8(md,i)*alphaScale); buffer.writeu32(od,i*4,rgb+a*16777216) end
    return out
end

function Magick.paintMask(mask,source)
    local out=Magick.new(mask.width,mask.height)
    for y=0,mask.height-1 do for x=0,mask.width-1 do local a=buffer.readu8(mask.data,y*mask.width+x); if a~=0 then local r,g,b,sa=sourcePixel(source,x,y); out:set(x,y,r,g,b,clamp8(sa*a/255)) end end end
    return out
end

function Magick.dilateMask(mask,radius)
    radius=math.max(0,math.floor(radius)); local out=buffer.create(mask.width*mask.height)
    for y=0,mask.height-1 do for x=0,mask.width-1 do local best=0
        for yy=math.max(0,y-radius),math.min(mask.height-1,y+radius) do for xx=math.max(0,x-radius),math.min(mask.width-1,x+radius) do local v=buffer.readu8(mask.data,yy*mask.width+xx); if v>best then best=v end end end
        buffer.writeu8(out,y*mask.width+x,best)
    end end
    return Magick.mask(mask.width,mask.height,out)
end

function Magick.blurMask(mask,radius)
    radius=math.max(0,math.floor(radius+0.5)); if radius==0 then local b=buffer.create(buffer.len(mask.data)); buffer.copy(b,0,mask.data,0,buffer.len(mask.data)); return Magick.mask(mask.width,mask.height,b) end
    local w,h=mask.width,mask.height; local temp=buffer.create(w*h); local out=buffer.create(w*h); local span=radius*2+1
    for y=0,h-1 do local sum=0
        for xx=-radius,radius do local sx=math.max(0,math.min(w-1,xx)); sum += buffer.readu8(mask.data,y*w+sx) end
        for x=0,w-1 do buffer.writeu8(temp,y*w+x,clamp8(sum/span)); local outx=math.max(0,x-radius); local inx=math.min(w-1,x+radius+1); sum += buffer.readu8(mask.data,y*w+inx)-buffer.readu8(mask.data,y*w+outx) end
    end
    for x=0,w-1 do local sum=0
        for yy=-radius,radius do local sy=math.max(0,math.min(h-1,yy)); sum += buffer.readu8(temp,sy*w+x) end
        for y=0,h-1 do buffer.writeu8(out,y*w+x,clamp8(sum/span)); local outy=math.max(0,y-radius); local iny=math.min(h-1,y+radius+1); sum += buffer.readu8(temp,iny*w+x)-buffer.readu8(temp,outy*w+x) end
    end
    return Magick.mask(w,h,out)
end

function Magick.subtractMask(a,b)
    assert(a.width==b.width and a.height==b.height,"magick: mask geometry mismatch"); local out=buffer.create(a.width*a.height)
    for i=0,a.width*a.height-1 do buffer.writeu8(out,i,math.max(0,buffer.readu8(a.data,i)-buffer.readu8(b.data,i))) end
    return Magick.mask(a.width,a.height,out)
end

function Magick.modulate(img,brightness,saturation)
    brightness=(brightness or 100)/100; saturation=(saturation or 100)/100
    for y=0,img.height-1 do for x=0,img.width-1 do local r,g,b,a=img:get(x,y); local gray=0.2126*r+0.7152*g+0.0722*b; r=(gray+(r-gray)*saturation)*brightness; g=(gray+(g-gray)*saturation)*brightness; b=(gray+(b-gray)*saturation)*brightness; img:set(x,y,r,g,b,a) end end
    return img
end

function Magick.emboss(img,strength)
    strength=strength or 1; local src=img:clone()
    for y=0,img.height-1 do for x=0,img.width-1 do local r,g,b,a=src:get(x,y); local pr,pg,pb=src:get(x-1,y-1); local nr,ng,nb=src:get(x+1,y+1); img:set(x,y,r+(nr-pr)*strength,g+(ng-pg)*strength,b+(nb-pb)*strength,a) end end
    return img
end

function Magick.tint(img,color,amount)
    local c=colorTable(color); local t=(amount or 100)/100
    for y=0,img.height-1 do for x=0,img.width-1 do local r,g,b,a=img:get(x,y); local lum=(r+g+b)/3/255; local tr=c[1]*lum; local tg=c[2]*lum; local tb=c[3]*lum; img:set(x,y,r+(tr-r)*t,g+(tg-g)*t,b+(tb-b)*t,a) end end
    return img
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

function Image:alphaMask()
    local n=self.width*self.height; local b=buffer.create(n); local d=self.data
    for i=0,n-1 do buffer.writeu8(b,i,buffer.readu8(d,i*4+3)) end
    return Magick.mask(self.width,self.height,b)
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

function Image:grayscale()
    local d=self.data
    for o=0,buffer.len(d)-4,4 do
        local r=buffer.readu8(d,o); local g=buffer.readu8(d,o+1); local b=buffer.readu8(d,o+2)
        local v=clamp8(0.212656*r+0.715158*g+0.072186*b)
        buffer.writeu8(d,o,v); buffer.writeu8(d,o+1,v); buffer.writeu8(d,o+2,v)
    end
    return self
end

function Image:threshold(level)
    if level<=1 then level*=255 end
    local d=self.data
    for o=0,buffer.len(d)-4,4 do
        local v=((buffer.readu8(d,o)+buffer.readu8(d,o+1)+buffer.readu8(d,o+2))/3)>=level and 255 or 0
        buffer.writeu8(d,o,v); buffer.writeu8(d,o+1,v); buffer.writeu8(d,o+2,v)
    end
    return self
end

function Image:colorize(color,amount)
    local c=colorTable(color); local t=(amount or 100)/100; local d=self.data
    for o=0,buffer.len(d)-4,4 do
        local r=buffer.readu8(d,o); local g=buffer.readu8(d,o+1); local b=buffer.readu8(d,o+2)
        buffer.writeu8(d,o,clamp8(r+(c[1]-r)*t)); buffer.writeu8(d,o+1,clamp8(g+(c[2]-g)*t)); buffer.writeu8(d,o+2,clamp8(b+(c[3]-b)*t))
    end
    return self
end

function Image:transparent(color)
    local c=colorTable(color)
    for y=0,self.height-1 do for x=0,self.width-1 do local r,g,b,a=self:get(x,y); if r==c[1] and g==c[2] and b==c[3] then self:set(x,y,r,g,b,0) end end end
    return self
end

function Image:opaque(fromColor,toColor)
    local f=colorTable(fromColor); local t=colorTable(toColor)
    for y=0,self.height-1 do for x=0,self.width-1 do local r,g,b,a=self:get(x,y); if r==f[1] and g==f[2] and b==f[3] then self:set(x,y,t[1],t[2],t[3],a) end end end
    return self
end

--- Sets every pixel's alpha: a value up to 1 is a share of opaque, a larger one the byte itself.
function Image.setAlpha(self: Image, value: number): Image
  local alpha = if value <= 1 then clamp8(value * 255) else clamp8(value)
  local count = self.width * self.height

  if count > 0 then dataPlane.fill(self.data, 'u8@4+3', 0, count, alpha) end

  return self
end

function Image:darken(src,dx,dy)
    dx=dx or 0; dy=dy or 0
    for sy=0,src.height-1 do local ty=sy+dy; if ty>=0 and ty<self.height then for sx=0,src.width-1 do local tx=sx+dx; if tx>=0 and tx<self.width then
        local sr,sg,sb,sa=src:get(sx,sy); if sa>0 then local dr,dg,db,da=self:get(tx,ty); self:set(tx,ty,math.min(dr,sr),math.min(dg,sg),math.min(db,sb),math.max(da,sa)) end
    end end end end
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

local function gaussianKernel(sigma)
    sigma=math.max(0.01,sigma); local radius=math.max(1,math.ceil(sigma*3)); local k={}; local sum=0
    for i=-radius,radius do local v=math.exp(-(i*i)/(2*sigma*sigma)); k[#k+1]=v; sum+=v end
    for i=1,#k do k[i]/=sum end
    return k,radius
end

function Magick.gaussianBlur(img,sigma)
    if sigma<=0 then return img:clone() end
    local k,r=gaussianKernel(sigma); local width=img.width; local height=img.height
    local src=img.data; local tmp=Magick.new(width,height); local td=tmp.data; local out=Magick.new(width,height); local od=out.data
    local kernelSize=#k
    local interiorX0=r; local interiorX1=width-r-1
    for y=0,height-1 do
        local row=y*width*4
        local leftEnd=math.min(width-1,r-1)
        for x=0,leftEnd do
            local rr,gg,bb,aa=0,0,0,0
            for i=-r,r do local sx=math.max(0,math.min(width-1,x+i)); local so=row+sx*4; local weight=k[i+r+1]; rr+=buffer.readu8(src,so)*weight; gg+=buffer.readu8(src,so+1)*weight; bb+=buffer.readu8(src,so+2)*weight; aa+=buffer.readu8(src,so+3)*weight end
            local o=row+x*4; buffer.writeu8(td,o,clamp8(rr)); buffer.writeu8(td,o+1,clamp8(gg)); buffer.writeu8(td,o+2,clamp8(bb)); buffer.writeu8(td,o+3,clamp8(aa))
        end
        if interiorX0<=interiorX1 then
            for x=interiorX0,interiorX1 do
                local rr,gg,bb,aa=0,0,0,0; local so=row+(x-r)*4
                for ki=1,kernelSize do local weight=k[ki]; rr+=buffer.readu8(src,so)*weight; gg+=buffer.readu8(src,so+1)*weight; bb+=buffer.readu8(src,so+2)*weight; aa+=buffer.readu8(src,so+3)*weight; so+=4 end
                local o=row+x*4; buffer.writeu8(td,o,clamp8(rr)); buffer.writeu8(td,o+1,clamp8(gg)); buffer.writeu8(td,o+2,clamp8(bb)); buffer.writeu8(td,o+3,clamp8(aa))
            end
        end
        local rightStart=math.max(leftEnd+1,width-r)
        for x=rightStart,width-1 do
            local rr,gg,bb,aa=0,0,0,0
            for i=-r,r do local sx=math.max(0,math.min(width-1,x+i)); local so=row+sx*4; local weight=k[i+r+1]; rr+=buffer.readu8(src,so)*weight; gg+=buffer.readu8(src,so+1)*weight; bb+=buffer.readu8(src,so+2)*weight; aa+=buffer.readu8(src,so+3)*weight end
            local o=row+x*4; buffer.writeu8(td,o,clamp8(rr)); buffer.writeu8(td,o+1,clamp8(gg)); buffer.writeu8(td,o+2,clamp8(bb)); buffer.writeu8(td,o+3,clamp8(aa))
        end
    end
    local stride=width*4; local interiorY0=r; local interiorY1=height-r-1
    for y=0,height-1 do
        local middle=y>=interiorY0 and y<=interiorY1
        for x=0,width-1 do
            local rr,gg,bb,aa=0,0,0,0
            if middle then
                local so=(y-r)*stride+x*4
                for ki=1,kernelSize do local weight=k[ki]; rr+=buffer.readu8(td,so)*weight; gg+=buffer.readu8(td,so+1)*weight; bb+=buffer.readu8(td,so+2)*weight; aa+=buffer.readu8(td,so+3)*weight; so+=stride end
            else
                for i=-r,r do local sy=math.max(0,math.min(height-1,y+i)); local so=sy*stride+x*4; local weight=k[i+r+1]; rr+=buffer.readu8(td,so)*weight; gg+=buffer.readu8(td,so+1)*weight; bb+=buffer.readu8(td,so+2)*weight; aa+=buffer.readu8(td,so+3)*weight end
            end
            local o=y*stride+x*4; buffer.writeu8(od,o,clamp8(rr)); buffer.writeu8(od,o+1,clamp8(gg)); buffer.writeu8(od,o+2,clamp8(bb)); buffer.writeu8(od,o+3,clamp8(aa))
        end
    end
    return out
end

function Magick.mathCompose(a,b,k1,k2,k3,k4)
    assert(a.width==b.width and a.height==b.height,"magick: geometry mismatch"); local out=Magick.new(a.width,a.height); k1=k1 or 0;k2=k2 or 1;k3=k3 or 0;k4=k4 or 0
    for y=0,a.height-1 do for x=0,a.width-1 do local ar,ag,ab,aa=a:get(x,y); local br,bg,bb=b:get(x,y); local function f(u,v) return clamp8((k1*(u/255)*(v/255)+k2*(u/255)+k3*(v/255)+k4)*255) end; out:set(x,y,f(ar,br),f(ag,bg),f(ab,bb),aa) end end
    return out
end

function Image:polynomial(slope,intercept)
    local d=self.data; local bias=intercept*255
    for o=0,buffer.len(d)-4,4 do
        buffer.writeu8(d,o,clamp8(buffer.readu8(d,o)*slope+bias))
        buffer.writeu8(d,o+1,clamp8(buffer.readu8(d,o+1)*slope+bias))
        buffer.writeu8(d,o+2,clamp8(buffer.readu8(d,o+2)*slope+bias))
    end
    return self
end

function Image:contrastStretch(lowPct,highPct)
    local hist={}; for i=0,255 do hist[i]=0 end; local n=self.width*self.height
    for y=0,self.height-1 do for x=0,self.width-1 do local r,g,b=self:get(x,y); hist[clamp8((r+g+b)/3)]+=1 end end
    local loTarget=n*(lowPct or 0)/100; local hiTarget=n*(1-(highPct or 0)/100); local acc=0; local lo=0; local hi=255
    for i=0,255 do acc+=hist[i]; if acc>=loTarget then lo=i; break end end
    acc=0; for i=0,255 do acc+=hist[i]; if acc>=hiTarget then hi=i; break end end
    if hi<=lo then return self end
    local scale=255/(hi-lo)
    for y=0,self.height-1 do for x=0,self.width-1 do local r,g,b,a=self:get(x,y); self:set(x,y,(r-lo)*scale,(g-lo)*scale,(b-lo)*scale,a) end end
    return self
end

function Image:sigmoidalContrast(contrast,midpoint)
    local c=contrast or 2; local m=(midpoint or 0.5); if m>1 then m/=100 end
    local function sig(x) return 1/(1+math.exp(c*(m-x))) end
    local lo=sig(0); local hi=sig(1); local denom=hi-lo
    for y=0,self.height-1 do for x=0,self.width-1 do local r,g,b,a=self:get(x,y); local function f(v) return (sig(v/255)-lo)/denom*255 end; self:set(x,y,f(r),f(g),f(b),a) end end
    return self
end

function Image:median()
    local hist={}; for i=0,255 do hist[i]=0 end; local n=self.width*self.height
    for y=0,self.height-1 do for x=0,self.width-1 do local r,g,b=self:get(x,y); hist[clamp8((r+g+b)/3)]+=1 end end
    local acc=0; for i=0,255 do acc+=hist[i]; if acc*2>=n then return i end end; return 0
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

function Magick.randomNoise(width,height,seed)
    local random=lcg(seed or 1); local out=Magick.new(width,height)
    for y=0,height-1 do for x=0,width-1 do local v=math.floor(random()*256); out:set(x,y,v,v,v,255) end end
    return out
end

function Magick.addGaussianNoise(img,seed,attenuate)
    local out=img:clone(); local random=lcg(seed or 1); local spare=nil; local sigma=(attenuate or 0.02)*255
    local function gaussian() if spare then local v=spare; spare=nil; return v end local u=math.max(1e-12,random()); local v=random(); local m=math.sqrt(-2*math.log(u)); local a=2*math.pi*v; spare=m*math.sin(a); return m*math.cos(a) end
    for y=0,out.height-1 do for x=0,out.width-1 do local r,g,b,a=out:get(x,y); out:set(x,y,r+gaussian()*sigma,g+gaussian()*sigma,b+gaussian()*sigma,a) end end
    return out
end

function Magick.shadowed(img,opacity,sigma,dx,dy)
    opacity=(opacity or 80)/100; sigma=sigma or 3; dx=dx or 0; dy=dy or 0
    local margin=math.max(1,math.ceil(sigma*2))
    local padded=Magick.new(img.width+margin*2,img.height+margin*2)
    for y=0,img.height-1 do for x=0,img.width-1 do local _,_,_,a=img:get(x,y); if a>0 then padded:set(x+margin,y+margin,255,255,255,a) end end end
    local blurred=Magick.gaussianBlur(padded,sigma)
    local shadow=Magick.new(padded.width,padded.height)
    for y=0,blurred.height-1 do for x=0,blurred.width-1 do local _,_,_,a=blurred:get(x,y); if a>0 then shadow:set(x,y,0,0,0,a*opacity) end end end
    local sx=dx-margin; local sy=dy-margin
    local minx=math.min(0,sx); local miny=math.min(0,sy)
    local maxx=math.max(img.width,sx+shadow.width); local maxy=math.max(img.height,sy+shadow.height)
    local out=Magick.new(maxx-minx,maxy-miny)
    out:over(shadow,sx-minx,sy-miny)
    out:over(img,-minx,-miny)
    return out
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
