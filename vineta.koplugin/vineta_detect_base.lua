--[[--
Shared table and helpers of the Lua port of Viñeta's panel detector
(tools/panels/detector/panels-core.js, Viñeta 3.6.1).

Every top-level function and constant of panels-core.js lives in this table `D`
(D.detectPanels, D.TOL…). The port is split in several files
(vineta_detect_a.lua … _d.lua) that add their functions to D; vineta_detect.lua
loads them all. Conventions of the port: see docs/detector-lua.md.

Typed arrays are FFI arrays: 0-based, same index arithmetic as the JS code.
Their length is kept in a weak table (D.len).
]]

local ffi = require("ffi")
local bit = require("bit")

local D = {}

-- ---------------------------------------------------------------------------
-- Constants from the head of panels-core.js

D.DETECT_MAX = 900
D.FULL_PAGE = { x = 0, y = 0, w = 1, h = 1 }
D.TOL = 40
D.DARK_INK = 60
D.DARK_CUT_LOW = 0.05
D.DARK_CUT_HIGH = 0.15
D.FRAMED_MAX_SEGS = 250
D.FRAMED_MAX_PAIRS = 6000
D.FRAMED_BUDGET_MS = 1500
D.PAPER = 210
D.TUNE = {
    darkPage = 0.3,
    darkColorPage = 0.12,
    paperCap = D.PAPER,
    paperDrop = 25,
    framedCap = 235,
    framedDrop = 20,
}

-- ---------------------------------------------------------------------------
-- Typed arrays

local LEN = setmetatable({}, { __mode = "k" })    -- array → length
local PARENT = setmetatable({}, { __mode = "k" }) -- view → array it points into (keeps it alive)
D._LEN = LEN

local function alloc(ctype)
    local ct = ffi.typeof(ctype .. "[?]")
    return function(n)
        n = n or 0
        if n < 0 then n = 0 end
        n = math.floor(n)
        local a = ct(n) -- zero-filled, like JS
        LEN[a] = n
        return a
    end
end

D.u8 = alloc("uint8_t")   -- Uint8Array and Uint8ClampedArray (write clamped values with D.clamp8)
D.i8 = alloc("int8_t")
D.u16 = alloc("uint16_t")
D.i16 = alloc("int16_t")
D.u32 = alloc("uint32_t")
D.i32 = alloc("int32_t")
D.f32 = alloc("float")
D.f64 = alloc("double")   -- also for JS number arrays of fixed size (new Array(n).fill(0))

-- Length of an array made by the helpers above (JS `.length`).
function D.len(a)
    local n = LEN[a]
    if n == nil then error("vineta_detect: length of an unknown array", 2) end
    return n
end

-- Registers an array that was not made by the helpers (for example a buffer from KOReader).
function D.adopt(a, n, parent)
    LEN[a] = n
    if parent then PARENT[a] = parent end
    return a
end

local ELEM = {}
local function maker(a)
    -- New array of the same element type.
    local t = tostring(ffi.typeof(a))
    local m = ELEM[t]
    if m then return m end
    for _, name in ipairs({ "u8", "i8", "u16", "i16", "u32", "i32", "f32", "f64" }) do
        if tostring(ffi.typeof(D[name](0))) == t then
            ELEM[t] = D[name]
            return D[name]
        end
    end
    -- Pointer views (D.sub) of each type.
    local base = t:match("^ctype<(.-) %*>$") or t:match("^ctype<(.-) %[.*%]>$")
    local map = {
        ["unsigned char"] = D.u8, ["uint8_t"] = D.u8, ["char"] = D.i8, ["int8_t"] = D.i8,
        ["unsigned short"] = D.u16, ["uint16_t"] = D.u16, ["short"] = D.i16, ["int16_t"] = D.i16,
        ["unsigned int"] = D.u32, ["uint32_t"] = D.u32, ["int"] = D.i32, ["int32_t"] = D.i32,
        ["float"] = D.f32, ["double"] = D.f64,
    }
    m = base and map[base]
    if not m then error("vineta_detect: unknown array type " .. t, 3) end
    ELEM[t] = m
    return m
end

-- JS a.subarray(from, to): a view that shares memory.
function D.sub(a, from, to)
    local n = D.len(a)
    from = from or 0
    to = to or n
    if from < 0 then from = math.max(0, n + from) end
    if to < 0 then to = math.max(0, n + to) end
    if to > n then to = n end
    if from > to then from = to end
    local p = a + from
    LEN[p] = to - from
    PARENT[p] = a
    return p
end

-- JS a.slice(from, to) of a typed array: a copy.
function D.slice(a, from, to)
    local n = D.len(a)
    from = from or 0
    to = to or n
    if from < 0 then from = math.max(0, n + from) end
    if to < 0 then to = math.max(0, n + to) end
    if to > n then to = n end
    local m = math.max(0, to - from)
    local b = maker(a)(m)
    if m > 0 then ffi.copy(b, a + from, ffi.sizeof(b)) end -- sizeof of a VLA: its bytes
    return b
