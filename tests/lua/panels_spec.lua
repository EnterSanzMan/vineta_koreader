-- Tests of vineta_panels.lua (pure logic). Run with LuaJIT from the repo root:
--   luajit tests/lua/panels_spec.lua
package.path = "vineta.koplugin/?.lua;" .. package.path
local Panels = require("vineta_panels")

local failures, count = 0, 0
local function test(name, fn)
    count = count + 1
    local ok, err = pcall(fn)
    if ok then
        print("ok   " .. name)
    else
        failures = failures + 1
        print("FAIL " .. name .. "\n     " .. tostring(err))
    end
end

local function eq(a, b, msg)
    if a ~= b then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end
local function near(a, b, msg)
    if math.abs(a - b) > 1e-6 then error((msg or "") .. " expected " .. tostring(b) .. ", got " .. tostring(a), 2) end
end

-- Detections as the runner gives them (rects normalised to the page).
local function sample()
    return {
        pages = {
            [1] = Panels.entry{ kind = "comic",
                ltr = { { x = 0, y = 0, w = 0.5, h = 0.5 }, { x = 0.5, y = 0, w = 0.5, h = 0.5 } },
                rtl = { { x = 0.5, y = 0, w = 0.5, h = 0.5 }, { x = 0, y = 0, w = 0.5, h = 0.5 } } },
            [2] = Panels.entry{ kind = "text", ltr = { { x = 0, y = 0, w = 1, h = 1 } } },
            [3] = Panels.entry{ kind = "single", ltr = { { x = 0, y = 0, w = 1, h = 1 } } },
            -- page 4: not detected yet
            [5] = Panels.entry{ kind = "error" },
        },
    }
end

local native = { w = 500, h = 1000 }
local noMargin = { margin = 0, max_zoom = 4 }

