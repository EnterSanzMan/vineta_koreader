--[[--
Viñeta's panel detector in Lua (port of panels-core.js, Viñeta 3.6.1).

    local Detect = require("vineta_detect")
    local r = Detect.detectImage(rgba, w, h)  -- rgba: uint8_t* w×h×4 (R, G, B, A)
    -- r = { kind = "comic"|"single"|"text", style = …, panels = {{x,y,w,h}…}, panelsRtl = {…} }
    -- rects normalised to 0..1, in reading order.

Pure LuaJIT (no KOReader modules), so the tests run it with a plain luajit.
]]

local D = require("vineta_detect_base")
require("vineta_detect_a")
require("vineta_detect_b")
require("vineta_detect_c")
require("vineta_detect_d")

-- Bump when the port or its input changes: cached results of older versions are dropped.
D.VERSION = "3.6.1-lua1"

local DISPLAY_MAX = 3000 -- processPage's displayMax in Viñeta

-- Size the page is analysed at: the long side is DETECT_MAX, the other keeps the
-- aspect ratio (as processPage does for any page larger than DETECT_MAX).
function D.analysisSize(w, h)
    local ak = D.DETECT_MAX / math.max(w, h)
    return math.max(8, D.round(w * ak)), math.max(8, D.round(h * ak))
end

-- Same steps as tools/panels/detect.mjs (processPage + analysisImage of the app):
-- box-filter the page to aw×ah and to 2aw×2ah, paper maps, negative, detectPanels.
-- rgba: 0-based uint8_t array (or pointer) of iw×ih×4 bytes.
-- opts.aw, opts.ah: analysis size (default: D.analysisSize(iw, ih) capped to the image).
-- opts.bgr: the bytes are B, G, R, A.
function D.detectImage(rgba, iw, ih, opts)
    opts = opts or {}
    local aw, ah = opts.aw, opts.ah
    if not aw then
        -- detect.mjs / processPage: the page is first sized to the display size (long side
        -- ≤ 3000, rounded), then to the analysis size; never larger than the image itself.
        local k = math.min(1, DISPLAY_MAX / math.max(iw, ih))
        local dw, dh = D.round(iw * k), D.round(ih * k)
        local ak = math.min(1, D.DETECT_MAX / math.max(dw, dh))
        aw = math.max(8, D.round(dw * ak))
        ah = math.max(8, D.round(dh * ak))
    end
    D.adopt(rgba, iw * ih * 4)

    local W, H = aw * 2, ah * 2
    local sum = D.u32(W * H * 3)
    local cnt = D.u16(W * H)
    local sum1 = D.u32(aw * ah * 3)
    local cnt1 = D.u16(aw * ah)
    D.boxAccumulate(sum, cnt, rgba, iw, ih, W, H, 0, ih)
    D.boxAccumulate(sum1, cnt1, rgba, iw, ih, aw, ah, 0, ih)
    local big = D.boxFinish(sum, cnt, W, H)
    local data = D.boxFinish(sum1, cnt1, aw, ah)
    sum, cnt, sum1, cnt1 = nil, nil, nil, nil
    if opts.bgr then
        for _, a in ipairs({ big, data }) do
            for i = 0, D.len(a) - 1, 4 do
                a[i], a[i + 2] = a[i + 2], a[i]
            end
        end
    end
    local maps = D.paperMaps(big, W, H)
    local neg = D.negativeOf(data, big, aw, ah)
    big = nil

    local r = D.detectPanels(data, aw, ah, {
        rtl = false, style = opts.style or "auto", hi = maps.hi, hiLuma = maps.hiLuma, neg = neg,
    })
    return {
        kind = r.kind,
        style = r.style,
        panels = r.panels,
        panelsRtl = r.panelsRtl or r.panels,
        aw = aw,
        ah = ah,
    }
end

-- Speech balloons of a panel (detectBalloons of panels-core.js), in both reading orders.
-- rgba: the panel, iw×ih×4 bytes (see D.balloonSize). whole: the image is a whole page
-- (a single-panel page), where balloons are smaller relative to it.
-- Returns { ltr = {rects}, rtl = {rects} } normalised to the image.
function D.detectBalloonsBoth(rgba, iw, ih, whole)
    D.adopt(rgba, iw * ih * 4)
    local found = D.findBalloons(rgba, iw, ih, whole and D.BALLOON_PAGE or D.BALLOON_PANEL, nil)
    local function norm(list)
        local out = {}
        for i, r in ipairs(list) do
            out[i] = { x = r.x0 / iw, y = r.y0 / ih, w = (r.x1 - r.x0) / iw, h = (r.y1 - r.y0) / ih }
        end
        return out
    end
    return { ltr = norm(D.orderRects(found, false)), rtl = norm(D.orderRects(found, true)) }
end

-- Size a panel of pw×ph pixels is analysed at for its balloons, as Viñeta's reader does:
-- long side 800, but at least 0.48 Mpx (wide strips), never enlarged.
function D.balloonSize(pw, ph)
    local k = 800 / math.max(pw, ph)
    if pw * k * ph * k < 480000 then k = math.sqrt(480000 / (pw * ph)) end
    k = math.min(1, k)
    return math.max(8, D.round(pw * k)), math.max(8, D.round(ph * k))
end

return D
