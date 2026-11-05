-- luajit tests/parity/run.lua page.rgba width height
-- Runs the Lua detector on a raw RGBA file and prints the result as JSON.
-- Called by parity.mjs from the repository root.

package.path = "vineta.koplugin/?.lua;" .. package.path

local ffi = require("ffi")
local D = require("vineta_detect")
-- The JS (V8) rarely reaches the time budget of the framed method; LuaJIT is slower.
D.FRAMED_BUDGET_MS = tonumber(os.getenv("VINETA_BUDGET_MS") or "") or 1e9

local file, w, h = arg[1], tonumber(arg[2]), tonumber(arg[3])
local f = assert(io.open(file, "rb"))
local bytes = f:read("*a")
f:close()
assert(#bytes == w * h * 4, "size mismatch")
local rgba = D.u8(w * h * 4)
ffi.copy(rgba, bytes, #bytes)
bytes = nil

local t0 = os.clock()
local r = D.detectImage(rgba, w, h)
local ms = math.floor((os.clock() - t0) * 1000 + 0.5)

local function num(x) return string.format("%.17g", x) end
local function rects(list)
    local out = {}
    for i, q in ipairs(list) do
        out[i] = string.format('{"x":%s,"y":%s,"w":%s,"h":%s}', num(q.x), num(q.y), num(q.w), num(q.h))
    end
    return "[" .. table.concat(out, ",") .. "]"
end
io.write(string.format('{"kind":"%s","style":"%s","ms":%d,"panels":%s,"panelsRtl":%s}',
    r.kind, tostring(r.style), ms, rects(r.panels), rects(r.panelsRtl)))
