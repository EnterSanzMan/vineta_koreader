--[[--
Lua port of panels-core.js (Viñeta 3.6.1), lines 46-997:
detectPanels, framedShare, choose, mergeFlat, coverage, BLACK, BLACK_SLOPES,
INSET_SLOPES, blackComponents, blackDistance, blackPaperLevel, blackWalls,
detectInsets, largestRect, detectBlack.
]]

local ffi = require("ffi")
local bit = require("bit")
local D = require("vineta_detect_base")

-- Copy of a Uint8Array made with D.u8 (JS a.slice()). Local because D.slice in the base
-- file fails (ffi.typeof of an element value, a number).
local function copyU8(a)
    local n = D.len(a)
    local b = D.u8(n)
    if n > 0 then ffi.copy(b, a, n) end
    return b
end

-- ---------------------------------------------------------------------------
-- Constants

D.BLACK = {
    ink = 80,
    run = 0.04,
    side = 5,
    strip = 0.012,
    cut = 0.6,
    strong = 0.3,
    merge = 0.25,
    ridge = 20,
    lineAny = 0.92,
    lineThin = 0.5,
    lineMinW = 0.15,
    lineMinH = 0.1,
}
D.BLACK_SLOPES = { -0.05, -0.035, -0.02, -0.01, 0, 0.01, 0.02, 0.035, 0.05 }
D.INSET_SLOPES = { -0.02, -0.01, 0, 0.01, 0.02 }

-- ---------------------------------------------------------------------------
-- detectPanels

