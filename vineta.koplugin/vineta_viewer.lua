--[[--
Full-screen widget that shows one panel (or the whole page) at a time.

It sits on top of the normal reader: when the step changes to another page the
reader is moved there too (GotoPage), so KOReader keeps saving the position,
the statistics and the progress as usual.
]]

local Blitbuffer = require("ffi/blitbuffer")
local ButtonDialog = require("ui/widget/buttondialog")
local CenterContainer = require("ui/widget/container/centercontainer")
local Device = require("device")
local Event = require("ui/event")
local FrameContainer = require("ui/widget/container/framecontainer")
local Geom = require("ui/geometry")
local GestureRange = require("ui/gesturerange")
local ImageWidget = require("ui/widget/imagewidget")
local InputContainer = require("ui/widget/container/inputcontainer")
local UIManager = require("ui/uimanager")
local Font = require("ui/font")
local Notification = require("ui/widget/notification")
local OverlapGroup = require("ui/widget/overlapgroup")
local Size = require("ui/size")
local TextWidget = require("ui/widget/textwidget")
local logger = require("logger")
local Panels = require("vineta_panels")
local Screen = Device.screen

local PanelViewer = InputContainer:extend{
    -- set by the caller
    ui = nil,
    model = nil,        -- { pages = { [page] = entry } } (see vineta_panels); pages without entry are pending
    request = nil,      -- function(page, urgent): asks for the detection of a page
    rtl = false,
    opts = nil,         -- Panels.defaults plus refresh_every (-1: full refresh on each new page),
                        -- prefetch (pages detected ahead), gamma (minimum contrast), indicator
    page = 1,
    index = 1,
    on_close = nil,     -- function(viewer) called after closing

    covers_fullscreen = true, -- hint for UIManager:_repaint()
    dithered = true,          -- comic art: ask for dithered refreshes
    _whole_page = false,      -- long press: show the whole page of the current step
    _since_full = 0,          -- image changes since the last full refresh
}

function PanelViewer:init()
    self.document = self.ui.document
    self.opts = self.opts or Panels.defaults
    self.dimen = Geom:new{ x = 0, y = 0, w = Screen:getWidth(), h = Screen:getHeight() }

    if Device:hasKeys() then
        self.key_events = {
            Next = { { Device.input.group.PgFwd } },
            Prev = { { Device.input.group.PgBack } },
            ExitPanelMode = { { Device.input.group.Back } },
        }
    end
    if Device:isTouchDevice() then
        local range = Geom:new{ x = 0, y = 0, w = self.dimen.w, h = self.dimen.h }
        self.ges_events = {
            Tap = { GestureRange:new{ ges = "tap", range = range } },
            Hold = { GestureRange:new{ ges = "hold", range = range } },
            Swipe = { GestureRange:new{ ges = "swipe", range = range } },
        }
    end

    self:makeNavigator()
    self:renderStep(true) -- onShow does the first (full) refresh
end

function PanelViewer:makeNavigator()
    local doc = self.document
    -- Panels.steps needs the screen size to decide which panels go in two halves.
    self.opts.screen_w, self.opts.screen_h = self.dimen.w, self.dimen.h
    self.nav = Panels.navigator(doc:getPageCount(), function(page)
        return Panels.steps(self.model, page, doc:getNativePageDimensions(page), self.rtl, self.opts)
    end, self.page, self.index)
end