end

-- JS new XArray(a) from another typed array (same element type: plain copy).
function D.copyArray(a)
    return D.slice(a, 0)
end

-- JS a.fill(v, from, to).
function D.fill(a, v, from, to)
    local n = D.len(a)
    from = from or 0
    to = to or n
    if from < 0 then from = math.max(0, n + from) end
    if to < 0 then to = math.max(0, n + to) end
    if to > n then to = n end
    for i = from, to - 1 do a[i] = v end
    return a
end

-- JS dst.set(src, offset) between typed arrays.
function D.set(dst, src, offset)
    offset = offset or 0
    local n = D.len(src)
    for i = 0, n - 1 do dst[offset + i] = src[i] end
end

-- JS typedArray.sort() (numeric, ascending, in place).
function D.sortTyped(a)
    local n = D.len(a)
    local t = {}
    for i = 0, n - 1 do t[i + 1] = a[i] end
    table.sort(t)
    for i = 0, n - 1 do a[i] = t[i + 1] end
    return a
end

-- ---------------------------------------------------------------------------
-- Numbers

local floor, ceil = math.floor, math.ceil

-- JS Math.round: halves go up (towards +∞).
function D.round(x)
    return floor(x + 0.5)
end

-- JS Math.trunc and `x | 0` for values in the int32 range.
function D.trunc(x)
    if x >= 0 then return floor(x) end
    return ceil(x)
end

-- JS `x | 0` (ToInt32: truncation and wrap to 32 bits).
function D.toint(x)
    if x ~= x or x == math.huge or x == -math.huge then return 0 end
    return bit.tobit(D.trunc(x) % 4294967296)
end

function D.sign(x)
    if x > 0 then return 1 elseif x < 0 then return -1 end
    return x -- 0, -0 or NaN
end

function D.hypot(a, b)
    return math.sqrt(a * a + b * b)
end

-- JS % (remainder with the sign of the dividend).
D.fmod = math.fmod

-- Value stored by a Uint8ClampedArray: clamp to 0..255, round half to even.
function D.clamp8(v)
    if v ~= v then return 0 end
    if v <= 0 then return 0 end
    if v >= 255 then return 255 end
    local f = floor(v)
    local d = v - f
    if d > 0.5 then return f + 1 end
    if d < 0.5 then return f end
    if f % 2 == 0 then return f end
    return f + 1
end

-- JS Math.max / Math.min with NaN propagation (math.max is unreliable with NaN).
function D.max(a, b, ...)
    if select("#", ...) > 0 then return D.max(D.max(a, b), ...) end
    if b == nil then return a end
    if a ~= a or b ~= b then return 0 / 0 end
    if a >= b then return a end
    return b
end

function D.min(a, b, ...)
    if select("#", ...) > 0 then return D.min(D.min(a, b), ...) end
    if b == nil then return a end
    if a ~= a or b ~= b then return 0 / 0 end
    if a <= b then return a end
    return b
end

D.INF = math.huge

-- Milliseconds of CPU time (JS performance.now() for the time budgets).
function D.now()
    return os.clock() * 1000
end

-- ---------------------------------------------------------------------------
-- Lists (Lua tables, 1-based)

-- Stable sort in place, like JS Array.prototype.sort: cmp(a, b) returns a number,
-- negative if a goes first. JS sorts holes/undefined last; lists here have none.
function D.sort(t, cmp)
    local n = #t
    if n < 2 then return t end
    -- Insertion sort for short lists, merge sort for long ones: both stable.
    if n <= 16 then
        for i = 2, n do
            local v = t[i]
            local j = i - 1
            while j >= 1 and cmp(t[j], v) > 0 do
                t[j + 1] = t[j]
                j = j - 1
            end
            t[j + 1] = v
        end
        return t
    end
    local src, dst = t, {}
    local width = 1
    while width < n do
        local i = 1
        while i <= n do
            local mid = math.min(i + width, n + 1)
            local hi = math.min(i + 2 * width, n + 1)
            local a, b, k = i, mid, i
            while a < mid and b < hi do
                if cmp(src[b], src[a]) < 0 then
                    dst[k] = src[b]; b = b + 1
                else
                    dst[k] = src[a]; a = a + 1
                end
                k = k + 1
            end
            while a < mid do dst[k] = src[a]; a = a + 1; k = k + 1 end
            while b < hi do dst[k] = src[b]; b = b + 1; k = k + 1 end
            i = i + 2 * width
        end
        src, dst = dst, src
        width = width * 2
    end
    if src ~= t then
        for i = 1, n do t[i] = src[i] end
    end
    return t