-- opts: { rtl, style, debug, hi, hiLuma, neg }
function D.detectPanels(data, w, h, opts)
    opts = opts or {}
    local rtl = opts.rtl
    if rtl == nil then rtl = false end
    local style = opts.style
    if style == nil then style = "auto" end
    local hi, hiLuma, neg = opts.hi, opts.hiLuma, opts.neg

    local function norm(r)
        return {
            x = r.x0 / w,
            y = r.y0 / h,
            w = (r.x1 - r.x0) / w,
            h = (r.y1 - r.y0) / h,
        }
    end
    local function half(r)
        return { x0 = r.x0 / 2, y0 = r.y0 / 2, x1 = r.x1 / 2, y1 = r.y1 / 2 }
    end
    local function bigPanel(limit)
        return function(r) return D.area(r) >= w * h * limit end
    end

    local clean = D.detectClean(data, w, h, rtl)
    local strict = #clean.rects >= 2
        and D.coverage(clean.rects, clean.bbox) >= 0.7
        and D.framedShare(clean.rects, data, w, h) >= 0.6
    local dense = nil
    if not (style == "clean" or style == "framed") then
        dense = D.detectDense(data, w, h, rtl, clean.bbox, nil, hi, strict)
    end
    local gutterBalloons = nil
    if not clean.text and style ~= "black" then
        local nb = D.withoutGutterBalloons(data, w, h, hi)
        if nb then
            gutterBalloons = nb.balloons
            local c2
            if style == "framed" then c2 = clean else c2 = D.detectClean(nb.data, w, h, rtl) end
            if not c2.text and #c2.rects > #clean.rects
                and D.coverage(c2.rects, c2.bbox or clean.bbox) >= 0.7 then
                clean = c2
            end
            if dense and style ~= "framed" then
                local d2 = D.detectDense(nb.data, w, h, rtl, clean.bbox, nil, nb.hi, strict)
                if #d2.rects > #dense.rects then dense = d2 end
            end
        end
    end
    local others = D.concat(clean.rects, dense and dense.rects or nil)
    local framed = nil
    if not (style == "clean" or style == "dense") then
        framed = D.detectFramed(data, w, h, rtl, clean.bbox, nil, hi, hiLuma, others)
    end
    if clean then clean.rects = D.mergeFlat(clean.rects, data, w, h) end
    if dense then dense.rects = D.mergeFlat(dense.rects, data, w, h) end
    if framed then framed.rects = D.mergeFlat(framed.rects, data, w, h) end

    local pick
    if style == "auto" or style == "black" then
        pick = D.choose(clean, dense, framed)
    else
        local byStyle = { dense = dense, framed = framed, clean = clean }
        pick = byStyle[style] or clean
    end
    if style == "black" then
        local black = {}
        if hiLuma then
            black = D.map(D.detectBlack(hiLuma, 2 * w, 2 * h), half)
        end
        if #black < 2 then
            return D.detectPanels(data, w, h,
                { rtl = rtl, style = "auto", debug = nil, hi = hi, hiLuma = hiLuma, neg = neg })
        end
        pick = { style = "black", rects = black }
    end
    if (style == "auto" or style == "dark") and neg and not clean.text then
        local dark
        local wholeish = #pick.rects < 2 or D.some(pick.rects, bigPanel(0.8))
        if neg.color and not wholeish then
            dark = { rects = {} }
        elseif not neg.color and style ~= "dark" then
            dark = { rects = {} }
        elseif neg.color then
            local nClean = D.detectClean(neg.data, w, h, rtl)
            local nDense = D.detectDense(neg.data, w, h, rtl, nClean.bbox, nil, neg.hi)
            local negFramed = D.detectFramed(neg.data, w, h, rtl, nClean.bbox, nil, neg.hi, neg.hiLuma,
                D.concat(nClean.rects, nDense.rects))
            nClean.rects = D.mergeFlat(nClean.rects, neg.data, w, h)
            nDense.rects = D.mergeFlat(nDense.rects, neg.data, w, h)
            negFramed.rects = D.mergeFlat(negFramed.rects, neg.data, w, h)
            dark = D.assign(D.choose(nClean, nDense, negFramed), { style = "dark" })
            dark.rects = D.filter(dark.rects, function(r)
                return r.x1 - r.x0 >= w * 0.1 and r.y1 - r.y0 >= h * 0.08
            end)
            if #dark.rects > 12
                or D.coverage(dark.rects, { x0 = 0, y0 = 0, x1 = w, y1 = h }) < 0.5
                or D.gapDarkness(dark.rects, data, w, h) < 0.6 then
                dark.rects = {}
            end
        else
            local negFramed = D.detectFramed(neg.data, w, h, rtl, nil, nil, neg.hi, neg.hiLuma, {})
            local frames = D.filter(negFramed.rects, function(r) return r.frame >= 0.6 end)
            dark = D.detectDark(data, w, h, rtl, nil, frames, hiLuma)
        end
        if #dark.rects >= 2 and (style == "dark" or not neg.color or #dark.rects > #pick.rects) then
            pick = dark
        elseif style == "dark" then
            pick = D.assign(clean, { rects = {} })
        end
    elseif style == "dark" then
        pick = D.assign(clean, { rects = {} })
    end
    if style == "auto" and hiLuma and not clean.text
        and (#pick.rects < 2 or D.some(pick.rects, bigPanel(0.8))) then
        local insets = D.map(D.detectInsets(hiLuma, 2 * w, 2 * h), half)
        if #insets >= 2 then pick = { style = "black", rects = insets } end
    end
    if gutterBalloons ~= nil and #pick.rects >= 2 and pick.style ~= "dark" then
        pick = D.assign(pick, { rects = D.reattachBalloons(pick.rects, gutterBalloons) })
    end
    local function alt(r)
        if r and #r.rects >= 2 then
            return {
                panels = D.map(D.orderRects(r.rects, false), norm),
                panelsRtl = D.map(D.orderRects(r.rects, true), norm),
            }
        end
        return nil
    end
    local alternatives = { clean = alt(clean), dense = alt(dense), framed = alt(framed) }
    if pick.style == "dark" or pick.style == "black" then alternatives[pick.style] = alt(pick) end
    local doubt = nil
    if style == "auto" and #pick.rects >= 2 then
        if D.some(pick.rects, bigPanel(0.85)) then
            doubt = "whole"
        elseif D.coverage(pick.rects, clean.bbox) < 0.5 then
            doubt = "coverage"
        end
    end
    local extra = {
        alternatives = alternatives,
        sure = not doubt,
        doubt = doubt,
        counts = {
            clean = #clean.rects,
            dense = dense and #dense.rects or 0,
            framed = framed and #framed.rects or 0,
            frames = framed and framed.framedCount or 0,
        },
    }
    if dense then extra.gutter = dense.gutter end

    local rtlRects = nil
    if #pick.rects >= 2 then rtlRects = D.map(D.orderRects(pick.rects, true), norm) end
    pick = D.assign(pick, { rects = D.orderRects(pick.rects, rtl) })

    if clean.text and #pick.rects < 2 then
        return D.assign({ kind = "text", style = "clean", panels = { D.FULL_PAGE } }, extra)
    end
    if #pick.rects >= 2 then
        return D.assign({
            kind = "comic",
            style = pick.style,
            panels = D.map(pick.rects, norm),
            panelsRtl = rtlRects,
        }, extra)
    end
    local one
    if #pick.rects == 1 then one = pick.rects[1] else one = clean.bbox end
    if one and D.area(one) < w * h * 0.8 then
        return D.assign({ kind = "single", style = pick.style, panels = { norm(one) } }, extra)
    end
    return D.assign({ kind = "single", style = pick.style, panels = { D.FULL_PAGE } }, extra)
end

-- ---------------------------------------------------------------------------
-- framedShare

function D.framedShare(rects, data, w, h)
    local function luma(x, y)
        if x < 0 or y < 0 or x >= w or y >= h then return 255 end
        local i = (y * w + x) * 4
        return 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2]
    end
    local IN = 5
    local function side(len, at)
        local best = 0
        for d = 0, IN - 1 do
            local n = 0
            local m = 0
            local k = 0
            while k < len do
                local l = at(k, d)
                if l < 100 and at(k, d + 3) > l + 60 then n = n + 1 end
                k = k + 2
                m = m + 1
            end
            if m ~= 0 and n / m > best then best = n / m end
        end
        return best
    end
    local framed = 0
    for _, r in ipairs(rects) do
        local sides = {
            side(r.x1 - r.x0, function(k, d) return luma(r.x0 + k, r.y0 + d) end),
            side(r.x1 - r.x0, function(k, d) return luma(r.x0 + k, r.y1 - 1 - d) end),
            side(r.y1 - r.y0, function(k, d) return luma(r.x0 + d, r.y0 + k) end),
            side(r.y1 - r.y0, function(k, d) return luma(r.x1 - 1 - d, r.y0 + k) end),
        }
        local cnt = 0
        for i = 1, 4 do
            if sides[i] >= 0.6 then cnt = cnt + 1 end
        end
        if cnt >= 3 then framed = framed + 1 end
    end
    if #rects ~= 0 then return framed / #rects end
    return 0