-- Builds the image of the current step and puts it on screen.
function PanelViewer:renderStep(no_refresh)
    local page = self.nav.page
    local native = self.document:getNativePageDimensions(page)
    local rect = self.nav:current()
    if self._whole_page then
        rect = { x = 0, y = 0, w = native.w, h = native.h, full = true }
    end
    local zoom = Panels.zoom(native, rect, self.dimen.w, self.dimen.h, self.opts)
    local grect = Geom:new{ x = rect.x, y = rect.y, w = rect.w, h = rect.h }
    -- Same trick as Document:drawPagePart(): with scaled_rect, renderPage only renders that part.
    grect.scaled_rect = self.document:transformRect(grect, zoom, 0)
    local gamma = self.ui.view and self.ui.view.state and self.ui.view.state.gamma or 1.0
    -- «Más contraste»: colour pages come out washed out in 16 greys.
    if self.opts.gamma and self.opts.gamma > gamma then gamma = self.opts.gamma end
    local ok, tile = pcall(self.document.renderPage, self.document, page, grect, zoom, 0, gamma, 1.0, true)

    local bb
    if ok and tile and tile.bb then
        -- Copy: the tile belongs to the document cache, which may drop it while we show it.
        bb = tile.bb:copy()
    else
        logger.warn("Vineta: could not render page", page, tile)
        bb = Blitbuffer.new(1, 1, Screen.bb:getType())
        bb:fill(Blitbuffer.COLOR_WHITE)
    end
    -- We own the bitmap (image_disposable = false): free the previous one ourselves.
    self:freeImage()
    self.bb = bb
    self.image_widget = ImageWidget:new{
        image = bb,
        image_disposable = false,
        original_in_nightmode = false, -- follow night mode like the reader does
    }
    local content = CenterContainer:new{
        dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h },
        self.image_widget,
    }
    self._overlap = nil
    if self.opts.indicator ~= false then
        content = OverlapGroup:new{
            dimen = Geom:new{ w = self.dimen.w, h = self.dimen.h },
            content,
            self:indicator(),
        }
        self._overlap = content
    end
    self[1] = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = 0,
        padding = 0,
        margin = 0,
        content,
    }
    local page_changed = self._shown_page ~= page
    self._shown_page = page
    if not no_refresh then self:refresh(page_changed) end
    self:askDetections()
end

-- Small «step / steps» label in the bottom right corner.
function PanelViewer:indicator()
    local n = #self.nav:steps(self.nav.page)
    local label = self.nav:pending() and "…" or ("%d/%d"):format(self.nav.index, n)
    local frame = FrameContainer:new{
        background = Blitbuffer.COLOR_WHITE,
        bordersize = Size.border.thin,
        padding = Size.padding.small,
        padding_top = 0,
        padding_bottom = 0,
        margin = 0,
        TextWidget:new{ text = label, face = Font:getFace("ffont", 14) },
    }
    local fs = frame:getSize()
    frame.overlap_offset = { self.dimen.w - fs.w - Size.margin.small, self.dimen.h - fs.h - Size.margin.small }
    return frame
end

-- Redraws only the indicator (the picture on screen does not change).
function PanelViewer:updateIndicator()
    local group = self._overlap
    if not group then return end
    local old = group[2]
    local new = self:indicator()
    group[2] = new
    local function area(w)
        local sz = w:getSize()
        return Geom:new{ x = w.overlap_offset[1], y = w.overlap_offset[2], w = sz.w, h = sz.h }
    end
    local region = area(old):combine(area(new))
    old:free()
    UIManager:setDirty(self, function() return "ui", region end)
end

-- The current page first (if it is not detected yet), then the next ones.
function PanelViewer:askDetections()
    if not self.request then return end
    local page = self.nav.page
    if not self:isDetected(page) then self.request(page, true) end
    local ahead = math.min(self.opts.prefetch or 2, self.nav.page_count - page)
    for i = 1, ahead do
        local p = page + i
        if not self:isDetected(p) then self.request(p, false) end
    end
end

-- True if the page has an up to date detection (with balloons, if they are wanted).
function PanelViewer:isDetected(page)
    local e = self.model and self.model.pages[page]
    if not e then return false end
    if self.opts.balloons and e.kind ~= "error" and not e.balloons then return false end
    return true
end

-- Called by the plugin when a page has been detected.
function PanelViewer:onDetected(page)
    local current = page == self.nav.page
    local was_pending = current and self.nav:pending()
    self.nav:forget(page)
    if not was_pending then return end
    -- The whole page (first step) is on screen. Stay there, unless the user already
    -- asked for the next step (go to the first panel) or came back from the next page
    -- (go to the last panel).
    local target = 1
    if self._arrived_back then
        target = "last"
    elseif self._waiting then
        target = 2
    end
    self._waiting = false
    self.nav:jump(page, target)
    if target ~= 1 and not self._whole_page then
        self:renderStep()
    else
        self:updateIndicator() -- «…» becomes «1/N»
    end
end

function PanelViewer:notifyWaiting()
    Notification:notify("Buscando viñetas…")
end

function PanelViewer:refresh(page_changed)
    local every = self.opts.refresh_every or 8
    self._since_full = self._since_full + 1
    local mode = "partial"
    if (every > 0 and self._since_full >= every) or (every < 0 and page_changed) then
        mode = "full"
        self._since_full = 0
    end
    UIManager:setDirty(self, function()
        return mode, self.dimen, true -- dithered: comic art
    end)