test("the whole page comes first, then the panels in native units", function()
    local s = Panels.steps(sample(), 1, native, false, noMargin)
    eq(#s, 3)
    assert(s[1].full); near(s[1].w, 500); near(s[1].h, 1000)
    near(s[2].x, 0); near(s[2].w, 250); near(s[2].h, 500)
    near(s[3].x, 250)
end)

test("manga order uses rtl", function()
    local s = Panels.steps(sample(), 1, native, true, noMargin)
    assert(s[1].full)
    near(s[2].x, 250)
end)

-- 1264×1680 screen: the whole 500×1000 page fits at 1.68, i.e. 840 px wide.
local screen = { margin = 0, max_zoom = 4, split = 1.2, screen_w = 1264, screen_h = 1680 }

test("a wide strip that would not get 20 % wider goes in two halves", function()
    local m = { pages = {
        -- full-width strip of 25 % of the height: fits by width at 1264 / 500 = 2.53 (1.5× the page): not split;
        -- half-width panel of 75 % of the height: 1680 / 750 = 2.24 (1.33×): not split
        [1] = Panels.entry{ kind = "comic", ltr = { { x = 0, y = 0, w = 1, h = 0.25 }, { x = 0, y = 0.25, w = 0.5, h = 0.75 } } },
        -- full-width panel of 90 % of the height: 1680 / 900 = 1.87 (1.11×): split;
        -- strip of 10 %: 2.53 (1.5×): not split
        [2] = Panels.entry{ kind = "comic", ltr = { { x = 0, y = 0, w = 1, h = 0.9 }, { x = 0, y = 0.9, w = 1, h = 0.1 } } },
    } }
    local s = Panels.steps(m, 1, native, false, screen)
    eq(#s, 3) -- whole page + 2 panels, none split
    s = Panels.steps(m, 2, native, false, screen)
    eq(#s, 4) -- whole page + 2 halves + strip
    eq(s[2].half, "left"); near(s[2].x, 0); near(s[2].w, 250); near(s[2].h, 900)
    eq(s[3].half, "right"); near(s[3].x, 250); near(s[3].w, 250)
    eq(s[4].half, nil)
    -- manga: right half first
    s = Panels.steps(m, 2, native, true, screen)
    eq(s[2].half, "right"); eq(s[3].half, "left")
    -- without the screen size nothing is split
    eq(#Panels.steps(m, 2, native, false, noMargin), 3)
end)

test("text, whole-page, error and pending pages are one full page", function()
    local m = sample()
    for _, page in ipairs({ 2, 3, 4, 5 }) do -- no panels: only the whole page
        local s = Panels.steps(m, page, native, false, noMargin)
        eq(#s, 1, "page " .. page); assert(s[1].full); near(s[1].w, 500)
        eq(s[1].pending, page == 4, "pending page " .. page)
    end
end)

test("margin grows the panel and stays inside the page", function()
    local s = Panels.steps(sample(), 1, native, false, { margin = 0.02 })
    near(s[2].x, 0) -- clipped at the left edge
    near(s[3].x, 250 - 10)
    near(s[3].w, 250 + 10) -- clipped at the right edge
end)

test("entry() drops bad rectangles and clips the rest", function()
    local e = Panels.entry{ kind = "comic", ltr = { { x = 0, y = 0, w = 0, h = 0.1 }, { x = "a" }, { x = 0.9, y = 0.9, w = 0.5, h = 0.5 } } }
    eq(#e.ltr, 1)
    near(e.ltr[1].w, 0.1)
    eq(e.rtl, e.ltr) -- no rtl list: same order
    eq(Panels.entry(nil), nil)
    eq(Panels.entry{ kind = 3 }, nil)
end)

test("zoom fits the panel and is capped at max_zoom times the page", function()
    -- 1264×1680 screen; the whole 500×1000 page fits at 1.68
    local z = Panels.zoom(native, { x = 0, y = 0, w = 250, h = 500 }, 1264, 1680, noMargin)
    near(z, math.min(1264 / 250, 1680 / 500))
    z = Panels.zoom(native, { x = 0, y = 0, w = 10, h = 10 }, 1264, 1680, noMargin)
    near(z, 4 * 1.68)
    -- a full page is never capped
    z = Panels.zoom(native, { x = 0, y = 0, w = 500, h = 1000, full = true }, 5000, 10000, { max_zoom = 1 })
    near(z, 10)
end)

test("navigator walks panels and pages", function()
    local m = sample()
    local nav = Panels.navigator(3, function(p) return Panels.steps(m, p, native, false, noMargin) end, 1, 1)
    eq(nav:next(), "step"); eq(nav.index, 2) -- whole page → first panel
    eq(nav:next(), "step"); eq(nav.index, 3)
    eq(nav:next(), "page"); eq(nav.page, 2); eq(nav.index, 1)
    eq(nav:next(), "page"); eq(nav.page, 3)
    eq(nav:next(), "end"); eq(nav.page, 3)
    eq(nav:prev(), "page"); eq(nav.page, 2)
    eq(nav:prev(), "page"); eq(nav.page, 1); eq(nav.index, 3) -- back to the LAST panel
    eq(nav:prev(), "step"); eq(nav.index, 2)
    eq(nav:prev(), "step"); eq(nav.index, 1) -- the whole page
    eq(nav:prev(), "start")
end)

test("navigator clamps a saved position", function()
    local m = sample()
    local nav = Panels.navigator(3, function(p) return Panels.steps(m, p, native, false, noMargin) end, 9, 7)
    eq(nav.page, 3); eq(nav.index, 1)
    nav:jump(1, 99); eq(nav.index, 3)
    nav:jump(1, "last"); eq(nav.index, 3)
end)

test("a pending page gets its panels once detected", function()
    local m = sample()
    local nav = Panels.navigator(5, function(p) return Panels.steps(m, p, native, false, noMargin) end, 4, 1)
    assert(nav:pending())
    m.pages[4] = Panels.entry{ kind = "comic", ltr = { { x = 0, y = 0, w = 1, h = 0.5 }, { x = 0, y = 0.5, w = 1, h = 0.5 } } }
    assert(nav:pending()) -- steps are cached until forgotten
    nav:forget(4)
    assert(not nav:pending())
    eq(#nav:steps(4), 3)
end)

test("without overview the page starts at its first panel", function()
    local o = { margin = 0, max_zoom = 4, overview = false }
    local s = Panels.steps(sample(), 1, native, false, o)
    eq(#s, 2); assert(not s[1].full); near(s[1].w, 250)
    -- pages without panels are still the whole page
    s = Panels.steps(sample(), 3, native, false, o)
    eq(#s, 1); assert(s[1].full)
end)

test("split off: big panels stay whole", function()
    local m = { pages = { [1] = Panels.entry{ kind = "comic", ltr = { { x = 0, y = 0, w = 1, h = 0.9 } } } } }
    local o = { margin = 0, max_zoom = 4, screen_w = 1264, screen_h = 1680 } -- split = nil
    eq(#Panels.steps(m, 1, native, false, o), 2)
    o.split = 1.1 -- 1.87 / 1.68 = 1.11: just enough, not split
    eq(#Panels.steps(m, 1, native, false, o), 2)
    o.split = 1.5
    eq(#Panels.steps(m, 1, native, false, o), 3)
end)

test("a double page shows each half before its panels", function()
    local wide = { w = 2000, h = 1400 }
    local m = { pages = { [1] = Panels.entry{ kind = "comic",
        ltr = { { x = 0.05, y = 0.1, w = 0.4, h = 0.4 }, { x = 0.05, y = 0.5, w = 0.4, h = 0.4 }, { x = 0.55, y = 0.1, w = 0.4, h = 0.8 } },
        rtl = { { x = 0.55, y = 0.1, w = 0.4, h = 0.8 }, { x = 0.05, y = 0.1, w = 0.4, h = 0.4 }, { x = 0.05, y = 0.5, w = 0.4, h = 0.4 } } } } }
    local o = { margin = 0, max_zoom = 4, spreads = true, screen_w = 1264, screen_h = 1680 }
    local s = Panels.steps(m, 1, wide, false, o)
    eq(#s, 6) -- whole, left half, 2 panels, right half, 1 panel
    assert(s[1].full)
    eq(s[2].spread, "left"); near(s[2].x, 0); near(s[2].w, 1000)
    eq(s[5].spread, "right"); near(s[5].x, 1000)
    s = Panels.steps(m, 1, wide, true, o) -- manga: right half first
    eq(s[2].spread, "right"); eq(s[4].spread, "left")
    o.spreads = false
    eq(#Panels.steps(m, 1, wide, false, o), 4)
    -- a panel across the middle: not treated as a double page
    m.pages[2] = Panels.entry{ kind = "comic", ltr = { { x = 0.1, y = 0, w = 0.8, h = 0.5 }, { x = 0.1, y = 0.5, w = 0.3, h = 0.5 } } }
    o.spreads = true
    for _, st in ipairs(Panels.steps(m, 2, wide, false, o)) do eq(st.spread, nil) end
    -- portrait page: never
    for _, st in ipairs(Panels.steps(m, 1, native, false, o)) do eq(st.spread, nil) end
end)

test("balloons follow very wide panels, in reading order", function()
    local b = { ltr = { { x = 0.1, y = 0.2, w = 0.2, h = 0.3 }, { x = 0.7, y = 0.2, w = 0.2, h = 0.3 } },
                rtl = { { x = 0.7, y = 0.2, w = 0.2, h = 0.3 }, { x = 0.1, y = 0.2, w = 0.2, h = 0.3 } } }
    local m = { pages = { [1] = Panels.entry{ kind = "comic", balloons = true,
        -- strip 500×200 (aspect 2.5 vs the screen's 0.75: ratio 3.3) and a squarer panel
        ltr = { { x = 0, y = 0, w = 1, h = 0.2, balloons = b }, { x = 0, y = 0.2, w = 1, h = 0.8, balloons = b } } } } }
    local o = { margin = 0, max_zoom = 4, balloons = true, screen_w = 1264, screen_h = 1680 }
    local s = Panels.steps(m, 1, native, false, o)
    eq(#s, 5) -- whole, strip, 2 balloons, panel (its shape is close to the screen's: no balloons)
    assert(s[3].balloon and s[4].balloon)
    -- first balloon: 100×60 at (50, 40), padded by 15 % of 100
    near(s[3].x, 50 - 15); near(s[3].y, 40 - 15); near(s[3].w, 130); near(s[3].h, 90)
    near(s[4].x, 350 - 15)
    s = Panels.steps(m, 1, native, true, o) -- manga order (rtl list shared from ltr)
    near(s[3].x, 350 - 15)
    o.balloons = false
    eq(#Panels.steps(m, 1, native, false, o), 3)
end)

test("a single-panel page zooms to the balloons of the whole page", function()
    local m = { pages = { [1] = Panels.entry{ kind = "single", balloons = true, ltr = { { x = 0, y = 0, w = 1, h = 1 } },
        page_balloons = { ltr = { { x = 0.1, y = 0.1, w = 0.2, h = 0.1 } } } } } }
    assert(Panels.isWholePage(m.pages[1]))
    local o = { margin = 0, max_zoom = 4, balloons = true, screen_w = 1264, screen_h = 1680 }
    local s = Panels.steps(m, 1, native, false, o)
    eq(#s, 2); assert(s[1].full); assert(s[2].balloon)
    o.overview = false -- the whole page stays: it is the only "panel"
    eq(#Panels.steps(m, 1, native, false, o), 2)
end)

test("entry() keeps balloons and shares them with the manga order", function()
    local b = { ltr = { { x = 0.1, y = 0.1, w = 0.2, h = 0.2 }, { x = "bad" } } }
    local e = Panels.entry{ kind = "comic", balloons = true,
        ltr = { { x = 0, y = 0, w = 0.5, h = 1, balloons = b }, { x = 0.5, y = 0, w = 0.5, h = 1 } },
        rtl = { { x = 0.5, y = 0, w = 0.5, h = 1 }, { x = 0, y = 0, w = 0.5, h = 1 } } }
    eq(e.balloons, true)
    eq(#e.ltr[1].balloons.ltr, 1)
    eq(e.ltr[1].balloons.rtl, e.ltr[1].balloons.ltr) -- no rtl order: same
    eq(e.ltr[2].balloons, nil)
    eq(e.rtl[2].balloons, e.ltr[1].balloons)
    eq(e.rtl[1].balloons, nil)
    eq(Panels.entry{ kind = "comic", ltr = {} }.balloons, nil)
end)

test("wantsBalloons compares the panel's shape with the screen's", function()
    local scr = { 1264, 1680 }
    assert(Panels.wantsBalloons({ x = 0, y = 0, w = 1, h = 0.2 }, native, scr[1], scr[2]))
    assert(not Panels.wantsBalloons({ x = 0, y = 0, w = 1, h = 1 }, native, scr[1], scr[2])) -- 0.5 vs 0.75
    assert(Panels.wantsBalloons({ x = 0, y = 0, w = 0.2, h = 1 }, native, scr[1], scr[2])) -- 0.1 vs 0.75
end)

print(("%d tests, %d failures"):format(count, failures))
os.exit(failures == 0 and 0 or 1)