end

-- ---------------------------------------------------------------------------
-- choose

function D.choose(clean, dense, framed)
    if framed
        and framed.framedCount >= 2
        and framed.framedCount >= 0.6 * #framed.rects
        and D.coverage(framed.rects, clean.bbox) >= 0.5 then
        return framed
    end
    local c = #clean.rects >= 2 and D.coverage(clean.rects, clean.bbox) >= 0.7
    local d = #dense.rects >= 2
    if c and d then
        if #dense.rects > #clean.rects then return dense end
        return clean
    end
    if d then return dense end
    if c then return clean end
    local rects
    if #clean.rects == 1 then rects = clean.rects else rects = {} end
    return D.assign(clean, { rects = rects })
end

-- ---------------------------------------------------------------------------
-- mergeFlat

function D.mergeFlat(rects, data, w, h)
    if #rects < 2 then return rects end
    local paperLuma = D.paperLuma
    local PAPER = D.PAPER
    local ref = D.paperRef(data, w, h)
    local function flat(r)
        local edges = 0
        local paper = 0
        local n = 0
        local m = 0
        local sum = 0
        local sum2 = 0
        local yEnd = math.min(h, D.round(r.y1))
        local xStart = math.max(0, D.round(r.x0))
        local xEnd = math.min(w, D.round(r.x1)) - 1
        for y = math.max(0, D.round(r.y0)), yEnd - 1 do
            for x = xStart, xEnd - 1 do
                local i = (y * w + x) * 4
                local l = 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2]
                local l2 = 0.299 * data[i + 4] + 0.587 * data[i + 5] + 0.114 * data[i + 6]
                if math.abs(l - l2) > 30 then edges = edges + 1 end
                if paperLuma(data[i], data[i + 1], data[i + 2], ref) >= PAPER then
                    paper = paper + 1
                else
                    m = m + 1
                    sum = sum + l
                    sum2 = sum2 + l * l
                end
                n = n + 1
            end
        end
        local mean = sum / math.max(1, m)
        local sd = math.sqrt(math.max(0, sum2 / math.max(1, m) - mean * mean))
        return n > 0 and edges / n < 0.12 and paper / n >= 0.3 and sd < 22
    end
    local list = D.map(rects, function(r) return D.assign(r, { flat = flat(r) }) end)
    local nFlat = 0
    for i = 1, #list do
        if list[i].flat then nFlat = nFlat + 1 end
    end
    if nFlat < 2 then return rects end
    local changed = true
    while changed do
        changed = false
        for i = 1, #list do
            for j = i + 1, #list do
                local a = list[i]
                local b = list[j]
                if not a.flat or not b.flat then goto continue end
                do
                    local yo = math.min(a.y1, b.y1) - math.max(a.y0, b.y0)
                    local xo = math.min(a.x1, b.x1) - math.max(a.x0, b.x0)
                    local row = yo >= 0.5 * math.min(a.y1 - a.y0, b.y1 - b.y0) and -xo <= 0.06 * w
                    local col = xo >= 0.5 * math.min(a.x1 - a.x0, b.x1 - b.x0) and -yo <= 0.06 * h
                    if not row and not col then goto continue end
                    list[i] = D.assign(a, {
                        x0 = math.min(a.x0, b.x0),
                        y0 = math.min(a.y0, b.y0),
                        x1 = math.max(a.x1, b.x1),
                        y1 = math.max(a.y1, b.y1),
                        flat = true,
                    })
                    table.remove(list, j)
                    changed = true
                    goto outer
                end
                ::continue::
            end
        end
        ::outer::
    end
    return D.map(list, function(r)
        local o = D.assign(r, nil)
        o.flat = nil
        return o
    end)
end

-- ---------------------------------------------------------------------------
-- coverage

function D.coverage(rects, bbox)
    if not bbox then return 0 end
    local s = 0
    for i = 1, #rects do s = s + D.area(rects[i]) end
    return s / math.max(1, D.area(bbox))
end

-- ---------------------------------------------------------------------------
-- «marco negro»

