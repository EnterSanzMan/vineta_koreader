--[[--
Viñeta a viñeta: guided panel-by-panel reading for comics in KOReader.

Panels are detected on the reader itself with Viñeta's detector (ported to Lua,
vineta_detect*.lua), in a background process (vineta_runner.lua), page by page
as you read. Results are kept in the book's settings, so a comic is only
detected once. The comic file is never modified.

@module koplugin.Vineta
]]

local Dispatcher = require("dispatcher")
local InfoMessage = require("ui/widget/infomessage")
local UIManager = require("ui/uimanager")
local WidgetContainer = require("ui/widget/container/widgetcontainer")
local logger = require("logger")
-- Loaded now: plugin modules are only on package.path while main.lua loads.
local Detect = require("vineta_detect")
local Panels = require("vineta_panels")
local PanelViewer = require("vineta_viewer")
local Runner = require("vineta_runner")
local T = require("vineta_i18n").T

-- Opened in panel mode by default (if the user did not leave it in that book).
local COMIC_TYPES = { cbz = true, cbr = true, cbt = true, cb7 = true, zip = true }
-- Panel mode available from the menu.
local PAGED_TYPES = { cbz = true, cbr = true, cbt = true, cb7 = true, zip = true, pdf = true, xps = true }
-- Archives that may carry a ComicInfo.xml (read with libarchive, like KOReader does).
local META_TYPES = COMIC_TYPES

local Vineta = WidgetContainer:extend{
    name = "vineta",
    is_doc_only = true,
}

local function fileType(path)
    local ext = path:match("%.([^./\\]+)$")
    return ext and ext:lower() or ""
end

function Vineta:init()
    self:onDispatcherRegisterActions()
    self.ui.menu:registerToMainMenu(self)
end

function Vineta:onDispatcherRegisterActions()
    Dispatcher:registerAction("vineta_toggle", {
        category = "none", event = "VinetaToggle", title = T("Viñeta a viñeta"), paging = true,
    })
    Dispatcher:registerAction("vineta_switch", {
        category = "none", event = "VinetaSwitch", title = T("Activar o desactivar Viñeta a viñeta"), paging = true,
    })
end

-- Global on/off switch of the plugin. Off: no panel mode, no detection, nothing opens by itself.
local function isEnabled()
    return G_reader_settings:nilOrTrue("vineta_enabled")
end

