--[[--
Pure logic of the panel-by-panel reader: turns the detected panels of a page
into a list of "steps" (rectangles in document native units) and walks through
them. No KOReader requires here, so it can be tested with plain LuaJIT.

The detections come from vineta_runner: model.pages[page] is
    { kind = "comic"|"single"|"text"|"error", ltr = {rects}, rtl = {rects},
      balloons = true|nil, page_balloons = { ltr = {rects}, rtl = {rects} }|nil }
with rects normalised to the page (0..1). A panel rect may carry its speech balloons,
normalised to the panel: rect.balloons = { ltr = {rects}, rtl = {rects} }.
A page with no entry yet is pending. Page numbers are 1-based, like KOReader.
]]

local Panels = {}

Panels.defaults = {
    margin = 0.02,    -- context around each panel, fraction of the page's shorter side
    max_zoom = 4,     -- a panel is never magnified more than this many times the whole page
    split = 1.2,      -- panels that would not get 20 % wider than in the whole page go in two halves (nil: never)
    overview = true,  -- each page starts with the whole page
    balloons = false, -- zoom to the speech balloons of some panels (see Panels.wantsBalloons)
    spreads = true,   -- landscape pages (double pages): show each half before its panels
}

-- A panel gets balloon steps when its shape is this many times wider or taller than
-- the screen (its text ends up small), as in Viñeta's «zoom a diálogos».
Panels.BALLOON_RATIO = 1.8

local function isNumber(v)
    return type(v) == "number" and v == v and v ~= math.huge and v ~= -math.huge
end

