--[[--
Lua port of Viñeta's panel detector, part D: panels-core.js lines 2986-3487
(orderRects … halve) and 3624-4209 (BALLOON_* … reattachBalloons).
See docs/detector-lua.md for the conventions.
]]

local ffi = require("ffi")
local bit = require("bit")
local D = require("vineta_detect_base")

local floor, abs = math.floor, math.abs
local bor, rshift, lshift, bxor = bit.bor, bit.rshift, bit.lshift, bit.bxor

-- Copy of a byte array (new Uint8Array(a) / new Uint8ClampedArray(a) / a.slice()).
-- (D.copyArray is not used: D.slice calls ffi.typeof on an element, a number, and fails.)
local function copyU8(a)
    local n = D.len(a)
    local b = D.u8(n)
    if n > 0 then ffi.copy(b, a, n) end
    return b
end

-- ---------------------------------------------------------------------------
-- Constants (JS 3624-3628)

D.BALLOON_PANEL = { area = 0.004, w = 0.05, h = 0.04, maxArea = 0.35, letter = 0, biggest = 0.5, text = true }
D.BALLOON_PAGE = { area = 0.0012, w = 0.03, h = 0.015, maxArea = 0.12, letter = 0.005, biggest = 0.5, text = true }
D.BALLOON_GUTTER = D.assign(D.BALLOON_PAGE, { letter = 0, biggest = 0.3, text = false })
D.COVERAGE_MIN = 0.45

-- ---------------------------------------------------------------------------
-- Reading order

function D.orderRects(rects, rtl)
    local nr = #rects
    if nr <= 1 then
        local copy = {}
        for i = 1, nr do copy[i] = rects[i] end
        return copy
    end
    local hs = D.sort(D.map(rects, function(r) return r.y1 - r.y0 end), D.numcmp)
    local medH = hs[rshift(nr, 1) + 1]
    local ws = D.sort(D.map(rects, function(r) return r.x1 - r.x0 end), D.numcmp)
    local medW = ws[rshift(nr, 1) + 1]
    local function cutAt(key0, key1, slack)
        local sorted = {}
        for i = 1, nr do sorted[i] = rects[i] end
        D.sort(sorted, function(a, b) return a[key0] - b[key0] end)
        local e = sorted[1][key1]
        for i = 2, #sorted do
            if sorted[i][key0] >= e - slack then
                return (sorted[i][key0] + math.min(e, sorted[i][key0])) / 2
            end
            e = math.max(e, sorted[i][key1])
        end
        return nil
    end
    local y = cutAt("y0", "y1", 0.2 * medH)
    if y ~= nil then
        local top = D.filter(rects, function(r) return (r.y0 + r.y1) / 2 < y end)
        local bottom = D.filter(rects, function(r) return (r.y0 + r.y1) / 2 >= y end)
        if #top > 0 and #bottom > 0 then
            return D.concat(D.orderRects(top, rtl), D.orderRects(bottom, rtl))
        end
    end
    local x = cutAt("x0", "x1", 0.2 * medW)
    if x ~= nil then
        local left = D.filter(rects, function(r) return (r.x0 + r.x1) / 2 < x end)
        local right = D.filter(rects, function(r) return (r.x0 + r.x1) / 2 >= x end)
        if #left > 0 and #right > 0 then
            if rtl then
                return D.concat(D.orderRects(right, rtl), D.orderRects(left, rtl))
            end
            return D.concat(D.orderRects(left, rtl), D.orderRects(right, rtl))
        end
    end
    return D.readingOrder(rects, rtl)
end

-- ---------------------------------------------------------------------------
-- Background and mask

-- Returns { color = {r, g, b} (1-based list), ratio }.
function D.estimateBackground(d, w, h)
    local TOL = D.TOL
    local t = math.max(2, D.round(math.min(w, h) * 0.015))
    local bins = D.Map()
    local samples = {}
    local ns = 0
    local function sample(x, y)
        local i = (y * w + x) * 4
        ns = ns + 1
        samples[ns] = i
        local key = bor(lshift(rshift(d[i], 5), 6), lshift(rshift(d[i + 1], 5), 3), rshift(d[i + 2], 5))
        local b = bins:get(key)
        if not b then
            b = { 0, 0, 0, 0 }
            bins:set(key, b)
        end
        b[1] = b[1] + 1
        b[2] = b[2] + d[i]
        b[3] = b[3] + d[i + 1]
        b[4] = b[4] + d[i + 2]
    end
    for y = 0, t - 1 do
        for x = 0, w - 1, 2 do
            sample(x, y)
            sample(x, h - 1 - y)
        end
    end
    for x = 0, t - 1 do
        for y = t, h - t - 1, 2 do
            sample(x, y)
            sample(w - 1 - x, y)
        end
    end

    local top = nil
    for _, _, b in bins:iter() do
        if not top or b[1] > top[1] then top = b end
    end
    local color = { top[2] / top[1], top[3] / top[1], top[4] / top[1] }
    local c1, c2, c3 = color[1], color[2], color[3]

    local near = 0
    for k = 1, ns do
        local i = samples[k]
        if abs(d[i] - c1) <= TOL and abs(d[i + 1] - c2) <= TOL and abs(d[i + 2] - c3) <= TOL then
            near = near + 1
        end
    end
    return { color = color, ratio = near / ns }
end

-- bgc: 1-based list {r, g, b}.
function D.buildMask(d, w, h, bgc)
    local TOL = D.TOL
    local br, bg, bb = bgc[1], bgc[2], bgc[3]
    local n = w * h
    local m = D.u8(n)
    local i = 0
    for p = 0, n - 1 do
        if abs(d[i] - br) > TOL or abs(d[i + 1] - bg) > TOL or abs(d[i + 2] - bb) > TOL then
            m[p] = 1
        end
        i = i + 4
    end
    return m
end

