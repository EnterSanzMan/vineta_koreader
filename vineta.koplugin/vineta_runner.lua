--[[--
Detects the panels of a comic's pages on the reader, in the background.

A worker process (fork) opens its own copy of the document (its own file
offset: no races with the reader) and, for each page number it gets through a
pipe, renders the page in colour at the analysis size and runs the detector
(vineta_detect). Results come back through another pipe. If fork is not
available, pages are detected in the main process (blocking).

    local runner = Runner.new{ file = …, document = …, on_result = function(page, entry) … end }
    runner:request(page, urgent)   -- entry = { kind, ltr = {rects 0..1}, rtl = {…} } or { kind = "error" }
    runner:stop()
]]

local ffi = require("ffi")
local C = ffi.C
local Detect = require("vineta_detect")
local Panels = require("vineta_panels")

local Runner = {}
Runner.__index = Runner

local POLL = 0.25 -- seconds between checks of the worker's pipe
local MAX_RESTARTS = 3
local BACKGROUND_BUDGET_MS = 12000
-- Long side, in pixels, the page is assumed to have for the size of the balloon crops
-- (Viñeta draws them from its display image, about this size).
local BALLOON_PAGE_PX = 2400

-- Renders the part of page `p` at (ox, oy) of size w×h, at `zoom`, in colour.
-- Returns a fresh RGBA array (D.u8, R G B A even if MuPDF gives B G R A).
local function renderRGBA(p, zoom, w, h, ox, oy, bgr)
    local DrawContext = require("ffi/drawcontext")
    local dc = DrawContext.new()
    dc:setZoom(zoom)
    local bb = p:draw_new(dc, w, h, ox, oy)
    local bpp = bb:getBpp()
    if bpp ~= 32 then
        bb:free()
        error("render is not RGB32 (" .. bpp .. " bpp)")
    end
    local stride = tonumber(bb.stride)
    local src = ffi.cast("uint8_t*", bb.data)
    local rgba = Detect.u8(w * h * 4)
    if stride == w * 4 then
        ffi.copy(rgba, src, w * h * 4)
    else
        for y = 0, h - 1 do ffi.copy(rgba + y * w * 4, src + y * stride, w * 4) end
    end
    bb:free()
    if bgr then
        for i = 0, w * h * 4 - 1, 4 do rgba[i], rgba[i + 2] = rgba[i + 2], rgba[i] end
    end
    return rgba
end

-- Balloons of the normalised rect r of the page (nw × nh native units).
local function balloonsOf(p, r, nw, nh, whole, bgr)
    local k = BALLOON_PAGE_PX / math.max(nw, nh)
    local pw, ph = r.w * nw * k, r.h * nh * k
    local dw, dh = Detect.balloonSize(pw, ph)
    local zoom = dw / (r.w * nw)
    local rgba = renderRGBA(p, zoom, dw, dh, math.floor(r.x * nw * zoom + 0.5), math.floor(r.y * nh * zoom + 0.5), bgr)
    return Detect.detectBalloonsBoth(rgba, dw, dh, whole)
end

-- Render `page` of the MuPDF document `raw` in colour at twice the analysis size and
-- detect it. params: detect_max (analysis size), balloons (bool), screen_w, screen_h.
-- Returns the cache entry.
local function analyse(raw, page, bgr, params)
    local DrawContext = require("ffi/drawcontext")
    Detect.DETECT_MAX = params.detect_max or 900
    local p = raw:openPage(page)
    local ok, res = pcall(function()
        local nw, nh = p:getSize(DrawContext.new())
        local aw, ah = Detect.analysisSize(nw, nh)
        local W, H = aw * 2, ah * 2
        local rgba = renderRGBA(p, math.min(W / nw, H / nh), W, H, 0, 0, false)
        local r = Detect.detectImage(rgba, W, H, { aw = aw, ah = ah, bgr = bgr })
        rgba = nil
        local entry = { kind = r.kind, ltr = r.panels, rtl = r.panelsRtl }
        if params.balloons then
            entry.balloons = true
            local native = { w = nw, h = nh }
            if Panels.isWholePage(entry) then
                entry.page_balloons = balloonsOf(p, { x = 0, y = 0, w = 1, h = 1 }, nw, nh, true, bgr)
            elseif entry.kind == "comic" or entry.kind == "single" then
                for _, q in ipairs(entry.ltr) do
                    if Panels.wantsBalloons(q, native, params.screen_w, params.screen_h) then
                        q.balloons = balloonsOf(p, q, nw, nh, false, bgr)
                    end
                end
            end
        end
        return entry
    end)
    p:close()
    if not ok then error(res, 0) end
    return res
end