-- Keeps the rectangles that make sense inside the unit square, clipped to it.
local function sanitize(list, min)
    if type(list) ~= "table" then return nil end
    min = min or 0.005
    local out = {}
    for _, r in ipairs(list) do
        if type(r) == "table" and isNumber(r.x) and isNumber(r.y) and isNumber(r.w) and isNumber(r.h) then
            local x0, y0 = math.max(0, r.x), math.max(0, r.y)
            local x1, y1 = math.min(1, r.x + r.w), math.min(1, r.y + r.h)
            if x1 - x0 > min and y1 - y0 > min then
                out[#out + 1] = { x = x0, y = y0, w = x1 - x0, h = y1 - y0, balloons = r.balloons }
            end
        end
    end
    return out
end

local function sanitizeBalloons(b)
    if type(b) ~= "table" then return nil end
    local ltr = sanitize(b.ltr, 0.002)
    if not ltr then return nil end
    for _, r in ipairs(ltr) do r.balloons = nil end
    local rtl = sanitize(b.rtl, 0.002) or ltr
    for _, r in ipairs(rtl) do r.balloons = nil end
    return { ltr = ltr, rtl = rtl }
end

local function sameRect(a, b)
    return math.abs(a.x - b.x) < 1e-6 and math.abs(a.y - b.y) < 1e-6
        and math.abs(a.w - b.w) < 1e-6 and math.abs(a.h - b.h) < 1e-6
end

--- Cleans a detection (from the worker or from the saved cache). Returns the entry or nil.
function Panels.entry(e)
    if type(e) ~= "table" or type(e.kind) ~= "string" then return nil end
    if e.kind == "error" then return { kind = "error" } end
    local ltr = sanitize(e.ltr) or {}
    for _, r in ipairs(ltr) do r.balloons = sanitizeBalloons(r.balloons) end
    local rtl = sanitize(e.rtl) or ltr
    -- The manga list holds the same panels in another order: share their balloons.
    for _, r in ipairs(rtl ~= ltr and rtl or {}) do
        r.balloons = nil
        for _, l in ipairs(ltr) do
            if sameRect(r, l) then r.balloons = l.balloons break end
        end
    end
    return {
        kind = e.kind,
        ltr = ltr,
        rtl = rtl,
        balloons = e.balloons == true or nil, -- balloons were looked for
        page_balloons = sanitizeBalloons(e.page_balloons),
    }
end

--- True if a panel (rect normalised to a native.w × native.h page) gets balloon steps
-- on a screen_w × screen_h screen: its shape is very different from the screen's.
function Panels.wantsBalloons(r, native, screen_w, screen_h)
    local pa = (r.w * native.w) / (r.h * native.h)
    local sa = screen_w / screen_h
    return math.max(pa / sa, sa / pa) >= Panels.BALLOON_RATIO
end

--- True if the page is a single panel or illustration (its balloons are looked for on
-- the whole page).
function Panels.isWholePage(entry)
    if not entry or entry.kind ~= "single" then return false end
    local r = entry.ltr[1]
    return #entry.ltr == 0 or (#entry.ltr == 1 and r.w >= 0.999 and r.h >= 0.999)
end

-- Balloon steps inside the native rect `area` (balloons normalised to it).
local function balloonSteps(out, list, area, native)
    for _, b in ipairs(list) do
        local bx, by = area.x + b.x * area.w, area.y + b.y * area.h
        local bw, bh = b.w * area.w, b.h * area.h
        local pad = 0.15 * math.max(bw, bh) -- some drawing around the balloon
        local x0, y0 = math.max(0, bx - pad), math.max(0, by - pad)
        local x1, y1 = math.min(native.w, bx + bw + pad), math.min(native.h, by + bh + pad)
        out[#out + 1] = { x = x0, y = y0, w = x1 - x0, h = y1 - y0, balloon = true }
    end
end

--- Steps of a page: list of rectangles in native units ({x, y, w, h}).
-- native: { w, h } of the page as the document reports it.
--  1. The whole page (full = true), if opts.overview.
--  2. The panels in reading order. A panel that would not get at least opts.split
--     times wider on screen than in the whole page becomes two halves: left then
--     right (right then left in manga). That needs opts.screen_w / screen_h.
--  3. With opts.balloons, after a panel whose shape is very different from the
--     screen's (Panels.wantsBalloons), its speech balloons one by one. On a page that is
--     a single panel, the balloons of the whole page.
--  4. On a landscape page (a double page) with opts.spreads, each half of the page
--     before its panels, if no panel crosses the middle.
-- A page without panels is only the whole page; while the page is not detected yet,
-- that step has pending = true.
function Panels.steps(model, page, native, rtl, opts)
    opts = opts or Panels.defaults
    local entry = model and model.pages[page]
    local whole = { x = 0, y = 0, w = native.w, h = native.h, full = true, pending = entry == nil }
    if not entry or entry.kind == "text" or entry.kind == "error" then return { whole } end
    local sw, sh = opts.screen_w, opts.screen_h
    local out = {}
    if opts.overview ~= false then out[1] = whole end

    if Panels.isWholePage(entry) then
        if #out == 0 then out[1] = whole end
        local pb = entry.page_balloons
        if opts.balloons and pb then balloonSteps(out, rtl and pb.rtl or pb.ltr, whole, native) end
        return out
    end

    local list = rtl and entry.rtl or entry.ltr
    local m = (opts.margin or 0) * math.min(native.w, native.h)

    -- Double page: which half each panel is in (nil if one crosses the middle).
    local sides
    if opts.spreads ~= false and native.w > native.h * 1.15 and (not sw or sw < sh) then
        sides = {}
        for i, r in ipairs(list) do
            if r.x < 0.45 and r.x + r.w > 0.55 then sides = nil break end
            sides[i] = (r.x + r.w / 2 < 0.5) and "left" or "right"
        end
    end
    local last_side

    for i, r in ipairs(list) do
        if r.w >= 0.999 and r.h >= 0.999 then return { whole } end
        if sides and sides[i] ~= last_side then
            last_side = sides[i]
            local hx = last_side == "left" and 0 or native.w / 2
            out[#out + 1] = { x = hx, y = 0, w = native.w / 2, h = native.h, spread = last_side }
        end
        local x0 = math.max(0, r.x * native.w - m)
        local y0 = math.max(0, r.y * native.h - m)
        local x1 = math.min(native.w, (r.x + r.w) * native.w + m)
        local y1 = math.min(native.h, (r.y + r.h) * native.h + m)
        local rect = { x = x0, y = y0, w = x1 - x0, h = y1 - y0 }
        local halves = false
        if opts.split and sw and sh then
            local page_fit = math.min(sw / native.w, sh / native.h)
            halves = Panels.zoom(native, rect, sw, sh, opts) < opts.split * page_fit
        end
        if halves then
            local hw = rect.w / 2
            local left = { x = x0, y = y0, w = hw, h = rect.h, half = "left" }
            local right = { x = x0 + hw, y = y0, w = rect.w - hw, h = rect.h, half = "right" }
            if rtl then
                out[#out + 1] = right
                out[#out + 1] = left
            else
                out[#out + 1] = left
                out[#out + 1] = right
            end
        else
            out[#out + 1] = rect
        end
        if opts.balloons and r.balloons and sw and sh and Panels.wantsBalloons(r, native, sw, sh) then
            local area = { x = r.x * native.w, y = r.y * native.h, w = r.w * native.w, h = r.h * native.h }
            balloonSteps(out, rtl and r.balloons.rtl or r.balloons.ltr, area, native)
        end
    end
    if #out == 0 then out[1] = whole end
    return out
end

--- Zoom (screen pixels per native unit) to show rect on a screen_w × screen_h screen:
-- fits it whole, but never more than opts.max_zoom times the zoom of the whole page.
function Panels.zoom(native, rect, screen_w, screen_h, opts)
    opts = opts or Panels.defaults
    local fit = math.min(screen_w / rect.w, screen_h / rect.h)
    if opts.max_zoom and not rect.full then
        local page_fit = math.min(screen_w / native.w, screen_h / native.h)
        fit = math.min(fit, opts.max_zoom * page_fit)
    end
    return fit
end

--- Walks pages and steps. stepsOf(page) returns the steps of that page.
local Navigator = {}
Navigator.__index = Navigator

function Panels.navigator(page_count, stepsOf, page, index)
    local self = setmetatable({ page_count = page_count, stepsOf = stepsOf, cache = {} }, Navigator)
    self:jump(page or 1, index or 1)
    return self
end

function Navigator:steps(page)
    local s = self.cache[page]
    if not s then
        s = self.stepsOf(page)
        self.cache[page] = s
    end
    return s
end

--- Goes to a page; index may be "last". Out of range values are clamped.
function Navigator:jump(page, index)
    self.page = math.max(1, math.min(self.page_count, page))
    local n = #self:steps(self.page)
    if index == "last" then index = n end
    self.index = math.max(1, math.min(n, index or 1))
end

function Navigator:current()
    return self:steps(self.page)[self.index]
end

--- True while the current page has not been detected yet.
function Navigator:pending()
    local s = self:steps(self.page)
    return #s == 1 and s[1].pending == true
end

--- Next step. Returns "step", "page" (moved to another page) or "end".
function Navigator:next()
    if self.index < #self:steps(self.page) then
        self.index = self.index + 1
        return "step"
    end
    if self.page >= self.page_count then return "end" end
    self:jump(self.page + 1, 1)
    return "page"
end

--- Previous step. Returns "step", "page" or "start" (already at the beginning).
function Navigator:prev()
    if self.index > 1 then
        self.index = self.index - 1
        return "step"
    end
    if self.page <= 1 then return "start" end
    self:jump(self.page - 1, "last")
    return "page"
end

--- Forgets the cached steps of one page (it was just detected) or of all of them.
function Navigator:forget(page)
    if page then self.cache[page] = nil else self.cache = {} end
end

--- Forgets cached steps (after changing the reading direction) and stays in range.
function Navigator:reset()
    self.cache = {}
    self:jump(self.page, self.index)
end

return Panels