function D.removeSpecks(m, w, h)
    local out = copyU8(m)
    for y = 1, h - 2 do
        local i = y * w + 1
        for _ = 1, w - 2 do
            if m[i] ~= 0
                and m[i - 1] == 0 and m[i + 1] == 0 and m[i - w] == 0 and m[i + w] == 0
                and m[i - w - 1] == 0 and m[i - w + 1] == 0 and m[i + w - 1] == 0 and m[i + w + 1] == 0 then
                out[i] = 0
            end
            i = i + 1
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- XY-cut

function D.xyCut(c, x0, y0, x1, y1, depth, out)
    local pr = D.profiles(c, x0, y0, x1, y1)
    local rows, cols = pr.rows, pr.cols
    local rowNoise = D.noiseLevel(x1 - x0)
    local colNoise = D.noiseLevel(y1 - y0)
    local ry = D.span(rows, rowNoise)
    local rx = D.span(cols, colNoise)
    if not ry or not rx then return end

    local nx0 = x0 + rx[1]
    local nx1 = x0 + rx[2]
    local ny0 = y0 + ry[1]
    local ny1 = y0 + ry[2]

    if depth < 12 then
        local bands = D.runs(D.sub(rows, ry[1], ry[2]), rowNoise, c.minGapY)
        if #bands > 1 then
            for k = 1, #bands do
                local a, b = bands[k][1], bands[k][2]
                D.xyCut(c, nx0, ny0 + a, nx1, ny0 + b, depth + 1, out)
            end
            return
        end
        local strips = D.runs(D.sub(cols, rx[1], rx[2]), colNoise, c.minGapX)
        if #strips > 1 then
            if c.rtl then D.reverse(strips) end
            for k = 1, #strips do
                local a, b = strips[k][1], strips[k][2]
                D.xyCut(c, nx0 + a, ny0, nx0 + b, ny1, depth + 1, out)
            end
            return
        end
    end
    out[#out + 1] = { x0 = nx0, y0 = ny0, x1 = nx1, y1 = ny1 }
end

-- Returns { rows = u32 array, cols = u32 array }.
function D.profiles(c, x0, y0, x1, y1)
    local mask, w = c.mask, c.w
    local rows = D.u32(y1 - y0)
    local cols = D.u32(x1 - x0)
    for y = y0, y1 - 1 do
        local o = y * w
        local n = 0
        for x = x0, x1 - 1 do
            if mask[o + x] ~= 0 then
                n = n + 1
                cols[x - x0] = cols[x - x0] + 1
            end
        end
        rows[y - y0] = n
    end
    return { rows = rows, cols = cols }
end

function D.noiseLevel(len)
    return math.max(1, floor(len * 0.002))
end

-- Returns nil or {a, b} (1-based list holding 0-based offsets).
function D.span(p, noise)
    local a = -1
    local b = -1
    for i = 0, D.len(p) - 1 do
        if p[i] > noise then
            if a < 0 then a = i end
            b = i
        end
    end
    if a < 0 then return nil end
    return { a, b + 1 }
end

-- Returns a list of {start, end} pairs (0-based offsets).
function D.runs(p, noise, minGap)
    local out = {}
    local start = -1
    local last = -1
    for i = 0, D.len(p) - 1 do
        if p[i] <= noise then goto continue end
        if start < 0 then
            start = i
        elseif i - last - 1 >= minGap then
            out[#out + 1] = { start, last + 1 }
            start = i
        end
        last = i
        ::continue::
    end
    if start >= 0 then out[#out + 1] = { start, last + 1 } end
    return out
end

function D.looksLikeText(c, r)
    local rw = r.x1 - r.x0
    local rh = r.y1 - r.y0
    local rows = D.profiles(c, r.x0, r.y0, r.x1, r.y1).rows
    local ink = 0
    for i = 0, D.len(rows) - 1 do ink = ink + rows[i] end
    if ink / (rw * rh) > 0.45 then return false end
    return D.looksLikeLines(D.runs(rows, D.noiseLevel(rw), 1), c.h)
end

function D.looksLikeLines(bands, pageH)
    if #bands < 3 then return false end
    local heights = D.sort(D.map(bands, function(ab) return ab[2] - ab[1] end), D.numcmp)
    local med = heights[rshift(#heights, 1) + 1]
    if med < 2 or med > pageH * 0.035 then return false end
    local similar = 0
    for i = 1, #heights do
        local x = heights[i]
        if x >= med * 0.4 and x <= med * 2.2 then similar = similar + 1 end
    end
    return similar / #heights >= 0.75
end

function D.splitByComponents(c, r)
    local mask, w, h = c.mask, c.w, c.h
    local rx0, ry0 = r.x0, r.y0
    local rw = r.x1 - r.x0
    local rh = r.y1 - r.y0
    local labels = D.u8(rw * rh)
    local stack = D.i32(rw * rh)
    local minArea = w * h * 0.04
    local comps = {}
    local area = D.area

    for y = 0, rh - 1 do
        for x = 0, rw - 1 do
            local li = y * rw + x
            if labels[li] ~= 0 or mask[(y + ry0) * w + x + rx0] == 0 then goto continue end
            do
                local sp = 0
                stack[sp] = li
                sp = sp + 1
                labels[li] = 1
                local bx0, bx1, by0, by1 = x, x, y, y
                while sp ~= 0 do
                    sp = sp - 1
                    local cur = stack[sp]
                    local cx = cur % rw
                    local cy = floor(cur / rw)
                    if cx < bx0 then bx0 = cx end
                    if cx > bx1 then bx1 = cx end
                    if cy < by0 then by0 = cy end
                    if cy > by1 then by1 = cy end
                    for dy = -1, 1 do
                        local ny = cy + dy
                        if ny >= 0 and ny < rh then
                            for dx = -1, 1 do
                                local nx = cx + dx
                                if nx >= 0 and nx < rw then
                                    local ni = ny * rw + nx
                                    if labels[ni] == 0 and mask[(ny + ry0) * w + nx + rx0] ~= 0 then
                                        labels[ni] = 1
                                        stack[sp] = ni
                                        sp = sp + 1
                                    end
                                end
                            end
                        end
                    end
                end
                local comp = {
                    x0 = bx0 + rx0,
                    y0 = by0 + ry0,
                    x1 = bx1 + 1 + rx0,
                    y1 = by1 + 1 + ry0,
                }
                if area(comp) >= minArea then comps[#comps + 1] = comp end
            end
            ::continue::
        end
    end

    D.sort(comps, function(a, b) return area(b) - area(a) end)
    local kept = {}
    for k = 1, #comps do
        local cp = comps[k]
        if not D.some(kept, function(kk) return D.overlap(kk, cp) > area(cp) * 0.75 end) then
            kept[#kept + 1] = cp
        end
    end
    if #kept < 2 then return nil end

    for i = 1, #kept do
        for j = i + 1, #kept do
            if D.overlap(kept[i], kept[j]) > 0.35 * math.min(area(kept[i]), area(kept[j])) then
                return nil
            end
        end
    end
    local covered = 0
    for k = 1, #kept do covered = covered + area(kept[k]) end
    if covered < area(r) * 0.7 then return nil end

    return D.readingOrder(kept, c.rtl)
end

function D.readingOrder(rects, rtl)
    local rows = {}
    local sorted = {}
    for i = 1, #rects do sorted[i] = rects[i] end
    D.sort(sorted, function(a, b) return a.y0 - b.y0 end)
    for k = 1, #sorted do
        local r = sorted[k]
        local row = rows[#rows]
        if row then
            local ov = math.min(row.y1, r.y1) - math.max(row.y0, r.y0)
            if ov > 0.5 * math.min(row.y1 - row.y0, r.y1 - r.y0) then
                row.items[#row.items + 1] = r
                row.y0 = math.min(row.y0, r.y0)
                row.y1 = math.max(row.y1, r.y1)
                goto continue
            end
        end
        rows[#rows + 1] = { y0 = r.y0, y1 = r.y1, items = { r } }
        ::continue::
    end
    local cmp = function(a, b)
        local v
        if rtl then v = b.x1 - a.x1 else v = a.x0 - b.x0 end
        if v ~= 0 and v == v then return v end
        return a.y0 - b.y0
    end
    local out = {}
    for k = 1, #rows do
        local items = D.sort(rows[k].items, cmp)
        for i = 1, #items do out[#out + 1] = items[i] end
    end
    return out
end

function D.area(r)
    return (r.x1 - r.x0) * (r.y1 - r.y0)
end

function D.overlap(a, b)
    local ow = math.min(a.x1, b.x1) - math.max(a.x0, b.x0)
    local oh = math.min(a.y1, b.y1) - math.max(a.y0, b.y0)
    if ow > 0 and oh > 0 then return ow * oh end
    return 0
end

-- ---------------------------------------------------------------------------
-- Image pipeline

function D.paperMaps(big, W, H, invert)
    if invert == nil then invert = false end
    local paperLuma = D.paperLuma
    local n = W * H
    local hi = D.u8(n)
    local hiLuma = D.u8(n)
    local ref = D.paperRef(invert and D.invertRGBA(big) or big, W, H)
    local i = 0
    if invert then
        for p = 0, n - 1 do
            local r = 255 - big[i]
            local g = 255 - big[i + 1]
            local b = 255 - big[i + 2]
            hi[p] = paperLuma(r, g, b, ref)
            hiLuma[p] = 0.299 * r + 0.587 * g + 0.114 * b
            i = i + 4
        end
    else
        for p = 0, n - 1 do
            local r = big[i]
            local g = big[i + 1]
            local b = big[i + 2]
            hi[p] = paperLuma(r, g, b, ref)
            hiLuma[p] = 0.299 * r + 0.587 * g + 0.114 * b
            i = i + 4
        end
    end
    return { hi = hi, hiLuma = hiLuma }
end

function D.gapDarkness(rects, data, w, h)
    local n = 0
    local dark = 0
    local near = D.round(math.min(w, h) * 0.06)
    local function test(x, y)
        if x < 0 or y < 0 or x >= w or y >= h then return end
        local i = (y * w + x) * 4
        n = n + 1
        -- (a non-integer index reads undefined in JS: NaN, never dark)
        if i == floor(i) and 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2] < 100 then
            dark = dark + 1
        end
    end
    for ia = 1, #rects do
        local a = rects[ia]
        for ib = 1, #rects do
            local b = rects[ib]
            if a == b then goto continue end
            do
                local sy = math.min(a.y1, b.y1) - math.max(a.y0, b.y0)
                local sx = math.min(a.x1, b.x1) - math.max(a.x0, b.x0)
                local gx = b.x0 - a.x1
                local gy = b.y0 - a.y1
                if gx >= 0 and gx <= near and sy >= math.min(a.y1 - a.y0, b.y1 - b.y0) * 0.5 then
                    local x = D.round(a.x1 + gx / 2)
                    local y = math.max(a.y0, b.y0)
                    local lim = math.min(a.y1, b.y1)
                    while y < lim do
                        test(x, y)
                        y = y + 1
                    end
                end
                if gy >= 0 and gy <= near and sx >= math.min(a.x1 - a.x0, b.x1 - b.x0) * 0.5 then
                    local y = D.round(a.y1 + gy / 2)
                    local x = math.max(a.x0, b.x0)
                    local lim = math.min(a.x1, b.x1)
                    while x < lim do
                        test(x, y)
                        x = x + 1
                    end
                end
            end
            ::continue::
        end
    end
    if n ~= 0 then return dark / n end
    return 0
end

function D.invertRGBA(data)
    local len = D.len(data)
    local out = D.u8(len)
    for i = 0, len - 1, 4 do
        out[i] = 255 - data[i]
        out[i + 1] = 255 - data[i + 1]
        out[i + 2] = 255 - data[i + 2]
        out[i + 3] = 255
    end
    return out
end

function D.negativeOf(data, big, w, h)
    local dark = D.darkFraction(data)
    if dark < D.TUNE.darkColorPage then return nil end
    local color = D.isColorful(data)
    if not color and dark < D.TUNE.darkPage then return nil end
    local inv = D.invertRGBA(data)
    local pm = D.paperMaps(big, 2 * w, 2 * h, true)
    return { data = inv, hi = pm.hi, hiLuma = pm.hiLuma, color = color }
end

function D.isColorful(data)
    local lit = 0
    local sat = 0
    for i = 0, D.len(data) - 1, 4 do
        local r = data[i]
        local g = data[i + 1]
        local b = data[i + 2]
        local mx = math.max(r, g, b)
        if mx >= 60 then
            lit = lit + 1
            if mx - math.min(r, g, b) > 40 then sat = sat + 1 end
        end
    end
    return lit > 0 and sat / lit >= 0.15
end

-- For each source line p (0-based), the destination cells that contain it:
-- cells[p + 1] is a 1-based list of 0-based destination indices.
function D.cellsOf(S, Dn)
    local cells = {}
    for p = 1, S do cells[p] = {} end
    for d = 0, Dn - 1 do
        local a = floor((d * S) / Dn)
        local b = math.max(a + 1, floor(((d + 1) * S) / Dn))
        for p = a, math.min(b, S) - 1 do
            local l = cells[p + 1]
            l[#l + 1] = d
        end
    end
    return cells
end

-- sum: u32 (W*H*3), cnt: u16 (W*H), src: RGBA bytes of `rows` source lines starting at yFrom.
function D.boxAccumulate(sum, cnt, src, sw, sh, W, H, yFrom, rows)
    if yFrom == nil then yFrom = 0 end
    if rows == nil then rows = sh end
    local rowsOf = D.cellsOf(sh, H)
    local colsOf = D.cellsOf(sw, W)
    for yy = 0, rows - 1 do
        local ys = rowsOf[yFrom + yy + 1]
        local nys = #ys
        if nys == 0 then goto nextrow end
        do
            local row = yy * sw
            local y1 = ys[1]
            for xx = 0, sw - 1 do
                local xs = colsOf[xx + 1]
                local nxs = #xs
                if nxs ~= 0 then
                    local i = (row + xx) * 4
                    local r = src[i]
                    local g = src[i + 1]
                    local b = src[i + 2]
                    if nys == 1 and nxs == 1 then
                        local c = y1 * W + xs[1]
                        local o = c * 3
                        sum[o] = sum[o] + r
                        sum[o + 1] = sum[o + 1] + g
                        sum[o + 2] = sum[o + 2] + b
                        cnt[c] = cnt[c] + 1
                    else
                        for a = 1, nys do
                            local y = ys[a]
                            for k = 1, nxs do
                                local c = y * W + xs[k]
                                local o = c * 3
                                sum[o] = sum[o] + r
                                sum[o + 1] = sum[o + 1] + g
                                sum[o + 2] = sum[o + 2] + b
                                cnt[c] = cnt[c] + 1
                            end
                        end
                    end
                end
            end
        end
        ::nextrow::
    end
end

-- RGBA (Uint8ClampedArray) image of W×H from the sums.
function D.boxFinish(sum, cnt, W, H)
    local clamp8 = D.clamp8
    local out = D.u8(W * H * 4)
    local o, q = 0, 0
    for p = 0, W * H - 1 do
        local n = cnt[p]
        if n == 0 then n = 1 end
        out[o] = clamp8(sum[q] / n)
        out[o + 1] = clamp8(sum[q + 1] / n)
        out[o + 2] = clamp8(sum[q + 2] / n)
        out[o + 3] = 255
        o = o + 4
        q = q + 3
    end
    return out
end

function D.halve(big, W, H)
    local aw = rshift(W, 1)
    local ah = rshift(H, 1)
    local out = D.u8(aw * ah * 4)
    for y = 0, ah - 1 do
        local r0 = 2 * y * W
        local r1 = r0 + W
        for x = 0, aw - 1 do
            local a = (r0 + 2 * x) * 4
            local b = (r1 + 2 * x) * 4
            local o = (y * aw + x) * 4
            out[o] = rshift(big[a] + big[a + 4] + big[b] + big[b + 4], 2)
            out[o + 1] = rshift(big[a + 1] + big[a + 5] + big[b + 1] + big[b + 5], 2)
            out[o + 2] = rshift(big[a + 2] + big[a + 6] + big[b + 2] + big[b + 6], 2)
            out[o + 3] = 255
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Balloons

function D.findBalloons(data, w, h, size, debug, paint)
    local overlap, area = D.overlap, D.area
    local COVERAGE_MIN = D.COVERAGE_MIN
    local n = w * h
    local light = D.u8(n)
    local luma = D.u8(n)
    do
        local i = 0
        for p = 0, n - 1 do
            local r = data[i]
            local g = data[i + 1]
            local b = data[i + 2]
            local l = 0.299 * r + 0.587 * g + 0.114 * b
            luma[p] = l
            if l >= 200 and math.max(r, g, b) - math.min(r, g, b) <= 50 then light[p] = 1 end
            i = i + 4
        end
    end
    local q = D.i32(n)
    local seen = D.u8(n) -- per candidate: 1 zone, 2 outside, 3 hole
    local found = {}

    local function measure(X0, Y0, X1, Y1, isZone, zoneLum)
        local zone = 0
        for y = Y0, Y1 - 1 do
            for p = y * w + X0, y * w + X1 - 1 do
                seen[p] = isZone(p) and 1 or 0
                if seen[p] ~= 0 then zone = zone + 1 end
            end
        end
        local qh = 0
        local qt = 0
        local function push(p)
            if seen[p] == 0 then
                seen[p] = 2
                q[qt] = p
                qt = qt + 1
            end
        end
        for x = X0, X1 - 1 do
            push(Y0 * w + x)
            push((Y1 - 1) * w + x)
        end
        for y = Y0, Y1 - 1 do
            push(y * w + X0)
            push(y * w + X1 - 1)
        end
        while qh < qt do
            local p = q[qh]
            qh = qh + 1
            local x = p % w
            local y = (p - x) / w
            if x > X0 then push(p - 1) end
            if x < X1 - 1 then push(p + 1) end
            if y > Y0 then push(p - w) end
            if y < Y1 - 1 then push(p + w) end
        end
        local holes = 0
        local ink = 0
        local nHoles = 0
        local biggest = 0
        local heights = {}
        local centers = {}
        local glyphs = {}
        local bigH = 0
        local bigW = 0
        for y = Y0, Y1 - 1 do
            for p0 = y * w + X0, y * w + X1 - 1 do
                if seen[p0] ~= 0 then goto continue end
                do
                    nHoles = nHoles + 1
                    local sz = 0
                    local dark = 0
                    local hh = 0
                    local ht = 0
                    local top = h
                    local bottom = 0
                    local left = w
                    local right = 0
                    seen[p0] = 3
                    q[hh] = p0
                    hh = hh + 1
                    while ht < hh do
                        local p = q[ht]
                        ht = ht + 1
                        sz = sz + 1
                        if abs(luma[p] - zoneLum) >= 80 then dark = dark + 1 end
                        local x = p % w
                        local yy = (p - x) / w
                        if yy < top then top = yy end
                        if yy > bottom then bottom = yy end
                        if x < left then left = x end
                        if x > right then right = x end
                        if x > X0 and seen[p - 1] == 0 then
                            seen[p - 1] = 3
                            q[hh] = p - 1
                            hh = hh + 1
                        end
                        if x < X1 - 1 and seen[p + 1] == 0 then
                            seen[p + 1] = 3
                            q[hh] = p + 1
                            hh = hh + 1
                        end
                        if yy > Y0 and seen[p - w] == 0 then
                            seen[p - w] = 3
                            q[hh] = p - w
                            hh = hh + 1
                        end
                        if yy < Y1 - 1 and seen[p + w] == 0 then
                            seen[p + w] = 3
                            q[hh] = p + w
                            hh = hh + 1
                        end
                    end
                    holes = holes + sz
                    ink = ink + dark
                    if sz > biggest then
                        biggest = sz
                        bigH = bottom - top + 1
                        bigW = right - left + 1
                    end
                    if sz >= 3 then
                        heights[#heights + 1] = bottom - top + 1
                        centers[#centers + 1] = (top + bottom) / 2
                        glyphs[#glyphs + 1] = {
                            sz = sz, dark = dark, top = top, bottom = bottom,
                            left = left, right = right, cy = (top + bottom) / 2,
                        }
                    end
                end
                ::continue::
            end
        end
        local sortedH = {}
        for i = 1, #heights do sortedH[i] = heights[i] end
        D.sort(sortedH, D.numcmp)
        local med = 0
        if #sortedH > 0 then med = sortedH[rshift(#sortedH, 1) + 1] end
        local alike = 0
        for i = 1, #heights do
            local v = heights[i]
            if v >= 0.5 * med and v <= 1.6 * med then alike = alike + 1 end
        end
        local cys = {}
        for i = 1, #centers do cys[i] = centers[i] end
        D.sort(cys, D.numcmp)
        local rows = {}
        for k = 1, #cys do
            local cy = cys[k]
            local row = rows[#rows]
            if row and cy - row.sum / row.n <= 0.7 * med then
                row.sum = row.sum + cy
                row.n = row.n + 1
            else
                rows[#rows + 1] = { sum = cy, n = 1 }
            end
        end
        local inRows = 0
        for k = 1, #rows do
            if rows[k].n >= 2 then inRows = inRows + rows[k].n end
        end
        local lettering = #heights >= 6
            and alike >= 0.6 * #heights
            and med >= math.max(5, size.letter * h)
            and med <= 0.25 * (Y1 - Y0)
            and nHoles <= 250
            and #rows <= 10
            and #cys >= 3 * #rows
            and inRows >= 0.7 * #cys
        local fill = (zone + holes) / ((X1 - X0) * (Y1 - Y0))
        local n3 = #glyphs
        local letter = n3 > 0 and n3 <= 2 and bigW < 1.2 * bigH and biggest >= 0.55 * bigH * bigW
        local medA = med
        do
            local byH = {}
            for i = 1, #glyphs do byH[i] = glyphs[i] end
            D.sort(byH, function(a, b) return a.bottom - a.top - (b.bottom - b.top) end)
            local total = 0
            for i = 1, #byH do total = total + byH[i].sz end
            local acc = 0
            for i = 1, #byH do
                local g = byH[i]
                acc = acc + g.sz
                if acc >= total / 2 then
                    medA = g.bottom - g.top + 1
                    break
                end
            end
        end
        D.sort(glyphs, function(a, b) return a.cy - b.cy end)
        local lines = {}
        for k = 1, #glyphs do
            local g = glyphs[k]
            local row = lines[#lines]
            if row and g.cy - row.sum / #row.glyphs <= 0.7 * medA then
                row.glyphs[#row.glyphs + 1] = g
                row.sum = row.sum + g.cy
            else
                lines[#lines + 1] = { glyphs = { g }, sum = g.cy }
            end
        end
        local blocks = {}
        for k = 1, #lines do
            local row = lines[k]
            local c = row.sum / #row.glyphs
            local b = blocks[#blocks]
            if b and c - b.last <= 2.5 * medA then
                b.rows[#b.rows + 1] = row
                b.last = c
            else
                blocks[#blocks + 1] = { rows = { row }, last = c }
            end
        end
        local function spanG(gs)
            local x0 = w
            local y0 = h
            local x1 = 0
            local y1 = 0
            for k = 1, #gs do
                local g = gs[k]
                if g.left < x0 then x0 = g.left end
                if g.right + 1 > x1 then x1 = g.right + 1 end
                if g.top < y0 then y0 = g.top end
                if g.bottom + 1 > y1 then y1 = g.bottom + 1 end
            end
            return x1 - x0, y1 - y0
        end
        local function coverage(gs)
            local sum = 0
            for k = 1, #gs do sum = sum + gs[k].right - gs[k].left + 1 end
            local bw = spanG(gs)
            return D.min(1, sum / bw)
        end
        local textBlock = D.some(blocks, function(b)
            local gs = {}
            for k = 1, #b.rows do
                local rg = b.rows[k].glyphs
                for j = 1, #rg do gs[#gs + 1] = rg[j] end
            end
            if #gs < 4 then return false end
            local ar = 0
            local dk = 0
            for k = 1, #gs do
                ar = ar + gs[k].sz
                dk = dk + gs[k].dark
            end
            if dk < 0.5 * ar then return false end
            local full = D.filter(b.rows, function(r) return #r.glyphs >= 2 end)
            if #full == 0 then return false end
            local covs = D.sort(D.map(full, function(r) return coverage(r.glyphs) end), D.numcmp)
            if covs[rshift(#covs, 1) + 1] < COVERAGE_MIN then return false end
            if #full >= 2 then
                local widths = D.sort(D.map(full, function(r) return (spanG(r.glyphs)) end),
                    function(a, c) return c - a end)
                return widths[2] >= 0.5 * widths[1]
            end
            local bw, bh = spanG(gs)
            return bw >= 0.5 * (X1 - X0) and bh >= 0.3 * (Y1 - Y0)
        end)
        local gArea = 0
        for k = 1, #glyphs do gArea = gArea + glyphs[k].sz end
        local allW, allH = spanG(glyphs)
        local dens = 0
        if allW > 0 and allH > 0 then dens = gArea / (allW * allH) end
        local loose = n3 >= 6 and not textBlock and dens < 0.17
        return {
            zone = zone,
            holes = holes,
            ink = ink,
            nHoles = nHoles,
            biggest = biggest,
            fill = fill,
            lettering = lettering,
            letter = letter,
            loose = loose,
        }
    end

    local function accept(X0, Y0, X1, Y1)
        found[#found + 1] = { x0 = X0, y0 = Y0, x1 = X1, y1 = Y1 }
        if paint then
            for y = Y0, Y1 - 1 do
                for p = y * w + X0, y * w + X1 - 1 do
                    if seen[p] ~= 2 then paint[p] = 1 end
                end
            end
        end
    end
    local function sized(ar, bw, bh, maxArea)
        return not (ar < n * size.area or bw < w * size.w or bh < h * size.h)
            and not (ar > n * maxArea or (bw > w * 0.9 and bh > h * 0.5) or (bh > h * 0.9 and bw > w * 0.5)
                or bw > 8 * bh or bh > 8 * bw)
    end

    -- 1 and 2: light zones, as they are and closed.
    local first = D.blackComponents(light, w, h)
    local rr = 3
    local grown = D.dilateBy(light, w, h, rr)
    local inv = D.u8(n)
    for p = 0, n - 1 do inv[p] = bxor(grown[p], 1) end
    local shrunk = D.dilateBy(inv, w, h, rr)
    local closed = D.u8(n)
    for p = 0, n - 1 do closed[p] = bxor(shrunk[p], 1) end
    local second = D.blackComponents(closed, w, h)
    for pass = 1, 2 do
        local strict = pass == 2
        local res = strict and second or first
        local lab, comps = res.lab, res.comps
        for k = 1, #comps do
            local c = comps[k]
            local bw = c.x1 - c.x0
            local bh = c.y1 - c.y0
            local maxA
            if strict then maxA = 0.12 else maxA = size.maxArea end
            if not sized(c.area, bw, bh, maxA) then goto continue end
            if strict and D.some(found, function(f) return overlap(f, c) ~= 0 end) then goto continue end
            do
                local cid = c.id
                local m = measure(c.x0, c.y0, c.x1, c.y1, function(p) return lab[p] == cid end, 220)
                local why = false
                if c.area < 0.28 * bw * bh then why = true end
                if m.ink < 0.008 * bw * bh or m.ink < 0.3 * m.holes then why = true end
                if size.text and m.letter then why = true end
                if size.text and m.loose then why = true end
                if strict then
                    local lit = 0
                    for y = c.y0, c.y1 - 1 do
                        for p = y * w + c.x0, y * w + c.x1 - 1 do
                            if lab[p] == cid and light[p] ~= 0 then lit = lit + 1 end
                        end
                    end
                    if lit < 0.55 * c.area then why = true end
                    if not m.lettering then why = true end
                end
                if not why then accept(c.x0, c.y0, c.x1, c.y1) end
            end
            ::continue::
        end
    end

    -- 3: colour captions, segmented at half resolution.
    local hw = rshift(w, 1)
    local hh = rshift(h, 1)
    local half = D.u8(hw * hh * 4)
    for y = 0, hh - 1 do
        for x = 0, hw - 1 do
            local a = 4 * (2 * y * w + 2 * x)
            local b = a + 4 * w
            local o = 4 * (y * hw + x)
            for k = 0, 2 do
                half[o + k] = rshift(data[a + k] + data[a + 4 + k] + data[b + k] + data[b + 4 + k], 2)
            end
        end
    end
    local DRIFT = 40
    local zones = D.flatZones(half, hw, hh, 30, DRIFT)
    for k = 1, #zones do
        local c = zones[k]
        local bw = c.x1 - c.x0
        local bh = c.y1 - c.y0
        if c.area < hw * hh * size.area or bw < hw * size.w or bh < hh * size.h then goto continue end
        if c.area > hw * hh * math.min(size.maxArea, 0.1) or bw > 8 * bh or bh > 8 * bw then goto continue end
        do
            local lum = 0.299 * c.r + 0.587 * c.g + 0.114 * c.b
            if lum >= 185 then goto continue end
            local X0 = math.max(0, 2 * c.x0 - 1)
            local Y0 = math.max(0, 2 * c.y0 - 1)
            local X1 = math.min(w, 2 * c.x1 + 1)
            local Y1 = math.min(h, 2 * c.y1 + 1)
            local box = { x0 = X0, y0 = Y0, x1 = X1, y1 = Y1 }
            if D.some(found, function(f) return overlap(f, box) > 0.5 * math.min(area(f), area(box)) end) then
                goto continue
            end
            local T = DRIFT + 12
            local cr, cg, cb = c.r, c.g, c.b
            local m = measure(X0, Y0, X1, Y1, function(p)
                local i = 4 * p
                return abs(data[i] - cr) <= T and abs(data[i + 1] - cg) <= T and abs(data[i + 2] - cb) <= T
            end, lum)
            local why = false
            if m.fill < 0.6 then why = true end
            if m.nHoles < 4 or m.biggest > size.biggest * m.holes or not m.lettering then why = true end
            if m.ink < 0.008 * (X1 - X0) * (Y1 - Y0) or m.ink < 0.4 * m.holes or m.holes > 0.6 * m.zone then
                why = true
            end
            if not why then accept(X0, Y0, X1, Y1) end
        end
        ::continue::
    end

    -- Overlapping boxes: just one.
    local changed = true
    while changed do
        changed = false
        for i = 1, #found do
            for j = i + 1, #found do
                if overlap(found[i], found[j]) ~= 0 then
                    local a = found[i]
                    local b = found[j]
                    found[i] = {
                        x0 = math.min(a.x0, b.x0), y0 = math.min(a.y0, b.y0),
                        x1 = math.max(a.x1, b.x1), y1 = math.max(a.y1, b.y1),
                    }
                    table.remove(found, j)
                    changed = true
                    goto outer
                end
            end
        end
        ::outer::
    end
    return found
end

-- Flat colour zones of an RGBA image: list of { area, x0, y0, x1, y1, r, g, b }.
function D.flatZones(data, w, h, near, drift)
    local n = w * h
    local lab = D.i32(n)
    local q = D.i32(n)
    local zones = {}
    local qt, i, mr, mg, mb, id = 0, 0, 0, 0, 0, 0
    local function tryPush(o)
        if lab[o] ~= 0 then return end
        local j = 4 * o
        if abs(data[j] - data[i]) + abs(data[j + 1] - data[i + 1]) + abs(data[j + 2] - data[i + 2]) > near then return end
        if abs(data[j] - mr) > drift or abs(data[j + 1] - mg) > drift or abs(data[j + 2] - mb) > drift then return end
        lab[o] = id
        q[qt] = o
        qt = qt + 1
    end
    for s0 = 0, n - 1 do
        if lab[s0] ~= 0 then goto continue end
        do
            id = #zones + 1
            local sr = 0
            local sg = 0
            local sb = 0
            local ar = 0
            local x0 = w
            local y0 = h
            local x1 = 0
            local y1 = 0
            local qh = 0
            qt = 0
            lab[s0] = id
            q[qt] = s0
            qt = qt + 1
            while qh < qt do
                local p = q[qh]
                qh = qh + 1
                i = 4 * p
                sr = sr + data[i]
                sg = sg + data[i + 1]
                sb = sb + data[i + 2]
                ar = ar + 1
                local x = p % w
                local y = (p - x) / w
                if x < x0 then x0 = x end
                if x > x1 then x1 = x end
                if y < y0 then y0 = y end
                if y > y1 then y1 = y end
                mr = sr / ar
                mg = sg / ar
                mb = sb / ar
                if x > 0 then tryPush(p - 1) end
                if x < w - 1 then tryPush(p + 1) end
                if p >= w then tryPush(p - w) end
                if p < n - w then tryPush(p + w) end
            end
            zones[#zones + 1] = { area = ar, x0 = x0, y0 = y0, x1 = x1 + 1, y1 = y1 + 1, r = sr / ar, g = sg / ar, b = sb / ar }
        end
        ::continue::
    end
    return zones
end

-- Returns nil or { data = RGBA copy, hi = copy or nil, balloons = list of boxes }.
function D.withoutGutterBalloons(data, w, h, hi)
    local n = w * h
    local paint = D.u8(n)
    local found = D.findBalloons(data, w, h, D.BALLOON_GUTTER, nil, paint)
    if #found == 0 then return nil end
    local light = D.u8(n)
    do
        local i = 0
        for p = 0, n - 1 do
            local r = data[i]
            local g = data[i + 1]
            local b = data[i + 2]
            if paint[p] == 0 and 0.299 * r + 0.587 * g + 0.114 * b >= 200
                and math.max(r, g, b) - math.min(r, g, b) <= 50 then
                light[p] = 1
            end
            i = i + 4
        end
    end
    local gutter = D.u8(n)
    local q = D.i32(n)
    local qh = 0
    local qt = 0
    local function push(p)
        if light[p] ~= 0 and gutter[p] == 0 then
            gutter[p] = 1
            q[qt] = p
            qt = qt + 1
        end
    end
    for x = 0, w - 1 do
        push(x)
        push((h - 1) * w + x)
    end
    for y = 0, h - 1 do
        push(y * w)
        push(y * w + w - 1)
    end
    while qh < qt do
        local p = q[qh]
        qh = qh + 1
        local x = p % w
        if x > 0 then push(p - 1) end
        if x < w - 1 then push(p + 1) end
        if p >= w then push(p - w) end
        if p < n - w then push(p + w) end
    end
    local R = math.max(2, D.round(math.min(w, h) * 0.004))
    local ring = math.max(4, 2 * R)
    local fat = D.dilateBy(paint, w, h, R)
    local balloons = {}
    local erase = D.u8(n)
    local function band(x0, y0, x1, y1, rows)
        x0 = math.max(0, x0)
        y0 = math.max(0, y0)
        x1 = math.min(w, x1)
        y1 = math.min(h, y1)
        local out = {}
        if rows then
            for y = y0, y1 - 1 do
                for p = y * w + x0, y * w + x1 - 1 do
                    if gutter[p] ~= 0 and fat[p] == 0 then
                        out[#out + 1] = y
                        break
                    end
                end
            end
        else
            for x = x0, x1 - 1 do
                for y = y0, y1 - 1 do
                    if gutter[y * w + x] ~= 0 and fat[y * w + x] == 0 then
                        out[#out + 1] = x
                        break
                    end
                end
            end
        end
        return out
    end
    local maxGutter = D.round(math.min(w, h) * 0.035)
    local tol = math.max(4, D.round(math.min(w, h) * 0.012))
    local function passes(a, b)
        if #a < 2 or #b < 2 or #a > maxGutter or #b > maxGutter then return false end
        if a[#a] - a[1] > 2 * maxGutter or b[#b] - b[1] > 2 * maxGutter then return false end
        return abs((a[1] + a[#a]) / 2 - (b[1] + b[#b]) / 2) <= tol
    end
    for k = 1, #found do
        local b = found[k]
        local o = R + ring
        local across = passes(band(b.x0 - o, b.y0, b.x0 - R, b.y1, true), band(b.x1 + R, b.y0, b.x1 + o, b.y1, true))
            or passes(band(b.x0, b.y0 - o, b.x1, b.y0 - R, false), band(b.x0, b.y1 + R, b.x1, b.y1 + o, false))
        if across then
            local box = {
                x0 = math.max(0, b.x0 - R), y0 = math.max(0, b.y0 - R),
                x1 = math.min(w, b.x1 + R), y1 = math.min(h, b.y1 + R),
            }
            balloons[#balloons + 1] = box
            for y = box.y0, box.y1 - 1 do
                for p = y * w + box.x0, y * w + box.x1 - 1 do
                    if fat[p] ~= 0 then erase[p] = 1 end
                end
            end
        end
    end
    if #balloons == 0 then return nil end
    local bg = D.estimateBackground(data, w, h)
    local pr, pg, pb
    if bg.ratio >= 0.5 then
        pr, pg, pb = bg.color[1], bg.color[2], bg.color[3]
    else
        pr, pg, pb = 255, 255, 255
    end
    local out = copyU8(data)
    local cr, cg, cb = D.clamp8(pr), D.clamp8(pg), D.clamp8(pb)
    do
        local i = 0
        for p = 0, n - 1 do
            if erase[p] ~= 0 then
                out[i] = cr
                out[i + 1] = cg
                out[i + 2] = cb
            end
            i = i + 4
        end
    end
    local hiOut = nil
    if hi and D.len(hi) == 4 * n then
        hiOut = copyU8(hi)
        local W = 2 * w
        local paper = D.round(0.299 * pr + 0.587 * pg + 0.114 * pb)
        for p = 0, n - 1 do
            if erase[p] ~= 0 then
                local x = p % w
                local y = (p - x) / w
                local i = 2 * y * W + 2 * x
                hiOut[i] = paper
                hiOut[i + 1] = paper
                hiOut[i + W] = paper
                hiOut[i + W + 1] = paper
            end
        end
    end
    return { data = out, hi = hiOut, balloons = balloons }
end

-- Mask grown by r pixels (square).
function D.dilateBy(mask, w, h, r)
    local len = D.len(mask)
    local tmp = D.u8(len)
    local out = D.u8(len)
    for y = 0, h - 1 do
        local last = -math.huge
        local o = y * w
        for x = 0, w - 1 do
            if mask[o + x] ~= 0 then last = x end
            if x - last <= r then tmp[o + x] = 1 end
        end
        last = math.huge
        for x = w - 1, 0, -1 do
            if mask[o + x] ~= 0 then last = x end
            if last - x <= r then tmp[o + x] = 1 end
        end
    end
    for x = 0, w - 1 do
        local last = -math.huge
        for y = 0, h - 1 do
            if tmp[y * w + x] ~= 0 then last = y end
            if y - last <= r then out[y * w + x] = 1 end
        end
        last = math.huge
        for y = h - 1, 0, -1 do
            if tmp[y * w + x] ~= 0 then last = y end
            if last - y <= r then out[y * w + x] = 1 end
        end
    end
    return out
end

function D.reattachBalloons(rects, balloons)
    if #rects < 2 then return rects end
    local overlap, area = D.overlap, D.area
    local out = D.map(rects, function(r) return D.assign(r) end)
    for k = 1, #balloons do
        local b = balloons[k]
        if D.some(out, function(r) return overlap(r, b) >= 0.95 * area(b) end) then goto continue end
        do
            local best = 0 -- Lua index, 0 = none
            local bestA = 0
            for i = 1, #out do
                local a = overlap(out[i], b)
                if a > bestA then
                    bestA = a
                    best = i
                end
            end
            if best == 0 then goto continue end
            local r = out[best]
            out[best] = D.assign(r, {
                x0 = math.min(r.x0, b.x0), y0 = math.min(r.y0, b.y0),
                x1 = math.max(r.x1, b.x1), y1 = math.max(r.y1, b.y1),
            })
        end
        ::continue::
    end
    return out
end

return D