end

-- Comparator for JS sort((a, b) => a - b) of plain numbers.
function D.numcmp(a, b) return a - b end

-- [...a, ...b, ...]: new list with the items of every list given (nil lists are skipped).
function D.concat(...)
    local out = {}
    for k = 1, select("#", ...) do
        local l = select(k, ...)
        if l then
            for i = 1, #l do out[#out + 1] = l[i] end
        end
    end
    return out
end

-- { ...obj, ...extra }: shallow copy with fields replaced.
function D.assign(obj, extra)
    local out = {}
    if obj then for k, v in pairs(obj) do out[k] = v end end
    if extra then for k, v in pairs(extra) do out[k] = v end end
    return out
end

function D.map(t, fn)
    local out = {}
    for i = 1, #t do out[i] = fn(t[i], i) end
    return out
end

function D.filter(t, fn)
    local out = {}
    for i = 1, #t do
        if fn(t[i], i) then out[#out + 1] = t[i] end
    end
    return out
end

function D.some(t, fn)
    for i = 1, #t do
        if fn(t[i], i) then return true end
    end
    return false
end

function D.every(t, fn)
    for i = 1, #t do
        if not fn(t[i], i) then return false end
    end
    return true
end

function D.find(t, fn)
    for i = 1, #t do
        if fn(t[i], i) then return t[i] end
    end
    return nil
end

-- Lua index of v in t, or nil (JS indexOf/findIndex return -1 instead).
function D.indexOf(t, v)
    for i = 1, #t do
        if t[i] == v then return i end
    end
    return nil
end

-- JS a.splice(start0, count, ...items) with a 0-based start; returns the removed items.
function D.splice(t, start0, count, ...)
    local n = #t
    if start0 < 0 then start0 = math.max(0, n + start0) end
    if start0 > n then start0 = n end
    if count == nil then count = n - start0 end
    count = math.max(0, math.min(count, n - start0))
    local removed = {}
    for i = 1, count do removed[i] = t[start0 + i] end
    local items = { ... }
    local rest = {}
    for i = start0 + count + 1, n do rest[#rest + 1] = t[i] end
    for i = n, start0 + 1, -1 do t[i] = nil end
    for i = 1, #items do t[start0 + i] = items[i] end
    local base = start0 + #items
    for i = 1, #rest do t[base + i] = rest[i] end
    return removed
end

-- JS a.reverse() in place.
function D.reverse(t)
    local i, j = 1, #t
    while i < j do
        t[i], t[j] = t[j], t[i]
        i = i + 1
        j = j - 1
    end
    return t
end

-- JS a.flat() (one level).
function D.flat(t)
    local out = {}
    for i = 1, #t do
        local v = t[i]
        -- A list (it has [1], or is empty), not an object such as a rect.
        if type(v) == "table" and (v[1] ~= nil or next(v) == nil) then
            for j = 1, #v do out[#out + 1] = v[j] end
        else
            out[#out + 1] = v
        end
    end
    return out
end

-- JS a.reduce(fn, init).
function D.reduce(t, fn, init)
    local acc = init
    for i = 1, #t do acc = fn(acc, t[i], i) end
    return acc
end

-- JS Map / Set keep insertion order; Lua tables do not. Ordered map:
--   local m = D.Map(); m:set(k, v); m:get(k); m:has(k); m:delete(k); m.size; for _, k, v in m:iter()
local MapMT = {}
MapMT.__index = MapMT

function D.Map()
    return setmetatable({ keys = {}, vals = {}, pos = {}, size = 0 }, MapMT)
end

function MapMT:set(k, v)
    if self.pos[k] == nil then
        self.keys[#self.keys + 1] = k
        self.pos[k] = #self.keys
        self.size = self.size + 1
    end
    self.vals[k] = v
    return self
end

function MapMT:get(k) return self.vals[k] end
function MapMT:has(k) return self.pos[k] ~= nil end

function MapMT:delete(k)
    local p = self.pos[k]
    if p == nil then return false end
    table.remove(self.keys, p)
    self.pos[k] = nil
    self.vals[k] = nil
    for i = p, #self.keys do self.pos[self.keys[i]] = i end
    self.size = self.size - 1
    return true
end

-- Iterates in insertion order: for i, k, v in m:iter() do … end
function MapMT:iter()
    local i = 0
    return function()
        i = i + 1
        local k = self.keys[i]
        if k == nil then return nil end
        return i, k, self.vals[k]
    end
end

-- Ordered set: D.Set(); s:add(k); s:has(k); s:delete(k); s.size; for _, k in s:iter()
function D.Set(list)
    local s = D.Map()
    s.add = function(self, k) return self:set(k, true) end
    if list then for i = 1, #list do s:add(list[i]) end end
    return s
end

return D