local function safeAnalyse(raw, page, bgr, params)
    local ok, res = pcall(analyse, raw, page, bgr, params)
    if ok then return res end
    return { kind = "error", error = tostring(res) }
end

-- Reading direction from the comic's ComicInfo.xml (<Manga>YesAndRightToLeft</Manga>).
-- Returns { manga = true|false } or { } if there is none.
local function readMeta(file)
    local ok, Archiver = pcall(require, "ffi/archiver")
    if not ok then return {} end
    local arc = Archiver.Reader:new()
    if not arc:open(file) then return {} end
    local xml
    for entry in arc:iterate() do
        if entry.mode == "file" and entry.path:lower():match("comicinfo%.xml$") then
            xml = arc:extractToMemory(entry.path)
            break
        end
    end
    arc:close()
    if not xml then return {} end
    local manga = xml:match("<[Mm]anga>%s*([^<]-)%s*</[Mm]anga>")
    if not manga then return {} end
    return { manga = manga:lower() == "yesandrighttoleft" }
end

-- args: file (path), document (KOReader document), on_result(page, entry), logger
function Runner.new(args)
    local self = setmetatable({
        file = args.file,
        document = args.document,
        on_result = args.on_result,
        logger = args.logger,
        queue = {},     -- pages waiting, in order
        busy = nil,     -- page the worker is on
        buffer = "",
        restarts = 0,
        -- detect_max, balloons, screen_w, screen_h (see analyse); can change between requests
        params = args.params or {},
    }, Runner)
    local okm, mupdf = pcall(require, "ffi/mupdf")
    self.bgr = okm and mupdf.bgr or false
    return self
end

function Runner:log(...)
    if self.logger then self.logger.warn("Vineta:", ...) end
end

