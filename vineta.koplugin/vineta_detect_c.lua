--[[--
Lua port of panels-core.js (Viñeta 3.6.1), lines 1812-2981:
paperLuma … paperEdges (paper maps, straight edges, guillotine of the dense style and
the «framed» style). See docs/detector-lua.md for the conventions.
]]

local ffi = require("ffi")
local bit = require("bit")
local D = require("vineta_detect_base")

local _ = ffi, bit

-- ---------------------------------------------------------------------------
-- Paper

-- `ref`: nil or the list {r, g, b} returned by D.paperRef (1-based).
function D.paperLuma(r, g, b, ref)
    local near = ref ~= nil
        and math.abs(r - ref[1]) <= 45
        and math.abs(g - ref[2]) <= 45
        and math.abs(b - ref[3]) <= 45
    if near or math.max(r, g, b) - math.min(r, g, b) <= 28 then
        return 0.299 * r + 0.587 * g + 0.114 * b
    end
    return 0
end

-- Returns bg.color of D.estimateBackground (a 1-based list {r, g, b}) or nil.
function D.paperRef(data, w, h)
    local bg = D.estimateBackground(data, w, h)
    local c = bg.color
    local luma = 0.299 * c[1] + 0.587 * c[2] + 0.114 * c[3]
    if bg.ratio >= 0.5 and luma >= 150 then return c end
    return nil
end

function D.paperLevel(luma, cap, drop)
    if cap == nil then cap = D.TUNE.paperCap end
    if drop == nil then drop = D.TUNE.paperDrop end
    local hist = D.u32(256)
    local len = D.len(luma)
    for p = 0, len - 1 do
        local v = luma[p]
        hist[v] = hist[v] + 1
    end
    local best = -1
    local bestN = 0
    for v = 160, 255 do
        if hist[v] > bestN then
            bestN = hist[v]
            best = v
        end
    end
    if best < 180 or bestN < len * 0.002 then return cap end
    return math.min(cap, best - drop)
end

-- ---------------------------------------------------------------------------
-- Dense style: straight edges, walls, guillotine

