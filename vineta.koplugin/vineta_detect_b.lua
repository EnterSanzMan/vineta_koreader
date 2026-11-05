--[[--
Lua port of panels-core.js (Viñeta 3.6.1), lines 1001-1815:
detectClean … detectDenseAt (styles «márgenes claros», «calles oscuras» and the
entry points of «arte a sangre»). See docs/detector-lua.md.
]]

local ffi = require("ffi")
local bit = require("bit")
local D = require("vineta_detect_base")


-- ---------- estilo «márgenes claros» ----------

function D.detectClean(data, w, h, rtl)
    local border = D.estimateBackground(data, w, h)
    -- If the page border is mostly one color, that is the background; otherwise
    -- (bleed pages) try the usual backgrounds: white and black.
    local candidates
    if border.ratio >= 0.5 then
        candidates = { border.color }
    else
        candidates = {
            { 255, 255, 255 },
            { 0, 0, 0 },
        }
    end
    local best = nil
    for ci = 1, #candidates do
        local r = D.segment(data, w, h, candidates[ci], rtl)
        if not best or #r.rects > #best.rects then best = r end
    end
    best.style = "clean"
    return best
end

-- Builds the mask for a background color and cuts it into panels.
function D.segment(data, w, h, bg, rtl)
    local mask = D.removeSpecks(D.buildMask(data, w, h, bg), w, h)
    local c = {
        mask = mask,
        w = w,
        h = h,
        rtl = rtl,
        minGapX = math.max(2, D.round(w * 0.0035)),
        minGapY = math.max(2, D.round(h * 0.0035)),
    }
    local out = { rects = {}, text = false, bbox = nil }

    local inkPixels = 0
    for i = 0, D.len(mask) - 1 do inkPixels = inkPixels + mask[i] end
    local ink = inkPixels / (w * h)
    if ink < 0.01 then
        out.text = true -- blank or nearly blank page
        return out
    end

    -- Running text: many thin, similar bands (the lines).
    local pr = D.profiles(c, 0, 0, w, h)
    local rows, cols = pr.rows, pr.cols
    local ry = D.span(rows, D.noiseLevel(w))
    local rx = D.span(cols, D.noiseLevel(h))
    if ry and rx then out.bbox = { x0 = rx[1], y0 = ry[1], x1 = rx[2], y1 = ry[2] } end
    local pageBands = D.runs(rows, D.noiseLevel(w), 1)
    if #pageBands >= 6 and D.looksLikeLines(pageBands, h) then out.text = true end

    local leaves = {}
    D.xyCut(c, 0, 0, w, h, 0, leaves)

    local pageArea = w * h
    local rects = {}
    local textArea = 0
    for li = 1, #leaves do
        local r = leaves[li]
        if D.looksLikeText(c, r) then
            textArea = textArea + D.area(r)
            goto continue
        end
        if D.area(r) >= pageArea * 0.08 then
            local parts = D.splitByComponents(c, r)
            if parts then
                for k = 1, #parts do rects[#rects + 1] = parts[k] end
                goto continue
            end
        end
        rects[#rects + 1] = r
        ::continue::
    end

    if textArea >= pageArea * 0.2 then out.text = true end
    out.rects = D.filter(rects, D.isPanelSized(w, h))
    -- Little ink and no clear panels: credits, dedication, logo…
    if ink < 0.04 and #out.rects < 2 then out.text = true end
    -- Text page: nearly all the ink is in small blobs (letters).
    if not out.text and ink < 0.3 and D.looksLikeGlyphs(mask, w, h, inkPixels) then
        out.text = true
    end
    return out
end

-- Labels the ink blobs and measures how much ink is in letter-sized blobs.
function D.looksLikeGlyphs(mask, w, h, inkPixels)
    local maxGlyph = math.max(4, D.round(h * 0.025))
    local labels = D.u8(w * h)
    local stack = D.i32(w * h)
    local small = 0
    local smallInk = 0
    local floor = math.floor
    for p0 = 0, D.len(mask) - 1 do
        if labels[p0] ~= 0 or mask[p0] == 0 then goto continue end
        do
            local sp = 0
            stack[sp] = p0
            sp = sp + 1
            labels[p0] = 1
            local n = 0
            local y0 = h
            local y1 = 0
            local x0 = w
            local x1 = 0
            while sp ~= 0 do
                sp = sp - 1
                local cur = stack[sp]
                local cx = cur % w
                local cy = floor(cur / w)
                n = n + 1
                if cy < y0 then y0 = cy end
                if cy > y1 then y1 = cy end
                if cx < x0 then x0 = cx end
                if cx > x1 then x1 = cx end
                if cx > 0 and mask[cur - 1] ~= 0 and labels[cur - 1] == 0 then
                    labels[cur - 1] = 1
                    stack[sp] = cur - 1
                    sp = sp + 1
                end
                if cx < w - 1 and mask[cur + 1] ~= 0 and labels[cur + 1] == 0 then
                    labels[cur + 1] = 1
                    stack[sp] = cur + 1
                    sp = sp + 1
                end
                if cy > 0 and mask[cur - w] ~= 0 and labels[cur - w] == 0 then
                    labels[cur - w] = 1
                    stack[sp] = cur - w
                    sp = sp + 1
                end
                if cy < h - 1 and mask[cur + w] ~= 0 and labels[cur + w] == 0 then
                    labels[cur + w] = 1
                    stack[sp] = cur + w
                    sp = sp + 1
                end
            end
            -- single letter or text line (letters touch once the page is reduced)
            if y1 - y0 < maxGlyph and x1 - x0 < w * 0.4 then
                small = small + 1
                smallInk = smallInk + n
            end
        end
        ::continue::
    end
    return small >= 60 and smallInk >= inkPixels * 0.55
end

-- Drops page numbers, specks and loose lines.
function D.isPanelSized(w, h)
    return function(r)
        return D.area(r) >= w * h * 0.012
            and r.x1 - r.x0 >= w * 0.06
            and r.y1 - r.y0 >= h * 0.04
    end
end

-- ---------- estilo «calles oscuras» ----------

function D.darkFraction(data)
    local k = 0
    local len = D.len(data)
    for i = 0, len - 1, 4 do
        if 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2] < 50 then k = k + 1 end
    end
    return k / (len / 4)