-- Asks for a page. urgent: before every page already waiting.
function Runner:request(page, urgent)
    if page == self.busy then return end
    for i, q in ipairs(self.queue) do
        if q == page then
            if not urgent then return end
            table.remove(self.queue, i)
            break
        end
    end
    if urgent then table.insert(self.queue, 1, page) else self.queue[#self.queue + 1] = page end
    self:pump()
end

-- Drops the waiting pages (not the one being detected).
function Runner:clearQueue()
    self.queue = {}
end

function Runner:isPending(page)
    if page == self.busy then return true end
    for _, q in ipairs(self.queue) do
        if q == page then return true end
    end
    return false
end

local function writeAll(fd, s)
    local n = C.write(fd, s, #s)
    return tonumber(n) == #s
end

function Runner:startWorker()
    if self.pid then return true end
    if self.restarts > MAX_RESTARTS then return false end
    local ok, ffiutil = pcall(require, "ffi/util")
    if not ok or not ffiutil.runInSubProcess then return false end
    local file, bgr = self.file, self.bgr
    local pid, read_fd, write_fd = ffiutil.runInSubProcess(function(_, child_write_fd, child_read_fd)
        local mupdf = require("ffi/mupdf")
        local buffer = require("string.buffer")
        -- The framed method gives up after a time budget (1.5 s, tuned for a phone or a PC).
        -- An e-reader is several times slower and this runs in the background: allow more.
        Detect.FRAMED_BUDGET_MS = BACKGROUND_BUDGET_MS
        local raw = mupdf.openDocument(file)
        raw:setColorRendering(true)
        local byte = ffi.new("char[1]")
        while true do
            -- One request per line: the page number.
            local line = {}
            while true do
                local n = tonumber(C.read(child_read_fd, byte, 1))
                if n ~= 1 then return end -- parent closed the pipe: done
                local ch = ffi.string(byte, 1)
                if ch == "\n" then break end
                line[#line + 1] = ch
            end
            -- "meta", or "page detect_max balloons screen_w screen_h"
            line = table.concat(line)
            local page, entry
            local t0 = os.clock()
            if line == "meta" then
                page = 0
                local okm, meta = pcall(readMeta, file)
                entry = okm and meta or {}
            else
                local pg, dm, bal, sw, sh = line:match("^(%d+) (%d+) (%d) (%d+) (%d+)$")
                page = tonumber(pg)
                if page then
                    entry = safeAnalyse(raw, page, bgr, {
                        detect_max = tonumber(dm), balloons = bal == "1",
                        screen_w = tonumber(sw), screen_h = tonumber(sh),
                    })
                end
            end
            if page then
                entry.ms = math.floor((os.clock() - t0) * 1000 + 0.5)
                local payload = buffer.encode(entry)
                local head = string.format("%d %d\n", page, #payload)
                if not writeAll(child_write_fd, head .. payload) then return end
                collectgarbage()
            end
        end
    end, "bidi")
    if not pid then
        self:log("cannot start the detection worker:", read_fd)
        self.restarts = MAX_RESTARTS + 1
        return false
    end
    self.ffiutil = ffiutil
    self.pid, self.read_fd, self.write_fd = pid, read_fd, write_fd
    self.buffer = ""
    return true
end

function Runner:stopWorker()
    if not self.pid then return end
    local ffiutil = self.ffiutil
    if self.write_fd then C.close(self.write_fd) end
    if self.read_fd then C.close(self.read_fd) end
    ffiutil.terminateSubProcess(self.pid)
    -- Reap it later (terminateSubProcess only signals it).
    local pid = self.pid
    local UIManager = require("ui/uimanager")
    local tries = 0
    local function reap()
        tries = tries + 1
        if not ffiutil.isSubProcessDone(pid) and tries < 20 then UIManager:scheduleIn(0.5, reap) end
    end
    UIManager:scheduleIn(0.1, reap)
    self.pid, self.read_fd, self.write_fd = nil, nil, nil
end

function Runner:finish(page, entry)
    if page == 0 then
        -- ComicInfo.xml: nothing to log
    elseif entry.kind == "error" then
        self:log("page", page, entry.error)
    elseif self.logger then
        self.logger.info("Vineta: page", page, entry.kind, entry.ltr and #entry.ltr or 0, "panels,", entry.ms or "?", "ms")
    end
    self.busy = nil
    if self.on_result then self.on_result(page, entry) end
end

function Runner:requestLine(page)
    if page == 0 then return "meta\n" end
    local p = self.params
    return string.format("%d %d %d %d %d\n", page, p.detect_max or 900, p.balloons and 1 or 0,
        p.screen_w or 1, p.screen_h or 1)
end

-- Sends the next page to the worker (or detects it here if there is no worker).
function Runner:pump()
    if self.busy or self.stopped then return end
    local page = table.remove(self.queue, 1)
    if not page then return end
    self.busy = page
    if self:startWorker() then
        if writeAll(self.write_fd, self:requestLine(page)) then
            self:schedulePoll()
            return
        end
        self:stopWorker()
        self.restarts = self.restarts + 1
    end
    -- No worker: detect in this process, after the screen had a chance to update.
    local UIManager = require("ui/uimanager")
    UIManager:scheduleIn(0.05, function()
        if self.stopped then return end
        local entry
        if page == 0 then
            local okm, meta = pcall(readMeta, self.file)
            entry = okm and meta or {}
        else
            local raw = self.document._document
            local was = raw.color
            raw:setColorRendering(true)
            entry = safeAnalyse(raw, page, self.bgr, self.params)
            raw:setColorRendering(was)
        end
        self:finish(page, entry)
        self:pump()
    end)
end

function Runner:schedulePoll()
    if self.poll_scheduled then return end
    self.poll_scheduled = true
    local UIManager = require("ui/uimanager")
    self._poll = self._poll or function()
        self.poll_scheduled = false
        self:poll()
    end
    UIManager:scheduleIn(POLL, self._poll)
end

function Runner:poll()
    if self.stopped or not self.pid then return end
    local ffiutil = self.ffiutil
    local avail = ffiutil.getNonBlockingReadSize(self.read_fd) or 0
    if avail > 0 then
        local buf = ffi.new("char[?]", avail)
        local n = tonumber(C.read(self.read_fd, buf, avail))
        if n and n > 0 then self.buffer = self.buffer .. ffi.string(buf, n) end
    end
    -- Complete frames: "page length\n" + payload.
    while true do
        local nl = self.buffer:find("\n", 1, true)
        if not nl then break end
        local page, len = self.buffer:sub(1, nl - 1):match("^(%d+) (%d+)$")
        page, len = tonumber(page), tonumber(len)
        if not page or #self.buffer < nl + len then break end
        local payload = self.buffer:sub(nl + 1, nl + len)
        self.buffer = self.buffer:sub(nl + len + 1)
        local ok, entry = pcall(require("string.buffer").decode, payload)
        if not ok or type(entry) ~= "table" then entry = { kind = "error", error = "bad data from worker" } end
        self:finish(page, entry)
    end
    if self.busy then
        if ffiutil.isSubProcessDone(self.pid) then
            -- The worker died on this page (out of memory, crash in a decoder…).
            local page = self.busy
            self:stopWorker()
            self.restarts = self.restarts + 1
            self:finish(page, { kind = "error", error = "worker died" })
            self:pump()
        else
            self:schedulePoll()
        end
    else
        self:pump()
    end
end

function Runner:stop()
    self.stopped = true
    self.queue = {}
    self:stopWorker()
end

return Runner