end

function PanelViewer:onShow()
    self._since_full = 0
    UIManager:setDirty(self, function()
        return "full", self.dimen, true
    end)
    return true
end

-- Keeps the reader underneath on the page we are showing.
function PanelViewer:syncReader()
    if self.ui.paging and self.ui.paging.current_page ~= self.nav.page then
        self.ui:handleEvent(Event:new("GotoPage", self.nav.page))
    end
end

function PanelViewer:onNext()
    self._whole_page = false
    if self.nav:pending() and not self._waiting then
        -- First tap on a page still being detected: wait for its panels.
        self._waiting = true
        self:notifyWaiting()
        return true
    end
    self._waiting = false
    local res = self.nav:next()
    if res == "end" then
        -- Not the user's choice to leave the mode: reopening the book starts in panel mode again.
        UIManager:close(self, "full")
        self.ui:handleEvent(Event:new("EndOfBook"))
        return true
    end
    if res == "page" then
        self._arrived_back = false
        self:syncReader()
    end
    self:renderStep()
    return true
end

function PanelViewer:onPrev()
    self._whole_page = false
    self._waiting = false
    local res = self.nav:prev()
    if res == "start" then return true end
    if res == "page" then
        self._arrived_back = true
        self:syncReader()
    end
    self:renderStep()
    return true
end

-- Taps: 30 % on each side turn, the middle opens the menu. In manga mode the sides swap.
function PanelViewer:onTap(_, ges)
    local x = ges.pos.x / self.dimen.w
    local y = ges.pos.y / self.dimen.h
    local forward, backward = x >= 0.7, x < 0.3
    if self.rtl then forward, backward = backward, forward end
    if y < 0.15 or not (forward or backward) then
        self:showMenu()
    elseif forward then
        self:onNext()
    else
        self:onPrev()
    end
    return true
end

function PanelViewer:onSwipe(_, ges)
    local dir = ges.direction
    local forward = dir == "west"
    local backward = dir == "east"
    if self.rtl then forward, backward = backward, forward end
    if forward then return self:onNext() end
    if backward then return self:onPrev() end
    return false
end

-- Long press: whole page ↔ current panel.
function PanelViewer:onHold()
    self._whole_page = not self._whole_page
    self:renderStep()
    return true
end

-- keep: stay on the current step number (used when the direction comes from ComicInfo.xml).
function PanelViewer:setRtl(rtl, keep)
    self.rtl = rtl
    self.nav:reset()
    if not keep then self.nav.index = 1 end
    self:renderStep()
end

function PanelViewer:showMenu()
    local dialog
    dialog = ButtonDialog:new{
        title = ("Página %d de %d · paso %d de %d"):format(
            self.nav.page, self.nav.page_count, self.nav.index, #self.nav:steps(self.nav.page)),
        buttons = {
            { {
                text = self.rtl and "Sentido: manga (derecha a izquierda)" or "Sentido: occidental (izquierda a derecha)",
                callback = function()
                    UIManager:close(dialog)
                    self.rtl_user = true
                    self:setRtl(not self.rtl)
                end,
            } },
            { {
                text = self._whole_page and "Volver a la viñeta" or "Ver la página completa",
                callback = function()
                    UIManager:close(dialog)
                    self:onHold()
                end,
            } },
            { {
                text = "Salir del modo viñeta",
                callback = function()
                    UIManager:close(dialog)
                    self:onExitPanelMode()
                end,
            } },
        },
    }
    UIManager:show(dialog)
end

-- Left by the user (menu, Back key, toggle, end of the book).
function PanelViewer:onExitPanelMode()
    self.user_exit = true
    UIManager:close(self, "full")
    return true
end

-- KOReader broadcasts "Close" to every widget when it quits, goes to USB mode or
-- powers off: close without marking it as the user's choice.
function PanelViewer:onClose()
    UIManager:close(self)
end

function PanelViewer:freeImage()
    if self.image_widget then
        self.image_widget:free()
        self.image_widget = nil
    end
    if self.bb then
        self.bb:free()
        self.bb = nil
    end
end

function PanelViewer:onCloseWidget()
    self:freeImage()
    if self.on_close then self.on_close(self) end
end

return PanelViewer