end

function D.detectDark(data, w, h, rtl, debug, frames, hiLuma)
    if frames == nil then frames = {} end
    local floor = math.floor
    local n = w * h
    local mask = D.u8(n)
    do
        local i = 0
        local DARK_INK = D.DARK_INK
        for p = 0, n - 1 do
            if 0.299 * data[i] + 0.587 * data[i + 1] + 0.114 * data[i + 2] >= DARK_INK then mask[p] = 1 end
            i = i + 4
        end
    end
    local out = { rects = {}, text = false, bbox = nil, style = "dark" }

    -- Connected blobs on the mask dilated twice; low, not very wide ones are set aside.
    local grown = D.dilate(D.dilate(mask, w, h), w, h)
    local labels = D.i32(n)
    local stack = D.i32(n)
    local maxSmallH = math.max(4, D.round(h * 0.045))
    local small = {}
    local id = 0
    local biggest = 0
    for p0 = 0, n - 1 do
        if labels[p0] ~= 0 or grown[p0] == 0 then goto continue end
        do
            id = id + 1
            local sp = 0
            stack[sp] = p0
            sp = sp + 1
            labels[p0] = id
            local x0, x1, y0, y1 = w, 0, h, 0
            local px = 0
            while sp ~= 0 do
                sp = sp - 1
                local cur = stack[sp]
                local cx = cur % w
                local cy = floor(cur / w)
                px = px + 1
                if cx < x0 then x0 = cx end
                if cx > x1 then x1 = cx end
                if cy < y0 then y0 = cy end
                if cy > y1 then y1 = cy end
                if cx > 0 and grown[cur - 1] ~= 0 and labels[cur - 1] == 0 then labels[cur - 1] = id; stack[sp] = cur - 1; sp = sp + 1 end
                if cx < w - 1 and grown[cur + 1] ~= 0 and labels[cur + 1] == 0 then labels[cur + 1] = id; stack[sp] = cur + 1; sp = sp + 1 end
                if cy > 0 and grown[cur - w] ~= 0 and labels[cur - w] == 0 then labels[cur - w] = id; stack[sp] = cur - w; sp = sp + 1 end
                if cy < h - 1 and grown[cur + w] ~= 0 and labels[cur + w] == 0 then labels[cur + w] = id; stack[sp] = cur + w; sp = sp + 1 end
            end
            if px > biggest then biggest = px end
            local bw = x1 - x0 + 1
            local bh = y1 - y0 + 1
            -- Caption (low, not very wide) or speck/shard (small box): set aside.
            if (bh <= maxSmallH and bw <= w * 0.5) or (bw * bh <= n * 0.008 and bh <= h * 0.12) then
                small[#small + 1] = { id = id, x0 = x0, y0 = y0, x1 = x1 + 1, y1 = y1 + 1 }
            end
        end
        ::continue::
    end
    -- A single blob with more than 60 % of the page is an illustration.
    if biggest >= n * 0.6 then return out end
    local isSmall = D.u8(id + 1)
    for k = 1, #small do isSmall[small[k].id] = 1 end
    local art = D.u8(n)
    local ink = 0
    for p = 0, n - 1 do
        if mask[p] ~= 0 and isSmall[labels[p]] == 0 then
            art[p] = 1
            ink = ink + 1
        end
    end
    if ink < n * 0.02 then return out end

    local c = {
        mask = art,
        labels = labels,
        w = w,
        h = h,
        rtl = rtl,
        minGapX = math.max(2, D.round(w * 0.004)),
        minGapY = math.max(2, D.round(h * 0.004)),
        cleanCuts = 0,
    }
    local pr = D.profiles(c, 0, 0, w, h)
    local rows, cols = pr.rows, pr.cols
    local ry = D.span(rows, D.noiseLevel(w))
    local rx = D.span(cols, D.noiseLevel(h))
    if ry and rx then out.bbox = { x0 = rx[1], y0 = ry[1], x1 = rx[2], y1 = ry[2] } end
    local leaves = {}
    D.valleyCut(c, 0, 0, w, h, 0, leaves)
    -- Inset panels (framed) on a drawn background.
    local sized = D.isPanelSized(w, h)
    local candidates = D.filter(frames, function(f)
        return sized(f) and f.x1 - f.x0 >= w * 0.1 and f.y1 - f.y0 >= h * 0.08
    end)
    local function inOther(f, x, y)
        for k = 1, #candidates do
            local g = candidates[k]
            if g ~= f and x >= g.x0 and x < g.x1 and y >= g.y0 and y < g.y1 then return true end
        end
        return false
    end
    local function ringFree(f, side)
        local n0 = 0
        local free = 0
        for d = 2, 4 do
            if side == "top" or side == "bottom" then
                local y
                if side == "top" then y = f.y0 - d else y = f.y1 - 1 + d end
                if y < 0 or y >= h then return true end -- page border
                for x = math.max(0, f.x0), math.min(w, f.x1) - 1 do
                    n0 = n0 + 1
                    if art[y * w + x] == 0 or inOther(f, x, y) then free = free + 1 end
                end
            else
                local x
                if side == "left" then x = f.x0 - d else x = f.x1 - 1 + d end
                if x < 0 or x >= w then return true end
                for y = math.max(0, f.y0), math.min(h, f.y1) - 1 do
                    n0 = n0 + 1
                    if art[y * w + x] == 0 or inOther(f, x, y) then free = free + 1 end
                end
            end
        end
        return free >= n0 * 0.7
    end
    local SIDES = { "top", "bottom", "left", "right" }
    local goodFrames = D.filter(candidates, function(f)
        local k = 0
        for si = 1, 4 do
            if ringFree(f, SIDES[si]) then k = k + 1 end
        end
        return k >= 2
    end)
    local pieces = {}
    for li = 1, #leaves do
        local L = leaves[li]
        local inner = D.filter(goodFrames, function(f) return D.overlap(f, L) >= D.area(f) * 0.9 end)
        local innerArea = 0
        for k = 1, #inner do innerArea = innerArea + D.area(inner[k]) end
        -- Frames that overlap each other are not inset panels.
        local tangled = false
        for i = 1, #inner do
            local f = inner[i]
            for j = i + 1, #inner do
                local g = inner[j]
                if D.overlap(f, g) > math.min(D.area(f), D.area(g)) * 0.02 then
                    tangled = true
                    break
                end
            end
            if tangled then break end
        end
        if #inner < 2 or tangled or innerArea > D.area(L) * 0.9 then
            pieces[#pieces + 1] = L
            goto continue
        end
        do
            local erased = D.assign(c, { mask = D.slice(art) })
            for k = 1, #inner do
                local f = inner[k]
                for y = math.max(0, f.y0), math.min(h, f.y1) - 1 do
                    D.fill(erased.mask, 0, y * w + math.max(0, f.x0), y * w + math.min(w, f.x1))
                end
            end
            local rest = {}
            D.valleyCut(erased, L.x0, L.y0, L.x1, L.y1, 0, rest)
            local box = { x0 = w, y0 = h, x1 = 0, y1 = 0 }
            for k = 1, #inner do
                local f = inner[k]
                box = {
                    x0 = math.min(box.x0, f.x0),
                    y0 = math.min(box.y0, f.y0),
                    x1 = math.max(box.x1, f.x1),
                    y1 = math.max(box.y1, f.y1),
                }
            end
            for k = 1, #rest do
                local R = rest[k]
                if D.overlap(R, box) == 0 then
                    pieces[#pieces + 1] = R
                else
                    local options = D.filter({
                        D.assign(R, { y1 = math.min(R.y1, box.y0) }),
                        D.assign(R, { y0 = math.max(R.y0, box.y1) }),
                        D.assign(R, { x1 = math.min(R.x1, box.x0) }),
                        D.assign(R, { x0 = math.max(R.x0, box.x1) }),
                    }, function(q) return q.x1 > q.x0 and q.y1 > q.y0 and sized(q) end)
                    if #options > 0 then
                        pieces[#pieces + 1] = D.sort(options, function(a, b) return D.area(b) - D.area(a) end)[1]
                    end
                end
            end
            for k = 1, #inner do
                local f = inner[k]
                pieces[#pieces + 1] = { x0 = f.x0, y0 = f.y0, x1 = f.x1, y1 = f.y1 }
            end
            c.cleanCuts = c.cleanCuts + 1
        end
        ::continue::
    end
    -- Inset panels without a recognisable frame: anchored row.
    local anchored = {}
    for k = 1, #pieces do
        local L = pieces[k]
        if D.area(L) < n * 0.2 then
            anchored[#anchored + 1] = L
        else
            local split = D.insetRow(art, w, h, L, c, hiLuma)
            if split then c.cleanCuts = c.cleanCuts + 1 end
            local list = split or { L }
            for q = 1, #list do anchored[#anchored + 1] = list[q] end
        end
    end
    -- No very narrow panels on a black page.
    local rects = D.filter(anchored, function(r)
        return sized(r) and r.x1 - r.x0 >= w * 0.1 and r.y1 - r.y0 >= h * 0.06
    end)
    -- A narrow piece stuck to a panel along a long side is merged with it.
    local function slim(r) return r.x1 - r.x0 < w * 0.16 or r.y1 - r.y0 < h * 0.1 end
    local touch = D.round(math.min(w, h) * 0.05)
    local changed = true
    while changed do
        changed = false
        local slims = D.filter(rects, slim)
        for si = 1, #slims do
            local r = slims[si]
            local list = rects
            for oi = 1, #list do
                local o = list[oi]
                if o == r then goto nexto end
                do
                    local sx = math.min(r.x1, o.x1) - math.max(r.x0, o.x0)
                    local sy = math.min(r.y1, o.y1) - math.max(r.y0, o.y0)
                    local beside = sy >= (r.y1 - r.y0) * 0.6
                        and (math.abs(r.x1 - o.x0) <= touch or math.abs(o.x1 - r.x0) <= touch)
                    local stacked = sx >= (r.x1 - r.x0) * 0.6
                        and (math.abs(r.y1 - o.y0) <= touch or math.abs(o.y1 - r.y0) <= touch)
                    if not beside and not stacked then goto nexto end
                    local u = {
                        x0 = math.min(r.x0, o.x0),
                        y0 = math.min(r.y0, o.y0),
                        x1 = math.max(r.x1, o.x1),
                        y1 = math.max(r.y1, o.y1),
                    }
                    if D.some(rects, function(q)
                        return q ~= r and q ~= o and D.overlap(u, q) > D.area(q) * 0.02
                    end) then
                        goto nexto
                    end
                    o.x0, o.y0, o.x1, o.y1 = u.x0, u.y0, u.x1, u.y1
                    rects = D.filter(rects, function(q) return q ~= r end)
                    changed = true
                    break
                end
                ::nexto::
            end
            if changed then break end
        end
    end
    -- A full-page illustration also has dark furrows: without a clean cut, whole page.
    if D.some(rects, function(r) return D.area(r) >= n * 0.85 end) or c.cleanCuts == 0 then rects = {} end
    if #rects < 2 then
        out.rects = rects
        return out
    end

    -- Captions and specks go back to the nearest panel (within 6 % of the page).
    local reach = D.round(math.min(w, h) * 0.06)
    local function dist(a, b)
        return math.max(0, b.x0 - a.x1, a.x0 - b.x1) + math.max(0, b.y0 - a.y1, a.y0 - b.y1)
    end
    D.sort(small, function(a, b) return D.area(b) - D.area(a) end)
    for k = 1, #small do
        local s = small[k]
        local best = nil
        local bd = math.huge
        for q = 1, #rects do
            local r = rects[q]
            local d = dist(r, s)
            if d < bd then
                bd = d
                best = r
            end
        end
        if not best or bd > reach then goto continue end
        do
            local grownRect = {
                x0 = math.min(best.x0, s.x0),
                y0 = math.min(best.y0, s.y0),
                x1 = math.max(best.x1, s.x1),
                y1 = math.max(best.y1, s.y1),
            }
            if D.some(rects, function(o) return o ~= best and D.overlap(grownRect, o) ~= 0 end) then
                goto continue
            end
            best.x0, best.y0, best.x1, best.y1 = grownRect.x0, grownRect.y0, grownRect.x1, grownRect.y1
        end
        ::continue::
    end
    out.rects = rects
    return out
end

-- Bands with drawing of a profile separated by dark gutters. Returns a list of
-- {a, b} pairs (1-based: band[1] = a, band[2] = b), positions 0-based in p.
function D.darkBands(p, len, minGap, valid, onClean)
    local n = D.len(p)
    local low = math.max(D.noiseLevel(len), math.floor(len * D.DARK_CUT_LOW))
    local high = math.floor(len * D.DARK_CUT_HIGH)
    local win = math.max(12, D.round(n * 0.06))
    local function median(a, b)
        local arr = {}
        for i = math.max(0, a), math.min(n, b) - 1 do arr[#arr + 1] = p[i] end
        if #arr == 0 then return 0 end
        D.sort(arr, D.numcmp)
        return arr[bit.rshift(#arr, 1) + 1]
    end
    local cuts = {} -- {a, b}: gutter lines [a, b)
    local i = 0
    while i < n do
        if p[i] > high then
            i = i + 1
            goto continue
        end
        do
            local j = i
            while j < n and p[j] <= high do j = j + 1 end
            -- Inside the stretch ≤ high, is there a clean gutter?
            local a = -1
            local found = false
            for k = i, j do
                local ok = k < j and p[k] <= low
                if ok and a < 0 then a = k end
                if not ok and a >= 0 then
                    if k - a >= minGap then
                        cuts[#cuts + 1] = { a, k }
                        found = true
                        if onClean then onClean() end
                    end
                    a = -1
                end
            end
            if not found and j - i >= 2 and i > 0 and j < n then
                local mn = math.huge
                local at = i
                for k = i, j - 1 do
                    if p[k] < mn then
                        mn = p[k]
                        at = k
                    end
                end
                local sides = math.min(median(i - win, i), median(j, j + win))
                if mn <= sides * 0.5 and sides >= len * 0.25 and (not valid or valid(at)) then
                    cuts[#cuts + 1] = { at, at + 1 }
                end
            end
            i = j
        end
        ::continue::
    end
    -- Bands with content between gutters, trimmed to their inked lines.
    local bands = {}
    local s = 0
    for k = 1, #cuts do
        local a, b = cuts[k][1], cuts[k][2]
        if a > s then bands[#bands + 1] = { s, a } end
        s = b
    end
    if s < n then bands[#bands + 1] = { s, n } end
    local noise = D.noiseLevel(len)
    local res = {}
    for k = 1, #bands do
        local a, b = bands[k][1], bands[k][2]
        while a < b and p[a] <= noise do a = a + 1 end
        while b > a and p[b - 1] <= noise do b = b - 1 end
        if b > a then res[#res + 1] = { a, b } end
    end
    return res
end

-- Row of inset panels in a leaf. Returns the pieces (list) or nil.
function D.insetRow(art, w, h, L, c, hiLuma)
    local width = L.x1 - L.x0
    local height = L.y1 - L.y0
    local minRun = D.round(h * 0.1)
    local tol = D.round(h * 0.03)
    local s = (hiLuma ~= nil and D.len(hiLuma) == 4 * w * h) and 2 or 1
    local W = s * w
    local DARK_INK = D.DARK_INK
    local function isArt(x, y)
        if s == 1 then return art[y * w + x] ~= 0 end
        return hiLuma[y * W + x] >= DARK_INK and art[bit.arshift(y, 1) * w + bit.arshift(x, 1)] ~= 0
    end
    for pass = 1, 2 do
        local fromBottom = pass == 1
        -- Black run of each column from the chosen edge.
        local run = D.i32(width)
        for x = L.x0, L.x1 - 1 do
            local best = 0
            for sx = s * x, s * x + s - 1 do
                local k = 0
                local hits = 0
                for i = 0, s * height - 1 do
                    local y
                    if fromBottom then y = s * L.y1 - 1 - i else y = s * L.y0 + i end
                    if isArt(sx, y) then
                        hits = hits + 1
                        if hits >= s + 1 then break end
                    else
                        hits = 0
                    end
                    k = i + 1
                end
                best = math.max(best, math.floor(k / s))
            end
            run[x - L.x0] = best
        end
        -- Gaps: stretches of contiguous columns with a long run (but not the whole leaf).
        local gaps = {}
        local a = -1
        local maxRun = height - D.round(h * 0.04)
        for i = 0, width do
            local ok = i < width and run[i] >= minRun and run[i] < maxRun
            if ok and a < 0 then a = i end
            if not ok and a >= 0 then
                if i - a >= c.minGapX then
                    local rs = {}
                    for q = a, i - 1 do rs[#rs + 1] = run[q] end
                    D.sort(rs, D.numcmp)
                    gaps[#gaps + 1] = { a = a, b = i, run = rs[bit.rshift(#rs, 1) + 1] }
                end
                a = -1
            end
        end
        if #gaps < 2 then goto continue end
        do
            -- All at the same height (the median), or at least two of them.
            local runs = {}
            for q = 1, #gaps do runs[q] = gaps[q].run end
            D.sort(runs, D.numcmp)
            local depth = runs[bit.rshift(#runs, 1) + 1]
            local same = D.filter(gaps, function(g) return math.abs(g.run - depth) <= tol end)
            if #same < 2 then goto continue end
            local cutY = fromBottom and L.y1 - depth or L.y0 + depth
            local top
            if fromBottom then
                top = { x0 = L.x0, y0 = L.y0, x1 = L.x1, y1 = cutY }
            else
                top = { x0 = L.x0, y0 = cutY, x1 = L.x1, y1 = L.y1 }
            end
            local rowY0 = fromBottom and cutY or L.y0
            local rowY1 = fromBottom and L.y1 or cutY
            -- The row is split at the gaps; each piece is fitted to its drawing.
            local bounds = { L.x0 }
            for q = 1, #same do
                bounds[#bounds + 1] = L.x0 + same[q].a
                bounds[#bounds + 1] = L.x0 + same[q].b
            end
            bounds[#bounds + 1] = L.x1
            local cells = {}
            for i = 1, #bounds, 2 do
                local cell = D.shrink(art, w, { x0 = bounds[i], y0 = rowY0, x1 = bounds[i + 1], y1 = rowY1 })
                if cell then cells[#cells + 1] = cell end
            end
            local sized = D.isPanelSized(w, h)
            if #D.filter(cells, sized) < 1 or not sized(top) then goto continue end
            return D.concat({ D.shrink(art, w, top) or top }, cells)
        end
        ::continue::
    end
    return nil
end

-- Rectangle fitted to the drawing it contains (nil if none).
function D.shrink(art, w, r)
    local x0 = r.x1
    local x1 = r.x0
    local y0 = r.y1
    local y1 = r.y0
    for y = r.y0, r.y1 - 1 do
        for x = r.x0, r.x1 - 1 do
            if art[y * w + x] ~= 0 then
                if x < x0 then x0 = x end
                if x >= x1 then x1 = x + 1 end
                if y < y0 then y0 = y end
                if y >= y1 then y1 = y + 1 end
            end
        end
    end
    if x1 > x0 and y1 > y0 then return { x0 = x0, y0 = y0, x1 = x1, y1 = y1 } end
    return nil
end

-- Does the line split a drawing blob with at least a quarter of its pixels on each side?
function D.splitsBlob(c, horizontal, line, x0, y0, x1, y1)
    local labels, w, h = c.labels, c.w, c.h
    if not labels then return false end
    local touching = {}
    local touchList = {}
    for d = -2, 2 do
        if horizontal then
            local y = line + d
            if not (y < y0 or y >= y1) then
                for x = x0, x1 - 1 do
                    local l = labels[y * w + x]
                    if l ~= 0 and not touching[l] then
                        touching[l] = true
                        touchList[#touchList + 1] = l
                    end
                end
            end
        else
            local x = line + d
            if not (x < x0 or x >= x1) then
                for y = y0, y1 - 1 do
                    local l = labels[y * w + x]
                    if l ~= 0 and not touching[l] then
                        touching[l] = true
                        touchList[#touchList + 1] = l
                    end
                end
            end
        end
    end
    if #touchList == 0 then return false end
    local before = {}
    local after = {}
    for y = y0, y1 - 1 do
        for x = x0, x1 - 1 do
            local l = labels[y * w + x]
            if l ~= 0 and touching[l] then
                local side
                if (horizontal and y or x) < line then side = before else side = after end
                side[l] = (side[l] or 0) + 1
            end
        end
    end
    for k = 1, #touchList do
        local l = touchList[k]
        local a = before[l] or 0
        local b = after[l] or 0
        if a + b >= w * h * 0.01 and math.min(a, b) >= (a + b) * 0.25 then return true end
    end
    return false
end

-- XY-cut for dark pages: rows then columns, with the gutters of darkBands.
function D.valleyCut(c, x0, y0, x1, y1, depth, out)
    local pr = D.profiles(c, x0, y0, x1, y1)
    local rows, cols = pr.rows, pr.cols
    local ry = D.span(rows, D.noiseLevel(x1 - x0))
    local rx = D.span(cols, D.noiseLevel(y1 - y0))
    if not ry or not rx then return end
    local nx0 = x0 + rx[1]
    local nx1 = x0 + rx[2]
    local ny0 = y0 + ry[1]
    local ny1 = y0 + ry[2]
    if depth < 12 then
        -- A valley that splits one drawing blob is not a gutter.
        local function clean() c.cleanCuts = c.cleanCuts + 1 end
        local bands = D.darkBands(D.sub(rows, ry[1], ry[2]), x1 - x0, c.minGapY,
            function(at) return not D.splitsBlob(c, true, ny0 + at, nx0, ny0, nx1, ny1) end, clean)
        if #bands > 1 then
            for k = 1, #bands do
                D.valleyCut(c, nx0, ny0 + bands[k][1], nx1, ny0 + bands[k][2], depth + 1, out)
            end
            return
        end
        local strips = D.darkBands(D.sub(cols, rx[1], rx[2]), y1 - y0, c.minGapX,
            function(at) return not D.splitsBlob(c, false, nx0 + at, nx0, ny0, nx1, ny1) end, clean)
        if #strips > 1 then
            if c.rtl then D.reverse(strips) end
            for k = 1, #strips do
                D.valleyCut(c, nx0 + strips[k][1], ny0, nx0 + strips[k][2], ny1, depth + 1, out)
            end
            return
        end
    end
    out[#out + 1] = { x0 = nx0, y0 = ny0, x1 = nx1, y1 = ny1 }
end

-- ---------- estilo «arte a sangre» (entry points) ----------

function D.detectDense(data, w, h, rtl, bbox, debug, hi, strict)
    if strict == nil then strict = false end
    local n = w * h
    local paper = D.u8(n)
    local level
    if hi ~= nil and D.len(hi) == 4 * n then
        level = D.paperLevel(hi)
        local W = 2 * w
        for y = 0, h - 1 do
            local a = 2 * y * W
            local b = a + W
            for x = 0, w - 1 do
                local i = a + 2 * x
                local j = b + 2 * x
                local c = 0
                if hi[i] >= level then c = c + 1 end
                if hi[i + 1] >= level then c = c + 1 end
                if hi[j] >= level then c = c + 1 end
                if hi[j + 1] >= level then c = c + 1 end
                if c >= 2 then paper[y * w + x] = 1 end
            end
        end
    else
        local luma = D.u8(n)
        local ref = D.paperRef(data, w, h)
        local paperLuma = D.paperLuma
        local i = 0
        for p = 0, n - 1 do
            luma[p] = paperLuma(data[i], data[i + 1], data[i + 2], ref)
            i = i + 4
        end
        level = D.paperLevel(luma)
        for p = 0, n - 1 do
            if luma[p] >= level then paper[p] = 1 end
        end
    end
    return D.detectDenseAt(paper, level, w, h, rtl, bbox, debug, strict)
end

function D.detectDenseAt(paper, level, w, h, rtl, bbox, debug, strict)
    if strict == nil then strict = false end
    local n = w * h

    local start = bbox or { x0 = 0, y0 = 0, x1 = w, y1 = h }
    local dim = math.min(w, h)
    local maxGap = math.max(3, D.round(dim * 0.04))

    -- 1) straight edges, extended
    local walls = D.u8(n)
    local gaps = {}
    local segs = {}
    D.straightEdges(paper, w, h, true, D.round(w * 0.1), maxGap, walls, gaps, segs)
    D.straightEdges(paper, w, h, false, D.round(h * 0.1), maxGap, walls, gaps, segs)
    D.extendWalls(
        segs,
        walls,
        paper,
        w,
        h,
        start,
        D.round(dim * 0.06),
        D.round(dim * 0.12),
        D.round(dim * 0.45)
    )

    local gutter = nil
    if #gaps >= 20 then
        D.sort(gaps, D.numcmp)
        gutter = gaps[bit.rshift(#gaps, 1) + 1] / dim
    end

    -- 2) aligned segments
    local function paperRun(horizontal, o, from, to)
        local outer = horizontal and h or w
        local cnt = 0
        for i = from, to - 1 do
            for d = -maxGap, maxGap do
                local oo = o + d
                if not (oo < 0 or oo >= outer) then
                    local idx
                    if horizontal then idx = oo * w + i else idx = i * w + oo end
                    if paper[idx] ~= 0 then
                        cnt = cnt + 1
                        break
                    end
                end
            end
        end
        return cnt / math.max(1, to - from)
    end
    local hSegs = D.mergeCollinear(
        D.filter(segs, function(s) return s.horizontal end),
        maxGap,
        3 * maxGap,
        function(o, a, b) return paperRun(true, o, a, b) end
    )
    local vSegs = D.mergeCollinear(
        D.filter(segs, function(s) return not s.horizontal end),
        maxGap,
        3 * maxGap,
        function(o, a, b) return paperRun(false, o, a, b) end
    )

    -- 3) guillotine
    local leaves = {}
    local ctx = {
        paper = paper,
        maxGap = maxGap,
        strict = strict,
        w = w,
        h = h,
        hSegs = hSegs,
        vSegs = vSegs,
        minPiece = D.round(dim * 0.09),
        captionMax = D.round(dim * 0.12),
        near = math.max(3, D.round(dim * 0.02)),
        log = nil,
    }
    D.guillotine(start, ctx, 0, leaves)

    -- 4) fit to the drawing
    local rects = {}
    for k = 1, #leaves do
        local r = D.shrinkToInk(paper, w, leaves[k])
        if r then rects[#rects + 1] = r end
    end
    rects = D.filter(rects, D.isPanelSized(w, h))
    local valid = #rects >= 2
    return {
        rects = valid and rects or {},
        bbox = start,
        text = false,
        style = "dense",
        gutter = gutter,
    }
end

return D