-- 4-connected components of mask: { lab = Int32 labels (0-based), comps = list of
-- { id, x0, y0, x1, y1, area } } (comps[id] is the component with label id).
function D.blackComponents(mask, W, H)
    local n = W * H
    local lab = D.i32(n)
    local q = D.i32(n)
    local comps = {}
    for s = 0, n - 1 do
        if mask[s] == 0 or lab[s] ~= 0 then goto continue end
        do
            local id = #comps + 1
            local x0 = W
            local y0 = H
            local x1 = 0
            local y1 = 0
            local area = 0
            local qh = 0
            local qt = 0
            q[qt] = s
            qt = qt + 1
            lab[s] = id
            while qh < qt do
                local p = q[qh]
                qh = qh + 1
                local x = p % W
                local y = (p - x) / W
                area = area + 1
                if x < x0 then x0 = x end
                if x > x1 then x1 = x end
                if y < y0 then y0 = y end
                if y > y1 then y1 = y end
                if x > 0 and mask[p - 1] ~= 0 and lab[p - 1] == 0 then
                    lab[p - 1] = id; q[qt] = p - 1; qt = qt + 1
                end
                if x < W - 1 and mask[p + 1] ~= 0 and lab[p + 1] == 0 then
                    lab[p + 1] = id; q[qt] = p + 1; qt = qt + 1
                end
                if p >= W and mask[p - W] ~= 0 and lab[p - W] == 0 then
                    lab[p - W] = id; q[qt] = p - W; qt = qt + 1
                end
                if p < n - W and mask[p + W] ~= 0 and lab[p + W] == 0 then
                    lab[p + W] = id; q[qt] = p + W; qt = qt + 1
                end
            end
            comps[#comps + 1] = { id = id, x0 = x0, y0 = y0, x1 = x1 + 1, y1 = y1 + 1, area = area }
        end
        ::continue::
    end
    return { lab = lab, comps = comps }
end

function D.blackDistance(mask, W, H)
    local n = W * H
    local d = D.u16(n)
    local min = math.min
    for p = 0, n - 1 do
        if mask[p] ~= 0 then d[p] = 60000 else d[p] = 0 end
    end
    for y = 0, H - 1 do
        for x = 0, W - 1 do
            local p = y * W + x
            if d[p] ~= 0 then
                local v
                if x > 0 then v = min(d[p], d[p - 1] + 3) else v = min(d[p], 3) end
                if y > 0 then
                    v = min(v, d[p - W] + 3)
                    if x > 0 then v = min(v, d[p - W - 1] + 4) end
                    if x < W - 1 then v = min(v, d[p - W + 1] + 4) end
                else
                    v = min(v, 3)
                end
                d[p] = v
            end
        end
    end
    for y = H - 1, 0, -1 do
        for x = W - 1, 0, -1 do
            local p = y * W + x
            if d[p] ~= 0 then
                local v
                if x < W - 1 then v = min(d[p], d[p + 1] + 3) else v = min(d[p], 3) end
                if y < H - 1 then
                    v = min(v, d[p + W] + 3)
                    if x < W - 1 then v = min(v, d[p + W + 1] + 4) end
                    if x > 0 then v = min(v, d[p + W - 1] + 4) end
                else
                    v = min(v, 3)
                end
                d[p] = v
            end
        end
    end
    return d
end

function D.blackPaperLevel(L)
    local n = D.len(L)
    local hist = D.u32(256)
    for p = 0, n - 1 do
        local v = L[p]
        hist[v] = hist[v] + 1
    end
    local paper = 255
    local acc = 0
    for v = 255, 0, -1 do
        acc = acc + hist[v]
        if acc >= n * 0.1 then
            paper = v
            break
        end
    end
    return math.max(120, math.min(200, paper - 60))
end

function D.blackWalls(L, W, H, segs, relative)
    if relative == nil then relative = false end
    local n = W * H
    local DK = D.BLACK.ink
    local wall = D.u8(n)
    local minRun = D.round(W * D.BLACK.run)
    local sd = D.BLACK.side
    local function scan(horizontal)
        local A, B, sa, sb, side
        -- at(a, b) = a * sa + b * sb
        if horizontal then
            A, B, sa, sb, side = H, W, W, 1, sd * W
        else
            A, B, sa, sb, side = W, H, 1, W, sd
        end
        for a = sd, A - sd - 1 do
            local base = a * sa
            local b = 0
            while b < B do
                if L[base + b * sb] >= DK then
                    b = b + 1
                else
                    local e = b
                    local thin = 0
                    while e < B and L[base + e * sb] < DK do
                        local p = base + e * sb
                        local lit
                        if relative then lit = L[p] + 40 else lit = DK + 40 end
                        if L[p - side] >= lit or L[p + side] >= lit then thin = thin + 1 end
                        e = e + 1
                    end
                    if e - b >= minRun and thin >= 0.8 * (e - b) then
                        for k = b, e - 1 do wall[base + k * sb] = 1 end
                        if segs then segs[#segs + 1] = { horizontal = horizontal, o = a, from = b, to = e } end
                    end
                    b = e
                end
            end
        end
    end
    scan(true)
    scan(false)
    return wall
end

-- ---------------------------------------------------------------------------
-- detectInsets

function D.detectInsets(L, W, H)
    local n = W * H
    local segs = {}
    local wall = D.blackWalls(L, W, H, segs, true)
    local dim = math.min(W, H)
    local tol = math.max(4, D.round(dim * 0.012))
    local T = D.blackPaperLevel(L)
    local minW = D.round(W * 0.1)
    local minH = D.round(H * 0.08)
    local area, overlap = D.area, D.overlap

    local thick = math.max(3, D.round(dim * 0.006))
    local function lines(horizontal)
        local out = {}
        for _, s in ipairs(segs) do
            if s.horizontal == horizontal then
                local m = D.find(out, function(t)
                    return math.abs(t.o - s.o) <= thick and s.from < t.to + thick and s.to > t.from - thick
                end)
                if m then
                    m.o = (m.o * m.n + s.o) / (m.n + 1)
                    m.n = m.n + 1
                    m.from = math.min(m.from, s.from)
                    m.to = math.max(m.to, s.to)
                else
                    out[#out + 1] = { o = s.o, from = s.from, to = s.to, n = 1, edge = false }
                end
            end
        end
        local gap = D.round((horizontal and W or H) * 0.25)
        local changed = true
        while changed do
            changed = false
            local i = 1
            while i <= #out and not changed do
                local j = i + 1
                while j <= #out do
                    local a = out[i]
                    local b = out[j]
                    if math.abs(a.o - b.o) <= 2 * thick then
                        local d = math.max(a.from, b.from) - math.min(a.to, b.to)
                        if not (d > gap or d < -2 * thick) then
                            local la = a.to - a.from
                            local lb = b.to - b.from
                            a.o = (a.o * la + b.o * lb) / (la + lb)
                            a.from = math.min(a.from, b.from)
                            a.to = math.max(a.to, b.to)
                            table.remove(out, j)
                            changed = true
                            break
                        end
                    end
                    j = j + 1
                end
                i = i + 1
            end
        end
        return out
    end
    local Hs = lines(true)
    local Vs = lines(false)
    if #Hs > 120 or #Vs > 120 then return {} end
    Hs[#Hs + 1] = { o = 0, from = 0, to = W, edge = true }
    Hs[#Hs + 1] = { o = H - 1, from = 0, to = W, edge = true }
    Vs[#Vs + 1] = { o = 0, from = 0, to = H, edge = true }
    Vs[#Vs + 1] = { o = W - 1, from = 0, to = H, edge = true }

    local fatV = D.u8(n)
    local fatH = D.u8(n)
    for p = 0, n - 1 do
        if wall[p] ~= 0 then
            local x = p % W
            local y = (p - x) / W
            for d = -tol, tol do
                if y + d >= 0 and y + d < H then fatV[p + d * W] = 1 end
                if x + d >= 0 and x + d < W then fatH[p + d] = 1 end
            end
        end
    end
    local INSET_SLOPES = D.INSET_SLOPES
    local function cover(horizontal, o, from, to, want)
        local lim = (horizontal and H or W) - 1
        local mid = (from + to) / 2
        local best = 0
        local bestLit = 1
        for _, k in ipairs(INSET_SLOPES) do
            local hit = 0
            local lit = 0
            local m = 0
            local i = from
            while i < to do
                local oo = math.max(0, math.min(lim, D.round(o + k * (i - mid))))
                local p
                if horizontal then p = oo * W + i else p = i * W + oo end
                local f
                if horizontal then f = fatV[p] else f = fatH[p] end
                if f ~= 0 then
                    hit = hit + 1
                elseif L[p] >= T then
                    lit = lit + 1
                end
                i = i + 2
                m = m + 1
            end
            local c = 0
            if m ~= 0 then c = hit / m end
            if c > best then
                best = c
                if m > hit then bestLit = lit / (m - hit) else bestLit = 1 end
            end
        end
        if want then want.lit = bestLit end
        return best
    end
    local function span(a0, a1, b0, b1)
        return math.min(a1, b1) - math.max(a0, b0)
    end

    -- 2) Rectangles.
    local found = {}
    local function corner(l, a0, a1)
        return l.from <= a0 + 2 * tol or l.to >= a1 - 2 * tol
    end
    for _, Tl in ipairs(Hs) do
        for _, B in ipairs(Hs) do
            if B.o - Tl.o < minH then goto nextB end
            do
                local lo = math.min(Tl.from, B.from)
                local hi = math.max(Tl.to, B.to)
                for _, Lv in ipairs(Vs) do
                    if Lv.o < lo - tol or Lv.o > hi - minW
                        or span(Lv.from, Lv.to, Tl.o, B.o) < 0.4 * (B.o - Tl.o) then
                        goto nextL
                    end
                    for _, Rv in ipairs(Vs) do
                        if Rv.o - Lv.o < minW or Rv.o > hi + tol
                            or span(Rv.from, Rv.to, Tl.o, B.o) < 0.4 * (B.o - Tl.o) then
                            goto nextR
                        end
                        if span(Tl.from, Tl.to, Lv.o, Rv.o) < 0.4 * (Rv.o - Lv.o)
                            or span(B.from, B.to, Lv.o, Rv.o) < 0.4 * (Rv.o - Lv.o) then
                            goto nextR
                        end
                        do
                            local sides = { Tl, B, Lv, Rv }
                            local nonEdge = 0
                            for i = 1, 4 do
                                if not sides[i].edge then nonEdge = nonEdge + 1 end
                            end
                            if nonEdge < 2 then goto nextR end
                            local r = { x0 = D.round(Lv.o), y0 = D.round(Tl.o), x1 = D.round(Rv.o), y1 = D.round(B.o) }
                            local lit = { {}, {}, {}, {} }
                            local c = {
                                Tl.edge and 1 or cover(true, r.y0, r.x0, r.x1, lit[1]),
                                B.edge and 1 or cover(true, r.y1, r.x0, r.x1, lit[2]),
                                Lv.edge and 1 or cover(false, r.x0, r.y0, r.y1, lit[3]),
                                Rv.edge and 1 or cover(false, r.x1, r.y0, r.y1, lit[4]),
                            }
                            local real = {}
                            for i = 1, 4 do
                                if not sides[i].edge then real[#real + 1] = i end
                            end
                            local good = 0
                            for _, i in ipairs(real) do
                                if c[i] >= 0.8 then good = good + 1 end
                            end
                            local cmin = math.huge
                            for i = 1, 4 do
                                if c[i] < cmin then cmin = c[i] end
                            end
                            if good < 2 or #real - good > 1 or cmin < 0.4 then goto nextR end
                            local along = { r.x0, r.x0, r.y0, r.y0 }
                            local untl = { r.x1, r.x1, r.y1, r.y1 }
                            for i = 1, 4 do
                                if c[i] < 0.8 and lit[i].lit < 0.7 and not corner(sides[i], along[i], untl[i]) then
                                    goto nextR
                                end
                            end
                            local t = 0
                            for _, i in ipairs(real) do t = t + c[i] end
                            found[#found + 1] = D.assign(r, { good = good, score = t / #real })
                        end
                        ::nextR::
                    end
                    ::nextL::
                end
            end
            ::nextB::
        end
    end
    D.sort(found, function(a, b)
        local d = b.good - a.good
        if d ~= 0 then return d end
        d = b.score - a.score
        if d ~= 0 and d == d then return d end
        return area(b) - area(a)
    end)

    -- 3) Twins.
    local function clearBand(horizontal, o, from, to)
        local hit = 0
        local m = 0
        local i = from
        while i < to do
            if horizontal then hit = hit + wall[o * W + i] else hit = hit + wall[i * W + o] end
            i = i + 2
            m = m + 1
        end
        return m == 0 or hit < 0.5 * m
    end
    local maxGap = D.round(dim * 0.03)
    local function open(horizontal, mid, b)
        local bb = math.max(0, math.min((horizontal and W or H) - 1, b))
        local f
        if horizontal then f = fatH[mid * W + bb] else f = fatV[bb * W + mid] end
        return f == 0
    end
    local function twin(r)
        for _, horizontal in ipairs({ true, false }) do
            local list, a0, a1, b0, b1
            if horizontal then
                list, a0, a1, b0, b1 = Hs, r.y0, r.y1, r.x0, r.x1
            else
                list, a0, a1, b0, b1 = Vs, r.x0, r.x1, r.y0, r.y1
            end
            local function across(l)
                return not l.edge and span(l.from, l.to, b0, b1) >= 0.5 * (b1 - b0)
            end
            for _, l1 in ipairs(list) do
                if l1.o <= a0 + tol or l1.o >= a1 - tol or not across(l1) then goto nextL1 end
                if span(l1.from, l1.to, b0, b1) >= 0.85 * (b1 - b0)
                    and cover(horizontal, D.round(l1.o), b0, b1) >= 0.9
                    and math.min(l1.o - a0, a1 - l1.o) >= (horizontal and minH or minW) then
                    return true
                end
                for _, l2 in ipairs(list) do
                    local d = math.abs(l2.o - l1.o)
                    if l2 == l1 or d < 3 or d > maxGap or l2.o < a0 - tol or l2.o > a1 + tol or not across(l2) then
                        goto nextL2
                    end
                    do
                        local from = math.max(b0, l1.from, l2.from)
                        local to = math.min(b1, l1.to, l2.to)
                        local mid = D.round((l1.o + l2.o) / 2)
                        if clearBand(horizontal, mid, from, to)
                            and (open(horizontal, mid, b0) or open(horizontal, mid, b1)) then
                            return true
                        end
                    end
                    ::nextL2::
                end
                ::nextL1::
            end
        end
        return false
    end
    local kept = {}
    for _, r in ipairs(found) do
        if not twin(r) then
            if not D.some(kept, function(k) return overlap(k, r) >= 0.8 * math.max(area(k), area(r)) end) then
                kept[#kept + 1] = r
            end
        end
    end
    local function drawn(r)
        local ink = 0
        local edges = 0
        local m = 0
        local y = r.y0
        while y < r.y1 do
            local x = r.x0
            while x < r.x1 - 2 do
                local p = y * W + x
                if L[p] < T then ink = ink + 1 end
                if math.abs(L[p] - L[p + 2]) > 16 then edges = edges + 1 end
                x = x + 2
                m = m + 1
            end
            y = y + 2
        end
        return ink >= 0.4 * m and edges >= 0.08 * m
    end
    local insets = {}
    for _, r in ipairs(kept) do
        if drawn(r) and not D.some(insets, function(k) return overlap(k, r) > 0.2 * math.min(area(k), area(r)) end) then
            insets[#insets + 1] = r
        end
    end
    if #insets < 2 then return {} end

    -- 4) The remaining background.
    local free = D.fill(D.u8(n), 1)
    for _, r in ipairs(insets) do
        for y = math.max(0, r.y0 - tol), math.min(H, r.y1 + tol) - 1 do
            D.fill(free, 0, y * W + math.max(0, r.x0 - tol), y * W + math.min(W, r.x1 + tol))
        end
    end
    local bc = D.blackComponents(free, W, H)
    local lab, comps = bc.lab, bc.comps
    local rest = {}
    for _, c in ipairs(comps) do
        if c.area >= n * 0.08 then
            for _ = 0, 3 do
                local r = D.largestRect(lab, c.id, W, H)
                if not r or r.x1 - r.x0 < minW or r.y1 - r.y0 < minH or area(r) < n * 0.06 then break end
                if drawn(r) then rest[#rest + 1] = r end
                for y = r.y0, r.y1 - 1 do D.fill(lab, 0, y * W + r.x0, y * W + r.x1) end
            end
        end
    end
    return D.map(D.concat(insets, rest), function(r)
        return { x0 = r.x0, y0 = r.y0, x1 = r.x1, y1 = r.y1 }
    end)
end

function D.largestRect(lab, id, W, H)
    local height = D.i32(W)
    local stack = D.i32(W + 1)
    local best = nil
    local bestArea = 0
    for y = 0, H - 1 do
        local row = y * W
        for x = 0, W - 1 do
            if lab[row + x] == id then height[x] = height[x] + 1 else height[x] = 0 end
        end
        local top = 0
        for x = 0, W do
            local hx = 0
            if x < W then hx = height[x] end
            while top > 0 and height[stack[top - 1]] >= hx do
                top = top - 1
                local hh = height[stack[top]]
                local x0 = 0
                if top > 0 then x0 = stack[top - 1] + 1 end
                local a = hh * (x - x0)
                if a > bestArea then
                    bestArea = a
                    best = { x0 = x0, y0 = y - hh + 1, x1 = x, y1 = y + 1 }
                end
            end
            stack[top] = x
            top = top + 1
        end
    end
    return best
end

-- ---------------------------------------------------------------------------
-- detectBlack

function D.detectBlack(L, W, H)
    local n = W * H
    local T = D.blackPaperLevel(L)
    local BLACK = D.BLACK
    local DK = BLACK.ink
    local area = D.area

    -- 1. Walls.
    local wall = D.blackWalls(L, W, H)
    local block = copyU8(wall)
    for p = 0, n - 1 do
        if wall[p] ~= 0 then
            local x = p % W
            if x > 0 then block[p - 1] = 1 end
            if x < W - 1 then block[p + 1] = 1 end
            if p >= W then block[p - W] = 1 end
            if p < n - W then block[p + W] = 1 end
        end
    end

    -- 2. Paper: flood fill from the page border.
    local out = D.u8(n)
    local q = D.i32(n)
    local qh = 0
    local qt = 0
    local function push(p)
        if out[p] == 0 and L[p] >= T and block[p] == 0 then
            out[p] = 1
            q[qt] = p
            qt = qt + 1
        end
    end
    for x = 0, W - 1 do
        push(x)
        push((H - 1) * W + x)
    end
    for y = 0, H - 1 do
        push(y * W)
        push(y * W + W - 1)
    end
    while qh < qt do
        local p = q[qh]
        qh = qh + 1
        local x = p % W
        if x > 0 then push(p - 1) end
        if x < W - 1 then push(p + 1) end
        if p >= W then push(p - W) end
        if p < n - W then push(p + W) end
    end
    local lightIn = D.u8(n)
    for p = 0, n - 1 do
        if out[p] == 0 and block[p] == 0 and L[p] >= T then lightIn[p] = 1 else lightIn[p] = 0 end
    end
    local dist = D.blackDistance(lightIn, W, H)
    local lc = D.blackComponents(lightIn, W, H)
    local lLab, lComps = lc.lab, lc.comps
    local maxD = D.u16(#lComps + 1)
    for p = 0, n - 1 do
        local l = lLab[p]
        if l ~= 0 and dist[p] > maxD[l] then maxD[l] = dist[p] end
    end
    local strip = D.u8(#lComps + 1)
    local strips = 0
    for _, c in ipairs(lComps) do
        if maxD[c.id] <= BLACK.strip * W * 3
            and math.max(c.x1 - c.x0, c.y1 - c.y0) >= 0.06 * math.max(W, H) then
            strip[c.id] = 1
            strips = strips + 1
        end
    end
    if strips ~= 0 then
        for p = 0, n - 1 do
            if strip[lLab[p]] ~= 0 then out[p] = 1 end
        end
    end

    -- 3. What is enclosed: the panels.
    local inside = D.u8(n)
    for p = 0, n - 1 do
        if out[p] == 0 and block[p] == 0 then inside[p] = 1 else inside[p] = 0 end
    end
    local ic = D.blackComponents(inside, W, H)
    local lab, comps = ic.lab, ic.comps
    local lightCount = D.u32(#comps + 1)
    for p = 0, n - 1 do
        local l = lab[p]
        if l ~= 0 and L[p] >= T then lightCount[l] = lightCount[l] + 1 end
    end
    local function sizeable(c)
        return c.x1 - c.x0 >= W * 0.08 and c.y1 - c.y0 >= H * 0.05 and c.area >= n * 0.008
    end
    local sep = D.u8(n)
    for p = 0, n - 1 do
        if out[p] ~= 0 or block[p] ~= 0 then
            sep[p] = 2
        elseif L[p] < DK then
            sep[p] = 1
        else
            sep[p] = 0
        end
    end
    local ridgeH = D.u8(n)
    local ridgeV = D.u8(n)
    local RIDGE = BLACK.ridge
    local min = math.min
    for y = 4, H - 5 do
        for x = 4, W - 5 do
            local p = y * W + x
            if min(L[p - W], L[p], L[p + W]) + RIDGE < min(L[p - 4 * W], L[p + 4 * W]) then ridgeH[p] = 1 end
            if min(L[p - 1], L[p], L[p + 1]) + RIDGE < min(L[p - 4], L[p + 4]) then ridgeV[p] = 1 end
        end
    end
    local thickH = copyU8(ridgeH)
    local thickV = copyU8(ridgeV)
    for p = W, n - W - 1 do
        if ridgeH[p - W] ~= 0 or ridgeH[p + W] ~= 0 then thickH[p] = 1 end
        if ridgeV[p - 1] ~= 0 or ridgeV[p + 1] ~= 0 then thickV[p] = 1 end
    end
    local BLACK_SLOPES = D.BLACK_SLOPES
    local split
    split = function(pixels, depth)
        local x0 = W
        local y0 = H
        local x1 = 0
        local y1 = 0
        for i = 1, #pixels do
            local p = pixels[i]
            local x = p % W
            local y = (p - x) / W
            if x < x0 then x0 = x end
            if x > x1 then x1 = x end
            if y < y0 then y0 = y end
            if y > y1 then y1 = y end
        end
        local piece = { x0 = x0, y0 = y0, x1 = x1 + 1, y1 = y1 + 1, area = #pixels }
        if depth >= 6 then return { piece } end
        local best = nil
        for _, horizontal in ipairs({ true, false }) do
            local A0, A1, B0, B1, lim, minPart, minLine, ridge
            if horizontal then
                A0, A1, B0, B1, lim = piece.y0, piece.y1, piece.x0, piece.x1, H
                minPart = H * 0.05
                minLine = H * BLACK.lineMinH
                ridge = thickH
            else
                A0, A1, B0, B1, lim = piece.x0, piece.x1, piece.y0, piece.y1, W
                minPart = W * 0.08
                minLine = W * BLACK.lineMinW
                ridge = thickV
            end
            local mid = (B0 + B1) / 2
            for _, k in ipairs(BLACK_SLOPES) do
                local a = A0 + minPart
                while a < A1 - minPart do
                    local hit = 0
                    local strong = 0
                    local line = 0
                    local any = 0
                    local m = 0
                    local b = B0
                    while b < B1 do
                        local c = D.round(a + k * (b - mid))
                        if not (c < 0 or c >= lim) then
                            local p
                            if horizontal then p = c * W + b else p = b * W + c end
                            local v = sep[p]
                            hit = hit + v
                            if v == 2 then strong = strong + 1 end
                            if v == 2 or ridge[p] ~= 0 then line = line + 1 end
                            if v ~= 0 or ridge[p] ~= 0 then any = any + 1 end
                        end
                        b = b + 2
                        m = m + 1
                    end
                    local frac = hit / (2 * m)
                    local normal = frac >= BLACK.cut and strong >= BLACK.strong * m
                    local thin = not normal
                        and any >= BLACK.lineAny * m
                        and line >= BLACK.lineThin * m
                        and a - A0 >= minLine
                        and A1 - a >= minLine
                    local score = frac + (any + line) / (4 * m)
                    if normal and (not best or not best.normal or frac > best.frac) then
                        best = { horizontal = horizontal, k = k, a = a, mid = mid, frac = frac, normal = normal }
                    elseif thin and (not best or (not best.normal and score > best.score)) then
                        best = { horizontal = horizontal, k = k, a = a, mid = mid, frac = frac, score = score, normal = false }
                    end
                    a = a + 2
                end
            end
        end
        if not best then return { piece } end
        local A = {}
        local B = {}
        local bh, ba, bk, bm = best.horizontal, best.a, best.k, best.mid
        for i = 1, #pixels do
            local p = pixels[i]
            local x = p % W
            local y = (p - x) / W
            local s
            if bh then s = y - (ba + bk * (x - bm)) else s = x - (ba + bk * (y - bm)) end
            if s < 0 then A[#A + 1] = p else B[#B + 1] = p end
        end
        if #A < n * 0.008 or #B < n * 0.008 then return { piece } end
        return D.concat(split(A, depth + 1), split(B, depth + 1))
    end
    -- Map id → pixel list, in the order of comps (JS Map insertion order).
    local order = {}
    local pixelsOf = {}
    for _, c in ipairs(comps) do
        if sizeable(c) and lightCount[c.id] < 0.85 * c.area then
            local list = {}
            order[#order + 1] = list
            pixelsOf[c.id] = list
        end
    end
    for p = 0, n - 1 do
        local list = pixelsOf[lab[p]]
        if list then list[#list + 1] = p end
    end
    local found = {}
    for _, list in ipairs(order) do
        local parts = split(list, 0)
        for i = 1, #parts do found[#found + 1] = parts[i] end
    end
    found = D.filter(found, sizeable)
    local changed = true
    while changed do
        changed = false
        for i = 1, #found do
            for j = i + 1, #found do
                local a = found[i]
                local b = found[j]
                local ow = math.min(a.x1, b.x1) - math.max(a.x0, b.x0)
                local oh = math.min(a.y1, b.y1) - math.max(a.y0, b.y0)
                if ow <= 0 or oh <= 0 then goto continue end
                if ow * oh < BLACK.merge * math.min(area(a), area(b)) then goto continue end
                found[i] = {
                    x0 = math.min(a.x0, b.x0),
                    y0 = math.min(a.y0, b.y0),
                    x1 = math.max(a.x1, b.x1),
                    y1 = math.max(a.y1, b.y1),
                    area = a.area + b.area,
                }
                table.remove(found, j)
                changed = true
                goto outer
                ::continue::
            end
        end
        ::outer::
    end
    return D.map(found, function(r)
        return { x0 = r.x0, y0 = r.y0, x1 = r.x1, y1 = r.y1 }
    end)
end

return D
