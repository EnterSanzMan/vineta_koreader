-- Name and description in KOReader's plugin list, in its language (English by default).
-- Read before main.lua, when vineta_i18n.lua is not reachable yet: the texts go here.
local META = {
    en = { "Panel by panel", [[Read comics panel by panel. The reader itself finds the panels with Viñeta's detector, in the background while you read, and keeps them for next time.]] },
    es = { "Viñeta a viñeta", [[Lee cómics viñeta a viñeta. Las viñetas las busca el propio lector con el detector de Viñeta, en segundo plano mientras lees, y se guardan para la próxima vez.]] },
    pt = { "Vinheta a vinheta", [[Leia banda desenhada vinheta a vinheta. É o próprio leitor que encontra as vinhetas com o detetor da Viñeta, em segundo plano enquanto lê, e guarda-as para a próxima vez.]] },
    fr = { "Case par case", [[Lisez vos BD case par case. La liseuse trouve elle-même les cases avec le détecteur de Viñeta, en arrière-plan pendant la lecture, et les garde pour la prochaine fois.]] },
    de = { "Panel für Panel", [[Comics Panel für Panel lesen. Der Reader findet die Panels selbst mit dem Detektor von Viñeta, im Hintergrund während du liest, und speichert sie für das nächste Mal.]] },
}

local code
local ok, gettext = pcall(require, "gettext")
if ok and type(gettext) == "table" then code = gettext.current_lang end
if (not code or code == "C") and G_reader_settings then
    code = G_reader_settings:readSetting("language") or code
end
local lang = type(code) == "string" and code:match("^(%a%a)") or "en"
local meta = META[lang:lower()] or META.en

return {
    fullname = meta[1],
    description = meta[2],
}