-- Global settings (G_reader_settings "vineta_<name>") and their defaults.
local DEFAULTS = {
    autostart = true,
    overview = true,       -- each page starts whole
    split = 1.2,           -- panels that would not get this much wider go in two halves (0: never)
    balloons = false,      -- zoom to the balloons of very wide or very tall panels
    spreads = true,        -- double pages: each half before its panels
    prefetch = 2,          -- pages detected ahead (0: the whole comic)
    detect_max = 900,      -- analysis size: 900 as in Viñeta, 600 faster
    gamma = 0,             -- minimum contrast (0: the reader's)
    indicator = true,      -- «3/7» in a corner
    refresh_every = 8,     -- full refresh every N steps (0: never, -1: on each new page)
}

local function setting(name)
    local v = G_reader_settings:readSetting("vineta_" .. name)
    if v == nil then return DEFAULTS[name] end
    return v
end

local function setSetting(name, value)
    G_reader_settings:saveSetting("vineta_" .. name, value)
end

function Vineta:setEnabled(on)
    G_reader_settings:saveSetting("vineta_enabled", on)
    if on then
        if self.available and not self.viewer then self:start(true) end
    else
        if self._runner then
            self._runner:stop()
            self._runner = nil
        end
        -- Not the user leaving this book's panel mode: it comes back when switched on again.
        if self.viewer then UIManager:close(self.viewer, "full") end
    end
end

function Vineta:onVinetaSwitch()
    self:setEnabled(not isEnabled())
    local Notification = require("ui/widget/notification")
    Notification:notify(isEnabled() and T("Viñeta a viñeta activado") or T("Viñeta a viñeta desactivado"))
    return true
end

-- Detections saved in the book's settings (only if made by this version of the detector).
function Vineta:loadCache()
    self.model = { pages = {} }
    local saved = self.ui.doc_settings:readSetting("vineta_cache")
    if type(saved) == "table" and saved.version == self:cacheVersion() and type(saved.pages) == "table" then
        for page, e in pairs(saved.pages) do
            local entry = type(page) == "number" and Panels.entry(e)
            if entry and entry.kind ~= "error" then self.model.pages[page] = entry end
        end
    end
end

-- Detections depend on the detector and on the analysis size.
function Vineta:cacheVersion()
    return Detect.VERSION .. "/" .. setting("detect_max")
end

-- What the worker needs to know besides the page number.
function Vineta:runnerParams()
    local Screen = require("device").screen
    return {
        detect_max = setting("detect_max"),
        balloons = setting("balloons"),
        screen_w = Screen:getWidth(),
        screen_h = Screen:getHeight(),
    }
end

function Vineta:runner()
    if not self._runner then
        self._runner = Runner.new{
            file = self.ui.document.file,
            document = self.ui.document,
            logger = logger,
            params = self:runnerParams(),
            on_result = function(page, entry) self:onPageDetected(page, entry) end,
        }
    end
    return self._runner
end

function Vineta:onPageDetected(page, entry)
    if page == 0 then return self:onMeta(entry) end
    entry = Panels.entry(entry) or { kind = "error" }
    self.model.pages[page] = entry
    self.cache_dirty = true
    if self.viewer then self.viewer:onDetected(page) end
    -- After the first page: look for ComicInfo.xml (manga or not), once per comic.
    if self.state and self.state.meta == nil and not self.meta_asked and META_TYPES[fileType(self.ui.document.file)] then
        self.meta_asked = true
        self:runner():request(0, true)
    end
end

-- ComicInfo.xml read: if it says manga and the user did not choose a direction, use it.
function Vineta:onMeta(meta)
    self.state = self.state or {}
    self.state.meta = { manga = meta and meta.manga == true }
    -- rtl_user: the user chose the direction in the viewer menu; never overridden.
    if self.state.meta.manga and not self.state.rtl_user then
        self.state.rtl = true
        if self.viewer and not self.viewer.rtl then self.viewer:setRtl(true, true) end
    end
end

function Vineta:options()
    local prefetch = setting("prefetch")
    local refresh = setting("refresh_every")
    local split = setting("split")
    local gamma = setting("gamma")
    return {
        margin = Panels.defaults.margin,
        max_zoom = Panels.defaults.max_zoom,
        split = split > 0 and split or nil,
        overview = setting("overview"),
        balloons = setting("balloons"),
        spreads = setting("spreads"),
        refresh_every = refresh,
        prefetch = prefetch > 0 and prefetch or math.huge,
        gamma = gamma > 0 and gamma or nil,
        indicator = setting("indicator"),
    }
end

-- A setting changed: the viewer uses the new options at once.
function Vineta:applyOptions()
    if self._runner then self._runner.params = self:runnerParams() end
    local v = self.viewer
    if not v then return end
    local opts = self:options()
    opts.screen_w, opts.screen_h = v.opts.screen_w, v.opts.screen_h
    v.opts = opts
    v.nav:reset()
    v:renderStep()
end

function Vineta:onReaderReady()
    local kind = fileType(self.ui.document.file)
    if not self.ui.paging or not PAGED_TYPES[kind] or not self.ui.document._document then return end
    self.available = true
    self:loadCache()
    local state = self.ui.doc_settings:readSetting("vineta") or {}
    self.state = state
    if not isEnabled() then return end
    local wanted = state.active
    if wanted == nil then wanted = COMIC_TYPES[kind] and G_reader_settings:nilOrTrue("vineta_autostart") end
    if wanted then
        -- After the reader has drawn its first page.
        UIManager:nextTick(function() self:start(true) end)
    end
end

-- resume: continue at the saved panel if the reader is still on the saved page.
function Vineta:start(resume)
    if self.viewer or not isEnabled() then return end
    if not self.available then
        UIManager:show(InfoMessage:new{ text = T("El modo viñeta a viñeta solo funciona con cómics (CBZ, CBR, CBT, CB7) y PDF.") })
        return
    end
    local page = self.ui.paging.current_page
    local index = 1
    local state = self.state or {}
    if resume and state.page == page and state.index then index = state.index end
    local rtl = state.rtl
    if rtl == nil then rtl = false end -- may become true when ComicInfo.xml is read
    self.viewer = PanelViewer:new{
        ui = self.ui,
        model = self.model,
        request = function(p, urgent) self:runner():request(p, urgent) end,
        rtl = rtl,
        zoom = state.zoom ~= false,
        opts = self:options(),
        page = page,
        index = index,
        on_close = function(viewer) self:onViewerClosed(viewer) end,
    }
    UIManager:show(self.viewer)
end

function Vineta:onViewerClosed(viewer)
    self:remember(viewer)
    self.viewer = nil
    -- Left by the user: stay in the normal reader next time. If KOReader closed it
    -- (book closed, quit, power off), reopen in panel mode.
    if viewer.user_exit then self.state.active = false end
end

function Vineta:remember(viewer)
    self.state = self.state or {}
    self.state.page = viewer.nav.page
    self.state.index = viewer.nav.index
    self.state.rtl = viewer.rtl
    self.state.zoom = viewer.zoom ~= false
    if viewer.rtl_user then self.state.rtl_user = true end
    self.state.active = true
end

function Vineta:onVinetaToggle()
    if not self.ui.paging then return end
    if not isEnabled() then
        UIManager:show(InfoMessage:new{ text = T("Viñeta a viñeta está desactivado. Actívalo en su menú."), timeout = 3 })
        return true
    end
    if self.viewer then
        self.viewer:onExitPanelMode()
    else
        self:start(true)
    end
    return true
end

function Vineta:onSaveSettings()
    if self.viewer then self:remember(self.viewer) end
    if self.state then self.ui.doc_settings:saveSetting("vineta", self.state) end
    if self.cache_dirty then
        local pages = {}
        for page, e in pairs(self.model.pages) do
            if e.kind ~= "error" then pages[page] = e end
        end
        self.ui.doc_settings:saveSetting("vineta_cache", { version = self:cacheVersion(), pages = pages })
        self.cache_dirty = false
    end
end

function Vineta:onCloseDocument()
    if self._runner then
        self._runner:stop()
        self._runner = nil
    end
    if self.viewer then
        self:remember(self.viewer)
        UIManager:close(self.viewer)
    end
end

-- Forgets this comic's detections: pages are detected again as they are shown.
function Vineta:redetect()
    if self._runner then
        self._runner:stop()
        self._runner = nil
    end
    self.model.pages = {}
    self.cache_dirty = true
    if self.viewer then
        self.viewer.nav:reset()
        self.viewer:renderStep()
    end
end

-- Menu entry for an on/off setting.
function Vineta:toggleItem(name, text, separator)
    return {
        text = text,
        enabled_func = isEnabled,
        checked_func = function() return setting(name) == true end,
        callback = function()
            setSetting(name, not setting(name))
            self:applyOptions()
        end,
        separator = separator,
    }
end

-- Menu entry for a setting with several values: choices = { { value, label, short }, … }.
-- title(short) gives the entry's text for the current value (short defaults to label).
function Vineta:choiceItem(name, title, choices, on_change, separator)
    local function labelOf(v)
        for _, c in ipairs(choices) do
            if c[1] == v then return c[3] or c[2] end
        end
        return tostring(v)
    end
    return {
        text_func = function() return title(labelOf(setting(name))) end,
        enabled_func = isEnabled,
        sub_item_table_func = function()
            local items = {}
            for _, c in ipairs(choices) do
                items[#items + 1] = {
                    text = c[2],
                    radio = true,
                    checked_func = function() return setting(name) == c[1] end,
                    callback = function()
                        if setting(name) == c[1] then return end
                        setSetting(name, c[1])
                        if on_change then on_change() else self:applyOptions() end
                    end,
                }
            end
            return items
        end,
        separator = separator,
    }
end

function Vineta:addToMainMenu(menu_items)
    if not self.ui.paging then return end
    menu_items.vineta = {
        text = T("Viñeta a viñeta"),
        sorting_hint = "navi",
        sub_item_table = {
            {
                text = T("Activado"),
                checked_func = isEnabled,
                callback = function(touchmenu_instance)
                    local on = not isEnabled()
                    -- Close the menu first: switching on opens the panel viewer.
                    if on and touchmenu_instance then touchmenu_instance:closeMenu() end
                    self:setEnabled(on)
                end,
                separator = true,
            },
            {
                text = T("Leer viñeta a viñeta"),
                enabled_func = isEnabled,
                callback = function(touchmenu_instance)
                    if touchmenu_instance then touchmenu_instance:closeMenu() end
                    self:start(true)
                end,
            },
            self:toggleItem("autostart", T("Abrir los cómics en este modo")),
            {
                text = T("Volver a buscar las viñetas de este cómic"),
                enabled_func = function() return self.available == true and isEnabled() end,
                callback = function() self:redetect() end,
                separator = true,
            },
            self:toggleItem("overview", T("Empezar cada página entera")),
            self:choiceItem("split", function(l) return T("Partir en dos mitades: %s", l) end, {
                { 1.1, T("Las que no ganan un %d %% de ancho", 10), "< 10 %" },
                { 1.2, T("Las que no ganan un %d %% de ancho", 20), "< 20 %" },
                { 1.3, T("Las que no ganan un %d %% de ancho", 30), "< 30 %" },
                { 1.5, T("Las que no ganan un %d %% de ancho", 50), "< 50 %" },
                { 0, T("Ninguna"), T("no") },
            }),
            self:toggleItem("balloons", T("Zoom a los bocadillos")),
            self:toggleItem("spreads", T("Páginas dobles: primero cada mitad"), true),
            self:choiceItem("gamma", function(l) return T("Contraste: %s", l) end, {
                { 0, T("El del lector"), T("normal") },
                { 1.5, T("Más"), T("más") },
                { 2.0, T("Mucho más"), T("mucho más") },
            }),
            self:toggleItem("indicator", T("Mostrar el número de paso («3/7»)")),
            self:choiceItem("refresh_every", function(l) return T("Refresco completo: %s", l) end, {
                { 1, T("Cada paso"), T("cada paso") },
                { 4, T("Cada %d pasos", 4), T("%d pasos", 4) },
                { 8, T("Cada %d pasos", 8), T("%d pasos", 8) },
                { 12, T("Cada %d pasos", 12), T("%d pasos", 12) },
                { 20, T("Cada %d pasos", 20), T("%d pasos", 20) },
                { -1, T("Al cambiar de página"), T("cada página") },
                { 0, T("Nunca"), T("nunca") },
            }, nil, true),
            self:choiceItem("prefetch", function(l) return T("Analizar por delante: %s", l) end, {
                { 2, T("%d páginas", 2) },
                { 5, T("%d páginas", 5) },
                { 0, T("Todo el cómic"), T("todo el cómic") },
            }),
            self:choiceItem("detect_max", function(l) return T("Análisis: %s", l) end, {
                { 900, T("Normal (como Viñeta)"), T("normal") },
                { 600, T("Rápido (menos preciso)"), T("rápido") },
            }, function()
                -- Detections made at another size are dropped: look for the panels again.
                self:redetect()
            end),
        },
    }
end

return Vineta
