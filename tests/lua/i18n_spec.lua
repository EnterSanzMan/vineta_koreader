-- Tests of vineta_i18n.lua. Run with LuaJIT from the repo root:
--   luajit tests/lua/i18n_spec.lua
package.path = "vineta.koplugin/?.lua;" .. package.path
local I18n = require("vineta_i18n")

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

local function readFile(path)
    local f = assert(io.open(path, "rb"))
    local s = f:read("*a")
    f:close()
    return s
end

-- Placeholders of a text, in order (%% left out).
local function placeholders(s)
    local out = {}
    for p in s:gsub("%%%%", ""):gmatch("%%[%-%d%.]*%a") do out[#out + 1] = p end
    return table.concat(out, " ")
end

test("every text has every language", function()
    for key, t in pairs(I18n.STRINGS) do
        for _, lang in ipairs(I18n.LANGS) do
            if type(t[lang]) ~= "string" or t[lang] == "" then error("missing " .. lang .. ": " .. key) end
        end
    end
end)

test("placeholders match the Spanish key", function()
    for key, t in pairs(I18n.STRINGS) do
        for _, lang in ipairs(I18n.LANGS) do
            eq(placeholders(t[lang]), placeholders(key), lang .. " «" .. key .. "»:")
        end
    end
end)

test("every T(\"…\") in the plugin has a translation", function()
    for _, file in ipairs{ "main.lua", "vineta_viewer.lua" } do
        local src = readFile("vineta.koplugin/" .. file)
        local n = 0
        for key in src:gmatch('T%("(.-)"[,)]') do
            n = n + 1
            if not I18n.STRINGS[key] then error(file .. ": no translation for «" .. key .. "»") end
        end
        if n == 0 then error(file .. ": no T() found") end
    end
end)

test("language codes", function()
    eq(I18n.normalize("es"), "es")
    eq(I18n.normalize("pt_BR"), "pt")
    eq(I18n.normalize("pt_PT"), "pt")
    eq(I18n.normalize("de"), "de")
    eq(I18n.normalize("fr"), "fr")
    eq(I18n.normalize("en_GB"), "en")
    eq(I18n.normalize("C"), "en")
    eq(I18n.normalize("ja"), "en")
    eq(I18n.normalize(nil), "en")
end)

test("T translates and formats", function()
    I18n.setLang("es")
    eq(I18n.T("Activado"), "Activado")
    eq(I18n.T("Las que no ganan un %d %% de ancho", 20), "Las que no ganan un 20 % de ancho")
    I18n.setLang("en")
    eq(I18n.T("Activado"), "Enabled")
    eq(I18n.T("Página %d de %d · paso %d de %d", 3, 20, 2, 7), "Page 3 of 20 · step 2 of 7")
    I18n.setLang("de")
    eq(I18n.T("Partir en dos mitades: %s", I18n.T("no")), "In zwei Hälften teilen: keine")
    I18n.setLang("ja")
    eq(I18n.T("sin zoom"), "no zoom")
    eq(I18n.T("texto sin traducir"), "texto sin traducir")
    I18n.setLang(nil)
end)

test("_meta.lua gives a name in each language", function()
    local function meta(lang)
        package.loaded.gettext = { current_lang = lang }
        local m = dofile("vineta.koplugin/_meta.lua")
        package.loaded.gettext = nil
        return m.fullname
    end
    eq(meta("es"), "Viñeta a viñeta")
    eq(meta("pt_BR"), "Vinheta a vinheta")
    eq(meta("fr"), "Case par case")
    eq(meta("de"), "Panel für Panel")
    eq(meta("C"), "Panel by panel")
    eq(meta("ru"), "Panel by panel")
end)

print(("%d tests, %d failures"):format(count, failures))
os.exit(failures == 0 and 0 or 1)
