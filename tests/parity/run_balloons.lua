-- luajit tests/parity/run_balloons.lua < list
-- Each input line: "file width height whole" (raw RGBA crop; whole = 1 for a whole page).
-- Prints a JSON array with { ltr, rtl } balloons per crop. Called by balloons.mjs.

package.path = "vineta.koplugin/?.lua;" .. package.path

local ffi = require("ffi")
local D = require("vineta_detect")

local function num(x) return string.format("%.17g", x) end
local function rects(list)
    local out = {}
    for i, q in ipairs(list) do
        out[i] = string.format('{"x":%s,"y":%s,"w":%s,"h":%s}', num(q.x), num(q.y), num(q.w), num(q.h))
    end
    return "[" .. table.concat(out, ",") .. "]"
end

local results = {}
for line in io.lines() do
    local file, w, h, whole = line:match("^(.-) (%d+) (%d+) ([01])$")
    if file then
        w, h = tonumber(w), tonumber(h)
        local f = assert(io.open(file, "rb"))
        local bytes = f:read("*a")
        f:close()
        assert(#bytes == w * h * 4, "size mismatch " .. file)
        local rgba = D.u8(w * h * 4)
        ffi.copy(rgba, bytes, #bytes)
        local b = D.detectBalloonsBoth(rgba, w, h, whole == "1")
        results[#results + 1] = string.format('{"ltr":%s,"rtl":%s}', rects(b.ltr), rects(b.rtl))
    end
end
io.write("[" .. table.concat(results, ",") .. "]")