function D.straightEdges(paper, w, h, horizontal, minLen, maxGap, walls, gaps, segs)
    local outer = horizontal and h or w
    local inner = horizontal and w or h
    local step = horizontal and 1 or w
    local jump = horizontal and w or 1
    local n = w * h

    for _, side in ipairs({ -1, 1 }) do
        local E = D.u8(n)
        for o = 0, outer - 1 do
            local oo = o + side
            if oo >= 0 and oo < outer then
                local p = o * jump
                local q = oo * jump
                for _ = 0, inner - 1 do
                    if paper[p] == 1 and paper[q] == 0 then E[p] = 1 end
                    p = p + step
                    q = q + step
                end
            end
        end
        for o = 0, outer - 1 do
            local base = o * jump
            local hasPrev = o > 0
            local hasNext = o < outer - 1
            local run = 0
            local missed = 0
            local startI = -1
            for i = 0, inner do
                local on = false
                if i < inner then
                    local p = base + i * step
                    on = E[p] == 1
                        or (hasPrev and E[p - jump] == 1)
                        or (hasNext and E[p + jump] == 1)
                end
                if on then
                    if startI < 0 then startI = i end
                    run = run + 1
                    missed = 0
                elseif startI >= 0 and missed < 4 and i < inner then
                    missed = missed + 1
                else
                    if run >= minLen then
                        local e = i - missed
                        for k = startI, e - 1 do walls[base + k * step] = 1 end
                        segs[#segs + 1] = { o = o, from = startI, to = e, horizontal = horizontal }
                        for k = startI, e - 1, 4 do
                            local d = 1
                            local oo = o - side
                            while d <= 2 * maxGap
                                and oo >= 0
                                and oo < outer
                                and paper[oo * jump + k * step] ~= 0 do
                                d = d + 1
                                oo = oo - side
                            end
                            if d <= 2 * maxGap then gaps[#gaps + 1] = d end
                        end
                    end
                    run = 0
                    missed = 0
                    startI = -1
                end
            end
        end
    end
end

function D.extendWalls(segs, walls, paper, w, h, r, maxExt, maxEdge, maxPaper)
    for _, seg in ipairs(segs) do
        local o, horizontal = seg.o, seg.horizontal
        local at
        if horizontal then
            at = function(oo, i) return oo * w + i end
        else
            at = function(oo, i) return i * w + oo end
        end
        local outer = horizontal and h or w
        local lo = horizontal and r.x0 or r.y0
        local hi = horizontal and r.x1 or r.y1
        local function wallNear(i)
            return walls[at(o, i)] ~= 0
                or (o > 0 and walls[at(o - 1, i)] ~= 0)
                or (o < outer - 1 and walls[at(o + 1, i)] ~= 0)
        end
        local function paperNear(i)
            return paper[at(o, i)] ~= 0
                or (o > 0 and paper[at(o - 1, i)] ~= 0)
                or (o < outer - 1 and paper[at(o + 1, i)] ~= 0)
        end
        for _, dir in ipairs({ -1, 1 }) do
            local i
            if dir < 0 then i = seg.from - 1 else i = seg.to end
            local path = {}
            local np = 0
            local hit = false
            local onPaper = true
            local gap = 0
            while np < maxPaper do
                if i < lo or i >= hi then
                    hit = onPaper or np < maxEdge
                    break
                end
                if wallNear(i) and (onPaper or np < maxExt) then
                    hit = true
                    break
                end
                if paperNear(i) then gap = 0 else gap = gap + 1 end
                if gap > 3 then onPaper = false end
                if not onPaper and np >= maxEdge then break end
                np = np + 1
                path[np] = i
                i = i + dir
            end
            if hit and np > 0 then
                for k = 1, np do walls[at(o, path[k])] = 1 end
                if dir < 0 then seg.from = path[np] else seg.to = path[np] + 1 end
            end
        end
    end
end

function D.mergeCollinear(segs, tol, gap, paperBetween)
    local list = D.map(segs, function(s)
        return { o = s.o, from = s.from, to = s.to, n = 1, parts = { { s.from, s.to } } }
    end)
    D.sort(list, function(a, b)
        local d = a.o - b.o
        if d ~= 0 then return d end
        return a.from - b.from
    end)
    local changed = true
    while changed do
        changed = false
        for i = 1, #list do
            for j = i + 1, #list do
                local a = list[i]
                local b = list[j]
                if math.abs(a.o - b.o) > tol then goto continue end
                do
                    local overlapLen = math.min(a.to, b.to) - math.max(a.from, b.from)
                    if math.abs(a.o - b.o) > 3
                        and overlapLen > math.max(8, 0.1 * math.min(a.to - a.from, b.to - b.from)) then
                        goto continue
                    end
                    local hole = -overlapLen
                    if hole > gap then
                        local o = D.round((a.o + b.o) / 2)
                        if not paperBetween
                            or paperBetween(o, math.min(a.to, b.to), math.max(a.from, b.from)) < 0.85 then
                            goto continue
                        end
                    end
                    list[i] = {
                        o = (a.o * a.n + b.o * b.n) / (a.n + b.n),
                        from = math.min(a.from, b.from),
                        to = math.max(a.to, b.to),
                        n = a.n + b.n,
                        parts = D.coalesce(D.concat(a.parts, b.parts)),
                    }
                    table.remove(list, j)
                    changed = true
                    goto break_outer
                end
                ::continue::
            end
        end
        ::break_outer::
    end
    return D.map(list, function(s)
        return { o = D.round(s.o), from = s.from, to = s.to, parts = s.parts }
    end)
end

-- parts: list of {a, b} (1-based pairs).
function D.coalesce(parts)
    local sorted = D.concat(parts)
    D.sort(sorted, function(p, q) return p[1] - q[1] end)
    local out = {}
    for _, pr in ipairs(sorted) do
        local a, b = pr[1], pr[2]
        local last = out[#out]
        if last and a <= last[2] then
            last[2] = math.max(last[2], b)
        else
            out[#out + 1] = { a, b }
        end
    end
    return out
end

function D.covered(l, a, b)
    local total = 0
    for _, pr in ipairs(l.parts or { { l.from, l.to } }) do
        local x0 = math.max(a, pr[1])
        local x1 = math.min(b, pr[2])
        if x1 > x0 then total = total + (x1 - x0) end
    end
    return total / math.max(1, b - a)
end

function D.guillotine(r, ctx, depth, out)
    if depth < 12 then
        local cut = D.bestCut(r, ctx, true) or D.bestCut(r, ctx, false)
        if cut then
            D.guillotine(cut[1], ctx, depth + 1, out)
            D.guillotine(cut[2], ctx, depth + 1, out)
            return
        end
    end
    out[#out + 1] = r
end

function D.bestCut(r, ctx, horizontal)
    local segs, perp, lo, hi, spanLo, spanHi
    if horizontal then
        segs, perp = ctx.hSegs, ctx.vSegs
        lo, hi = r.y0, r.y1
        spanLo, spanHi = r.x0, r.x1
    else
        segs, perp = ctx.vSegs, ctx.hSegs
        lo, hi = r.x0, r.x1
        spanLo, spanHi = r.y0, r.y1
    end
    local span = spanHi - spanLo
    local near = ctx.near
    local function anchored(s, e)
        if math.abs(e - spanLo) <= near or math.abs(e - spanHi) <= near then return true end
        for _, q in ipairs(perp) do
            if math.abs(q.o - e) <= near and q.from - near <= s.o and q.to + near >= s.o then
                return true
            end
        end
        return false
    end

    local paper, maxGap = ctx.paper, ctx.maxGap
    local cw = ctx.w
    local outerN = horizontal and ctx.h or ctx.w
    local candidates = {}
    for _, s in ipairs(segs) do
        if s.o <= lo + 2 or s.o >= hi - 2 then goto continue end
        do
            local cov = (math.min(s.to, spanHi) - math.max(s.from, spanLo)) / span
            if cov <= 0 then goto continue end
            local anchors = (anchored(s, s.from) and 1 or 0) + (anchored(s, s.to) and 1 or 0)
            local from = math.max(s.from, spanLo)
            local to = math.min(s.to, spanHi)
            local prof = {}
            for d = -maxGap, maxGap do
                local oo = s.o + d
                if oo < 0 or oo >= outerN then
                    prof[#prof + 1] = -1
                else
                    local hits = 0
                    local m = 0
                    if horizontal then
                        for i = from, to - 1, 2 do
                            if paper[oo * cw + i] ~= 0 then hits = hits + 1 end
                            m = m + 1
                        end
                    else
                        for i = from, to - 1, 2 do
                            if paper[i * cw + oo] ~= 0 then hits = hits + 1 end
                            m = m + 1
                        end
                    end
                    prof[#prof + 1] = (m ~= 0) and hits / m or 0
                end
            end
            -- `at` is a Lua index into prof (0 = none, JS -1).
            local peak = 0
            local at = 0
            for k = 1, #prof do
                if prof[k] > peak then
                    peak = prof[k]
                    at = k
                end
            end
            local leftMin = 1
            local rightMin = 1
            for k = 1, at - 1 do
                if prof[k] >= 0 and prof[k] < leftMin then leftMin = prof[k] end
            end
            for k = at + 1, #prof do
                if prof[k] >= 0 and prof[k] < rightMin then rightMin = prof[k] end
            end
            local real = not ctx.strict or (peak >= 0.85 and leftMin <= 0.35 and rightMin <= 0.35)
            local bare = leftMin > 0.35 and rightMin > 0.35
            local ok = real
                and (cov >= 0.9 or (cov >= 0.7 and anchors >= 1) or (cov >= 0.6 and anchors == 2))
            if ok then candidates[#candidates + 1] = { s = s, cov = cov, bare = bare } end
        end
        ::continue::
    end
    D.sort(candidates, function(a, b) return b.cov - a.cov end)
    for _, cand in ipairs(candidates) do
        local s = cand.s
        local pieces
        if horizontal then
            pieces = {
                { x0 = r.x0, y0 = r.y0, x1 = r.x1, y1 = s.o },
                { x0 = r.x0, y0 = s.o, x1 = r.x1, y1 = r.y1 },
            }
        else
            pieces = {
                { x0 = r.x0, y0 = r.y0, x1 = s.o, y1 = r.y1 },
                { x0 = s.o, y0 = r.y0, x1 = r.x1, y1 = r.y1 },
            }
        end
        local ok1 = D.pieceOk(pieces[1], ctx, horizontal)
        local ok2 = D.pieceOk(pieces[2], ctx, horizontal)
        if not (cand.bare and not D.isEmptyPiece(pieces[1], ctx) and not D.isEmptyPiece(pieces[2], ctx)) then
            if ok1 and ok2 then return pieces end
        end
    end
    return nil
end

function D.isEmptyPiece(p, ctx)
    local paper, w = ctx.paper, ctx.w
    local ink = 0
    for y = p.y0, p.y1 - 1 do
        for x = p.x0, p.x1 - 1 do
            if paper[y * w + x] == 0 then ink = ink + 1 end
        end
    end
    return ink < (p.x1 - p.x0) * (p.y1 - p.y0) * 0.15
end

function D.pieceOk(p, ctx, horizontal)
    local paper, w = ctx.paper, ctx.w
    local pw = p.x1 - p.x0
    local ph = p.y1 - p.y0
    local colInk = D.u32(pw)
    local rowInk = D.u32(ph)
    local ink = 0
    for y = p.y0, p.y1 - 1 do
        for x = p.x0, p.x1 - 1 do
            if paper[y * w + x] == 0 then
                ink = ink + 1
                colInk[x - p.x0] = colInk[x - p.x0] + 1
                rowInk[y - p.y0] = rowInk[y - p.y0] + 1
            end
        end
    end
    if ink < pw * ph * 0.15 then return true end
    local thick = horizontal and ph or pw
    local cols = 0
    for i = 0, D.len(colInk) - 1 do
        if colInk[i] >= ph * 0.1 then cols = cols + 1 end
    end
    local rows = 0
    for i = 0, D.len(rowInk) - 1 do
        if rowInk[i] >= pw * 0.1 then rows = rows + 1 end
    end
    local caption = horizontal and thick < ctx.captionMax and ink >= 0.8 * pw * ph
    local atEdge = p.x0 <= 1 or p.y0 <= 1 or p.x1 >= ctx.w - 1 or p.y1 >= ctx.h - 1
    local bleed = atEdge and thick < ctx.captionMax and ink >= 0.9 * pw * ph
    return thick >= ctx.minPiece
        and not caption
        and not bleed
        and cols >= 0.6 * pw
        and rows >= 0.6 * ph
end

function D.shrinkToInk(paper, w, r)
    local x0 = r.x1
    local y0 = r.y1
    local x1 = r.x0
    local y1 = r.y0
    local ink = 0
    for y = r.y0, r.y1 - 1 do
        for x = r.x0, r.x1 - 1 do
            if paper[y * w + x] == 0 then
                ink = ink + 1
                if x < x0 then x0 = x end
                if x > x1 then x1 = x end
                if y < y0 then y0 = y end
                if y > y1 then y1 = y end
            end
        end
    end
    if ink < D.area(r) * 0.15 then return nil end
    return { x0 = x0, y0 = y0, x1 = x1 + 1, y1 = y1 + 1 }
end

function D.dilate(mask, w, h)
    local out = D.slice(mask, 0)
    for y = 0, h - 1 do
        for x = 0, w - 1 do
            local i = y * w + x
            if mask[i] == 0 then
                if (x > 0 and mask[i - 1] ~= 0)
                    or (x < w - 1 and mask[i + 1] ~= 0)
                    or (y > 0 and mask[i - w] ~= 0)
                    or (y < h - 1 and mask[i + w] ~= 0) then
                    out[i] = 1
                end
            end
        end
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Framed style

function D.detectFramed(data, w, h, rtl, bbox, debug, hi, hiLuma, cleanRects)
    if cleanRects == nil then cleanRects = {} end
    if hi and hiLuma and D.len(hi) == 4 * w * h and D.len(hiLuma) == 4 * w * h then
        local function dbl(q)
            return { x0 = 2 * q.x0, y0 = 2 * q.y0, x1 = 2 * q.x1, y1 = 2 * q.y1 }
        end
        local big = nil
        if bbox then big = dbl(bbox) end
        local r = D.detectFramedAt(hiLuma, hi, 2 * w, 2 * h, rtl, big, nil,
            D.map(cleanRects, function(q) return dbl(q) end))
        local function half(q)
            return D.assign(q, {
                x0 = D.round(q.x0 / 2),
                y0 = D.round(q.y0 / 2),
                x1 = D.round(q.x1 / 2),
                y1 = D.round(q.y1 / 2),
            })
        end
        r.rects = D.map(r.rects, function(q) return half(q) end)
        r.bbox = half(r.bbox)
        return r
    end
    local n = w * h
    local luma = D.u8(n)
    local pl = D.u8(n)
    local ref = D.paperRef(data, w, h)
    local paperLuma = D.paperLuma
    local i = 0
    for p = 0, n - 1 do
        local R, G, B = data[i], data[i + 1], data[i + 2]
        luma[p] = 0.299 * R + 0.587 * G + 0.114 * B
        pl[p] = paperLuma(R, G, B, ref)
        i = i + 4
    end
    return D.detectFramedAt(luma, pl, w, h, rtl, bbox, debug, cleanRects)
end

function D.detectFramedAt(luma, pl, w, h, rtl, bbox, debug, cleanRects)
    if cleanRects == nil then cleanRects = {} end
    local area, overlap, covered = D.area, D.overlap, D.covered
    local n = w * h
    local level = D.paperLevel(pl, D.TUNE.framedCap, D.TUNE.framedDrop)
    local paper = D.u8(n)
    for p = 0, n - 1 do
        if pl[p] >= level then paper[p] = 1 end
    end

    local dim = math.min(w, h)
    local minLen = D.round(dim * 0.08)
    local tol = math.max(3, D.round(dim * 0.02))
    local maxGap = math.max(3, D.round(dim * 0.04))
    local start = bbox or { x0 = 0, y0 = 0, x1 = w, y1 = h }

    local function paperRun(horizontal, o, from, to)
        local outer = horizontal and h or w
        local sO = horizontal and w or 1
        local sI = horizontal and 1 or w
        local k = 0
        for i = from, to - 1 do
            for d = -maxGap, maxGap do
                local oo = o + d
                if oo >= 0 and oo < outer
                    and paper[oo * sO + i * sI] ~= 0 then
                    k = k + 1
                    break
                end
            end
        end
        return k / math.max(1, to - from)
    end

    local overflow = false
    local function edges(horizontal, side)
        local segs = D.paperEdges(paper, w, h, horizontal, side, minLen)
        if #segs > D.FRAMED_MAX_SEGS then
            overflow = true
            return {}
        end
        return D.mergeCollinear(segs, tol, 3 * maxGap, function(o, a, b)
            return paperRun(horizontal, o, a, b)
        end)
    end
    local topsOwn = edges(true, 1)
    local bottomsOwn = edges(true, -1)
    local leftsOwn = edges(false, 1)
    local rightsOwn = edges(false, -1)

    local gutter = math.max(2, D.round(dim * 0.008))
    local minGutter = math.max(3, D.round(dim * 0.006))
    local function shifted(list, delta)
        return D.map(list, function(l) return D.assign(l, { o = l.o + delta, borrowed = true }) end)
    end
    local byO = function(a, b) return a.o - b.o end
    local tops = D.concat(topsOwn, shifted(bottomsOwn, gutter))
    local bottoms = D.concat(bottomsOwn, shifted(topsOwn, -gutter))
    local lefts = D.sort(D.concat(leftsOwn, shifted(rightsOwn, gutter)), byO)
    local rights = D.sort(D.concat(rightsOwn, shifted(leftsOwn, -gutter)), byO)

    if overflow
        or #tops * #bottoms > D.FRAMED_MAX_PAIRS
        or #lefts * #rights > D.FRAMED_MAX_PAIRS then
        return { rects = {}, framedCount = 0, bbox = start, text = false, style = "framed" }
    end

    local minW = D.round(w * 0.08)
    local minH = D.round(h * 0.06)

    local function byFirst(p, q) return p[1] - q[1] end
    local function cover(lines, o, a, b)
        local parts = {}
        for _, l in ipairs(lines) do
            if math.abs(l.o - o) <= tol then
                for _, pr in ipairs(l.parts or { { l.from, l.to } }) do
                    local s = math.max(a, pr[1])
                    local e = math.min(b, pr[2])
                    if e > s then parts[#parts + 1] = { s, e } end
                end
            end
        end
        D.sort(parts, byFirst)
        local total = 0
        local last = -math.huge
        for _, pr in ipairs(parts) do
            local s, e = pr[1], pr[2]
            if e > last then
                total = total + (e - math.max(s, last))
                last = e
            end
        end
        return total / math.max(1, b - a)
    end
    local function spans(l, a, b)
        return (math.min(l.to, b) - math.max(l.from, a)) / math.max(1, b - a)
    end

    local function inkFrac(r)
        local k = 0
        for y = math.max(0, r.y0), math.min(h, r.y1) - 1 do
            for x = math.max(0, r.x0), math.min(w, r.x1) - 1 do
                if paper[y * w + x] == 0 then k = k + 1 end
            end
        end
        return k / math.max(1, area(r))
    end

    local function paperBand(horizontal, o, dir, a, b, orEdge)
        if orEdge == nil then orEdge = false end
        local outer = horizontal and h or w
        local sO = horizontal and w or 1 -- index = oo * sO + i * sI
        local sI = horizontal and 1 or w
        local k = 0
        for i = a, b - 1 do
            local oo = o
            local skip = 0
            while skip < 3 and oo >= 0 and oo < outer
                and paper[oo * sO + i * sI] == 0 do
                oo = oo + dir
                skip = skip + 1
            end
            local cnt = 0
            while oo >= 0 and oo < outer and (cnt <= maxGap or orEdge) do
                if paper[oo * sO + i * sI] == 0 then break end
                cnt = cnt + 1
                oo = oo + dir
            end
            if cnt >= minGutter and (cnt <= maxGap or (orEdge and (oo < 0 or oo >= outer))) then
                k = k + 1
            elseif orEdge and (o + dir * 3 < 0 or o + dir * 3 >= outer) then
                k = k + 1
            end
        end
        return k / math.max(1, b - a)
    end

    local function sideGutter(horizontal, o, dir, a, b, farLines)
        local outer = horizontal and h or w
        if o + dir * 3 < 0 or o + dir * 3 >= outer then return 2 end
        if paperBand(horizontal, o, dir, a, b, true) < 0.6 then return 0 end
        if paperBand(horizontal, o, dir, a, b, false) < 0.6 then return 2 end
        for _, m in ipairs(farLines) do
            if (m.o - o) * dir > 0 and (m.o - o) * dir <= maxGap + tol and covered(m, a, b) >= 0.5 then
                return 2
            end
        end
        return 1
    end
    local function gutterSides(r)
        local g1 = sideGutter(true, r.y0, -1, r.x0, r.x1, bottomsOwn)
        local g2 = sideGutter(true, r.y1, 1, r.x0, r.x1, topsOwn)
        local g3 = sideGutter(false, r.x0, -1, r.y0, r.y1, rightsOwn)
        local g4 = sideGutter(false, r.x1, 1, r.y0, r.y1, leftsOwn)
        return g1 + g2 + g3 + g4
    end
    local function gutterLine(lines, horizontal, dir, near, a, b)
        for _, m in ipairs(lines) do
            if math.abs(m.o - near) <= tol and covered(m, a, b) >= 0.6
                and paperBand(horizontal, m.o, dir, a, b) >= 0.6 then
                return true
            end
        end
        return false
    end

    -- A gutter that crosses the candidate (t, bt, l, r) splits it in two.
    local function splitBy(t, bt, l, r)
        local lo, hi = t.o + tol, bt.o - tol
        for _, m in ipairs(bottomsOwn) do
            if m.o > lo and m.o < hi and covered(m, l.o, r.o) >= 0.6 and paperBand(true, m.o, 1, l.o, r.o) >= 0.6 then
                return true
            end
        end
        for _, m in ipairs(topsOwn) do
            if m.o > lo and m.o < hi and covered(m, l.o, r.o) >= 0.6 and paperBand(true, m.o, -1, l.o, r.o) >= 0.6 then
                return true
            end
        end
        for _, m in ipairs(bottomsOwn) do
            if m.o > lo and m.o < hi and covered(m, l.o, r.o) >= 0.6 then
                for _, q in ipairs(topsOwn) do
                    if q.o - m.o >= minGutter and q.o - m.o <= maxGap and covered(q, l.o, r.o) >= 0.6 then
                        return true
                    end
                end
            end
        end
        return false
    end

    local found = {}
    local deadline = D.now() + D.FRAMED_BUDGET_MS
    local timedOut = false
    for _, t in ipairs(tops) do
        if timedOut then break end
        for _, bt in ipairs(bottoms) do
            if D.now() > deadline then
                timedOut = true
                break
            end
            if bt.o - t.o < minH then goto next_bt end
            do
                local X0 = math.min(t.from, bt.from) - tol - maxGap
                local X1 = math.max(t.to, bt.to) + tol + maxGap
                if X1 - X0 < minW then goto next_bt end
                local ls = {}
                for _, l in ipairs(lefts) do
                    if l.o >= X0 and l.o <= X1 - minW and spans(l, t.o, bt.o) >= 0.6 then ls[#ls + 1] = l end
                end
                local rs = {}
                for _, l in ipairs(rights) do
                    if l.o >= X0 + minW and l.o <= X1 and spans(l, t.o, bt.o) >= 0.6 then rs[#rs + 1] = l end
                end
                for _, l in ipairs(ls) do
                    local first = nil
                    for _, q in ipairs(rs) do
                        if q.o - l.o >= minW then
                            first = q
                            break
                        end
                    end
                    if first then
                        for _, r in ipairs(rs) do
                            if not (r.o - l.o >= minW and r.o - first.o <= tol) then goto next_r end
                            do
                                local own = (t.borrowed and 0 or 1)
                                    + (bt.borrowed and 0 or 1)
                                    + (l.borrowed and 0 or 1)
                                    + (r.borrowed and 0 or 1)
                                if own < 1
                                    or (own < 2 and inkFrac({ x0 = l.o, y0 = t.o, x1 = r.o, y1 = bt.o }) < 0.25) then
                                    goto next_r
                                end
                                local ct = cover(tops, t.o, l.o, r.o)
                                local cb = cover(bottoms, bt.o, l.o, r.o)
                                if ct < 0.6 or cb < 0.6 then goto next_r end
                                if splitBy(t, bt, l, r) then goto next_r end
                                found[#found + 1] = { x0 = l.o, y0 = t.o, x1 = r.o, y1 = bt.o, own = own }
                            end
                            ::next_r::
                        end
                    end
                end
            end
            ::next_bt::
        end
    end

    local dark = math.min(170, level - 40)
    local reach = math.max(6, D.round(dim * 0.008))
    local chunk = math.max(20, D.round(dim * 0.1))
    local function side(horizontal, o, from, to)
        local outer = horizontal and h or w
        local sO = horizontal and w or 1
        local sI = horizontal and 1 or w
        local total = 0
        local a = from
        while a < to do
            local b = math.min(to, a + chunk)
            local best = 0
            for d0 = -reach, reach do
                local hit = 0
                for i = a, b - 1 do
                    local any = false
                    for d = d0 - 1, d0 + 1 do
                        local oo = o + d
                        if oo >= 0 and oo < outer
                            and luma[oo * sO + i * sI] < dark then
                            any = true
                            break
                        end
                    end
                    if any then hit = hit + 1 end
                end
                if hit > best then best = hit end
            end
            total = total + best
            a = a + chunk
        end
        return total / math.max(1, to - from)
    end
    local function frameScore(r)
        local x0 = math.max(0, r.x0)
        local x1 = math.min(w, r.x1)
        local y0 = math.max(0, r.y0)
        local y1 = math.min(h, r.y1)
        local s = {
            side(true, y0, x0, x1),
            side(true, y1, x0, x1),
            side(false, x0, y0, y1),
            side(false, x1, y0, y1),
        }
        D.sort(s, D.numcmp)
        return s[2]
    end

    local function realGutter(a, b)
        local xo0 = math.max(a.x0, b.x0)
        local xo1 = math.min(a.x1, b.x1)
        if xo1 - xo0 >= minW and b.y0 - a.y1 >= -tol and b.y0 - a.y1 <= maxGap + tol then
            return gutterLine(bottomsOwn, true, 1, a.y1, xo0, xo1)
                or gutterLine(topsOwn, true, -1, b.y0, xo0, xo1)
        end
        local yo0 = math.max(a.y0, b.y0)
        local yo1 = math.min(a.y1, b.y1)
        if yo1 - yo0 >= minH and b.x0 - a.x1 >= -tol and b.x0 - a.x1 <= maxGap + tol then
            return gutterLine(rightsOwn, false, 1, a.x1, yo0, yo1)
                or gutterLine(leftsOwn, false, -1, b.x0, yo0, yo1)
        end
        return false
    end

    local byAreaDesc = function(a, b) return area(b) - area(a) end
    local dropped = {}
    local function inside(a, b)
        return overlap(a, b) >= 0.9 * area(a) and area(a) < 0.9 * area(b)
    end
    for _, c in ipairs(D.sort(D.concat(found), byAreaDesc)) do
        if dropped[c] then goto next_c end
        do
            local inners = {}
            for _, o in ipairs(found) do
                if not dropped[o] and o ~= c and inside(o, c) then inners[#inners + 1] = o end
            end
            D.sort(inners, byAreaDesc)
            if #inners < 2 then goto next_c end
            local taken = {}
            for _, o in ipairs(inners) do
                local clash = false
                for _, k in ipairs(taken) do
                    if overlap(k, o) > 0.3 * math.min(area(k), area(o)) then
                        clash = true
                        break
                    end
                end
                if not clash then taken[#taken + 1] = o end
            end
            local tiles = {}
            for _, o in ipairs(taken) do
                for _, q in ipairs(taken) do
                    if q ~= o and (realGutter(o, q) or realGutter(q, o)) then
                        tiles[#tiles + 1] = o
                        break
                    end
                end
            end
            local coveredArea = 0
            for _, o in ipairs(tiles) do coveredArea = coveredArea + area(o) end
            if #tiles >= 2 and coveredArea >= 0.5 * area(c) then
                dropped[c] = true
            elseif gutterSides(c) == 8 and frameScore(c) >= 0.5 then
                local weak = {}
                for _, o in ipairs(inners) do
                    if gutterSides(o) <= 4 then weak[#weak + 1] = o end
                end
                for _, o in ipairs(weak) do dropped[o] = true end
            end
        end
        ::next_c::
    end

    local function straddles(c)
        for _, o in ipairs(cleanRects) do
            local ov = overlap(c, o)
            if ov >= 0.15 * area(c) and ov <= 0.85 * area(c) and ov <= 0.85 * area(o) then return true end
        end
        return false
    end
    local panelSized = D.isPanelSized(w, h)
    local scored = {}
    for _, c in ipairs(found) do
        if not dropped[c] and panelSized(c) then
            local gutters = gutterSides(c)
            scored[#scored + 1] = D.assign(c, {
                frame = frameScore(c),
                gutters = gutters,
                straddles = straddles(c) and 1 or 0,
            })
        end
    end
    D.sort(scored, function(a, b)
        local d = D.round(10 * b.frame) - D.round(10 * a.frame)
        if d ~= 0 then return d end
        d = a.straddles - b.straddles
        if d ~= 0 then return d end
        d = b.gutters - a.gutters
        if d ~= 0 then return d end
        d = b.own - a.own
        if d ~= 0 then return d end
        return area(b) - area(a)
    end)
    local sized = {}
    local swallowed = {}
    for _, c in ipairs(scored) do
        if swallowed[c] then goto next_s end
        for _, k in ipairs(sized) do
            if overlap(k, c) > 0.05 * math.min(area(k), area(c)) then goto next_s end
        end
        sized[#sized + 1] = c
        for _, o in ipairs(scored) do
            if o ~= c and not swallowed[o] and inside(o, c) then swallowed[o] = true end
        end
        ::next_s::
    end

    -- Captions above each panel.
    local captionGap = D.round(h * 0.012)
    for _, r in ipairs(sized) do
        local limit = start.y0
        for _, q in ipairs(D.concat(sized, cleanRects)) do
            if q ~= r and q.y1 <= r.y0 + tol and q.x1 > r.x0 and q.x0 < r.x1 then
                limit = math.max(limit, q.y1)
            end
        end
        local y = r.y0 - 2
        local gap = 0
        local top = r.y0
        while y > limit and gap <= captionGap do
            local inkN = 0
            for x = r.x0 + 2, r.x1 - 3 do
                if paper[y * w + x] == 0 then inkN = inkN + 1 end
            end
            local frac = inkN / math.max(1, r.x1 - r.x0 - 4)
            if frac > 0.015 and frac < 0.98 then
                top = y
                gap = 0
            else
                gap = gap + 1
            end
            y = y - 1
        end
        if r.y0 - top <= h * 0.09 then r.y0 = top end
    end
    -- …and below.
    for _, r in ipairs(sized) do
        local limit = start.y1
        for _, q in ipairs(D.concat(sized, cleanRects)) do
            if q ~= r and q.y0 >= r.y1 - tol and q.x1 > r.x0 and q.x0 < r.x1 then
                limit = math.min(limit, q.y0)
            end
        end
        local y = r.y1 + 1
        local gap = 0
        local bottom = r.y1
        while y < limit and gap <= captionGap do
            local inkN = 0
            for x = r.x0 + 2, r.x1 - 3 do
                if paper[y * w + x] == 0 then inkN = inkN + 1 end
            end
            local frac = inkN / math.max(1, r.x1 - r.x0 - 4)
            if frac > 0.03 and frac < 0.98 then
                bottom = y + 1
                gap = 0
            else
                gap = gap + 1
            end
            y = y + 1
        end
        if bottom - r.y1 <= h * 0.09 then r.y1 = bottom end
    end

    -- Leftovers of the clean panels once the frames are removed.
    local leftovers = {}
    for _, c in ipairs(cleanRects) do
        local pieces = { c }
        for _, f in ipairs(sized) do
            local nxt = {}
            for _, q in ipairs(pieces) do
                if overlap(q, f) == 0 then
                    nxt[#nxt + 1] = q
                else
                    if f.y0 > q.y0 then nxt[#nxt + 1] = { x0 = q.x0, y0 = q.y0, x1 = q.x1, y1 = f.y0 } end
                    if f.y1 < q.y1 then nxt[#nxt + 1] = { x0 = q.x0, y0 = f.y1, x1 = q.x1, y1 = q.y1 } end
                    local yy0 = math.max(q.y0, f.y0)
                    local yy1 = math.min(q.y1, f.y1)
                    if f.x0 > q.x0 then nxt[#nxt + 1] = { x0 = q.x0, y0 = yy0, x1 = f.x0, y1 = yy1 } end
                    if f.x1 < q.x1 then nxt[#nxt + 1] = { x0 = f.x1, y0 = yy0, x1 = q.x1, y1 = yy1 } end
                end
            end
            pieces = {}
            for _, q in ipairs(nxt) do
                if q.x1 - q.x0 >= minW and q.y1 - q.y0 >= minH then pieces[#pieces + 1] = q end
            end
        end
        for _, q in ipairs(pieces) do
            local t = D.shrinkToInk(paper, w, q)
            if t and panelSized(t) and inkFrac(t) >= 0.25 then
                local clash = false
                for _, o in ipairs(leftovers) do
                    if overlap(o, t) > 0.3 * math.min(area(o), area(t)) then
                        clash = true
                        break
                    end
                end
                if not clash then leftovers[#leftovers + 1] = t end
            end
        end
    end

    -- Text boxes stuck to a panel are merged into it.
    local all = D.concat(sized, leftovers)
    local inkCache = {}
    local function wideStrip(r)
        return r.x1 - r.x0 > 0.5 * w and r.y1 - r.y0 > 0.08 * h
    end
    local function isStrip(r)
        return r.frame == nil and r.y1 - r.y0 <= 0.15 * h and not wideStrip(r)
    end
    local function isTextBox(r)
        if isStrip(r) then return true end
        if r.y1 - r.y0 > 0.15 * h or not (r.frame ~= nil and r.frame >= 0.4) or wideStrip(r) then
            return false
        end
        if inkCache[r] == nil then inkCache[r] = inkFrac(r) end
        return inkCache[r] <= 0.6
    end
    local boxes = {}
    for _, r in ipairs(all) do
        if isTextBox(r) then boxes[#boxes + 1] = r end
    end
    D.sort(boxes, function(a, b) return a.y0 - b.y0 end)
    for _, box in ipairs(boxes) do
        local best = nil
        for _, host in ipairs(all) do
            if host == box or isTextBox(host) then goto next_host end
            do
                local gx = math.max(box.x0, host.x0) - math.min(box.x1, host.x1)
                local gy = math.max(box.y0, host.y0) - math.min(box.y1, host.y1)
                local gap = nil
                if -gx >= 0.6 * (box.x1 - box.x0) and gy <= maxGap then
                    gap = math.max(0, gy)
                elseif -gy >= 0.6 * (box.y1 - box.y0) and gx <= maxGap then
                    gap = math.max(0, gx)
                end
                if gap == nil then goto next_host end
                if isStrip(box) and (gy > maxGap or box.x0 < host.x0 - tol or box.x1 > host.x1 + tol) then
                    goto next_host
                end
                if not best
                    or gap < best.gap
                    or (gap == best.gap and area(host) > area(best.host)) then
                    best = { host = host, gap = gap }
                end
            end
            ::next_host::
        end
        if best then
            local k = best.host
            k.x0 = math.min(k.x0, box.x0)
            k.y0 = math.min(k.y0, box.y0)
            k.x1 = math.max(k.x1, box.x1)
            k.y1 = math.max(k.y1, box.y1)
            inkCache[k] = nil
            local idx = D.indexOf(all, box)
            if idx == nil then idx = #all end -- JS splice(-1, 1)
            if idx > 0 then table.remove(all, idx) end
        end
    end
    local framedCount = 0
    for _, r in ipairs(all) do
        if r.frame ~= nil and r.frame >= 0.6 then framedCount = framedCount + 1 end
    end
    return { rects = all, framedCount = framedCount, bbox = start, text = false, style = "framed" }
end

function D.paperEdges(paper, w, h, horizontal, side, minLen)
    local outer = horizontal and h or w
    local inner = horizontal and w or h
    local step = horizontal and 1 or w
    local jump = horizontal and w or 1
    local E = D.u8(w * h)
    for o = 0, outer - 1 do
        local oo = o + side
        if oo >= 0 and oo < outer then
            local p = o * jump
            local q = oo * jump
            for _ = 0, inner - 1 do
                if paper[p] == 1 and paper[q] == 0 then E[p] = 1 end
                p = p + step
                q = q + step
            end
        end
    end
    local function inkAt(oo, i)
        return oo >= 0 and oo < outer and paper[oo * jump + i * step] == 0
    end
    local function solid(o, from, to)
        local k = 0
        for i = from, to - 1 do
            if inkAt(o, i) or inkAt(o + side, i) or inkAt(o + 2 * side, i) then k = k + 1 end
        end
        return k / math.max(1, to - from)
    end
    local segs = {}
    for o = 0, outer - 1 do
        local base = o * jump
        local run = 0
        local missed = 0
        local startI = -1
        for i = 0, inner do
            local on = false
            if i < inner then
                local p = base + i * step
                on = E[p] == 1
                    or (o > 0 and E[p - jump] == 1)
                    or (o < outer - 1 and E[p + jump] == 1)
            end
            if on then
                if startI < 0 then startI = i end
                run = run + 1
                missed = 0
            elseif startI >= 0 and missed < 4 and i < inner then
                missed = missed + 1
            else
                if run >= minLen and solid(o, startI, i - missed) >= 0.8 then
                    segs[#segs + 1] = { o = o, from = startI, to = i - missed }
                end
                run = 0
                missed = 0
                startI = -1
            end
        end
    end
    return segs
end

return D
