--[[--
Translations of the plugin's texts: English, Spanish, Portuguese, French and German.

The Spanish text is the key. T("…", ...) returns the text in KOReader's language
(any other language gets English) and formats it with string.format when given
arguments, so placeholders (%d, %s, %%) go in the key too.

New text: add it to every language below; tests/lua/i18n_spec.lua checks that
none is missing and that the placeholders match.
]]

local M = {}

M.LANGS = { "en", "pt", "fr", "de" } -- Spanish is the key itself

M.STRINGS = {
    -- main.lua
    ["Viñeta a viñeta"] = {
        en = "Panel by panel",
        pt = "Vinheta a vinheta",
        fr = "Case par case",
        de = "Panel für Panel",
    },
    ["Activar o desactivar Viñeta a viñeta"] = {
        en = "Turn panel by panel on or off",
        pt = "Ativar ou desativar vinheta a vinheta",
        fr = "Activer ou désactiver case par case",
        de = "Panel für Panel ein- oder ausschalten",
    },
    ["Viñeta a viñeta activado"] = {
        en = "Panel by panel on",
        pt = "Vinheta a vinheta ativado",
        fr = "Case par case activé",
        de = "Panel für Panel eingeschaltet",
    },
    ["Viñeta a viñeta desactivado"] = {
        en = "Panel by panel off",
        pt = "Vinheta a vinheta desativado",
        fr = "Case par case désactivé",
        de = "Panel für Panel ausgeschaltet",
    },
    ["El modo viñeta a viñeta solo funciona con cómics (CBZ, CBR, CBT, CB7) y PDF."] = {
        en = "Panel by panel mode only works with comics (CBZ, CBR, CBT, CB7) and PDF.",
        pt = "O modo vinheta a vinheta só funciona com banda desenhada (CBZ, CBR, CBT, CB7) e PDF.",
        fr = "Le mode case par case ne fonctionne qu'avec les BD (CBZ, CBR, CBT, CB7) et les PDF.",
        de = "Der Panel-für-Panel-Modus funktioniert nur mit Comics (CBZ, CBR, CBT, CB7) und PDF.",
    },
    ["Viñeta a viñeta está desactivado. Actívalo en su menú."] = {
        en = "Panel by panel is off. Turn it on in its menu.",
        pt = "Vinheta a vinheta está desativado. Ative-o no seu menu.",
        fr = "Case par case est désactivé. Activez-le dans son menu.",
        de = "Panel für Panel ist ausgeschaltet. Schalte es in seinem Menü ein.",
    },
    ["Activado"] = {
        en = "Enabled",
        pt = "Ativado",
        fr = "Activé",
        de = "Aktiviert",
    },
    ["Leer viñeta a viñeta"] = {
        en = "Read panel by panel",
        pt = "Ler vinheta a vinheta",
        fr = "Lire case par case",
        de = "Panel für Panel lesen",
    },
    ["Abrir los cómics en este modo"] = {
        en = "Open comics in this mode",
        pt = "Abrir a banda desenhada neste modo",
        fr = "Ouvrir les BD dans ce mode",
        de = "Comics in diesem Modus öffnen",
    },
    ["Volver a buscar las viñetas de este cómic"] = {
        en = "Detect the panels of this comic again",
        pt = "Voltar a procurar as vinhetas deste livro",
        fr = "Relancer la détection des cases de cette BD",
        de = "Panels dieses Comics neu erkennen",
    },
    ["Empezar cada página entera"] = {
        en = "Start each page whole",
        pt = "Começar cada página inteira",
        fr = "Commencer chaque page en entier",
        de = "Jede Seite zuerst ganz zeigen",
    },
    ["Partir en dos mitades: %s"] = {
        en = "Split in two halves: %s",
        pt = "Dividir em duas metades: %s",
        fr = "Couper en deux moitiés : %s",
        de = "In zwei Hälften teilen: %s",
    },
    ["Las que no ganan un %d %% de ancho"] = {
        en = "Those that don't gain %d %% in width",
        pt = "As que não ganham %d %% de largura",
        fr = "Celles qui ne gagnent pas %d %% en largeur",
        de = "Die nicht um %d %% breiter werden",
    },
    ["Ninguna"] = {
        en = "None",
        pt = "Nenhuma",
        fr = "Aucune",
        de = "Keine",
    },
    ["no"] = { -- short form of «Ninguna»
        en = "none",
        pt = "nenhuma",
        fr = "aucune",
        de = "keine",
    },
    ["Zoom a los bocadillos"] = {
        en = "Zoom into speech balloons",
        pt = "Zoom aos balões de fala",
        fr = "Zoom sur les bulles",
        de = "In Sprechblasen zoomen",
    },
    ["Páginas dobles: primero cada mitad"] = {
        en = "Double pages: each half first",
        pt = "Páginas duplas: primeiro cada metade",
        fr = "Doubles pages : d'abord chaque moitié",
        de = "Doppelseiten: zuerst jede Hälfte",
    },
    ["Contraste: %s"] = {
        en = "Contrast: %s",
        pt = "Contraste: %s",
        fr = "Contraste : %s",
        de = "Kontrast: %s",
    },
    ["El del lector"] = {
        en = "The reader's",
        pt = "O do leitor",
        fr = "Celui de la liseuse",
        de = "Wie im Reader",
    },
    ["normal"] = {
        en = "normal",
        pt = "normal",
        fr = "normal",
        de = "normal",
    },
    ["Más"] = {
        en = "More",
        pt = "Mais",
        fr = "Plus",
        de = "Mehr",
    },
    ["más"] = {
        en = "more",
        pt = "mais",
        fr = "plus",
        de = "mehr",
    },
    ["Mucho más"] = {
        en = "Much more",
        pt = "Muito mais",
        fr = "Beaucoup plus",
        de = "Viel mehr",
    },
    ["mucho más"] = {
        en = "much more",
        pt = "muito mais",
        fr = "beaucoup plus",
        de = "viel mehr",
    },
    ["Mostrar el número de paso («3/7»)"] = {
        en = "Show the step number (\"3/7\")",
        pt = "Mostrar o número do passo («3/7»)",
        fr = "Afficher le numéro d'étape (« 3/7 »)",
        de = "Schrittnummer anzeigen („3/7“)",
    },
    ["Refresco completo: %s"] = {
        en = "Full refresh: %s",
        pt = "Atualização completa: %s",
        fr = "Rafraîchissement complet : %s",
        de = "Vollständige Auffrischung: %s",
    },
    ["Cada paso"] = {
        en = "Every step",
        pt = "Cada passo",
        fr = "À chaque étape",
        de = "Bei jedem Schritt",
    },
    ["cada paso"] = {
        en = "every step",
        pt = "cada passo",
        fr = "chaque étape",
        de = "jeder Schritt",
    },
    ["Cada %d pasos"] = {
        en = "Every %d steps",
        pt = "A cada %d passos",
        fr = "Toutes les %d étapes",
        de = "Alle %d Schritte",
    },
    ["%d pasos"] = {
        en = "%d steps",
        pt = "%d passos",
        fr = "%d étapes",
        de = "%d Schritte",
    },
    ["Al cambiar de página"] = {
        en = "On page change",
        pt = "Ao mudar de página",
        fr = "Au changement de page",
        de = "Beim Seitenwechsel",
    },
    ["cada página"] = {
        en = "every page",
        pt = "cada página",
        fr = "chaque page",
        de = "jede Seite",
    },
    ["Nunca"] = {
        en = "Never",
        pt = "Nunca",
        fr = "Jamais",
        de = "Nie",
    },
    ["nunca"] = {
        en = "never",
        pt = "nunca",
        fr = "jamais",
        de = "nie",
    },
    ["Analizar por delante: %s"] = {
        en = "Analyse ahead: %s",
        pt = "Analisar antecipadamente: %s",
        fr = "Analyser à l'avance : %s",
        de = "Im Voraus analysieren: %s",
    },
    ["%d páginas"] = {
        en = "%d pages",
        pt = "%d páginas",
        fr = "%d pages",
        de = "%d Seiten",
    },
    ["Todo el cómic"] = {
        en = "The whole comic",
        pt = "O livro inteiro",
        fr = "Toute la BD",
        de = "Den ganzen Comic",
    },
    ["todo el cómic"] = {
        en = "the whole comic",
        pt = "o livro inteiro",
        fr = "toute la BD",
        de = "ganzer Comic",
    },
    ["Análisis: %s"] = {
        en = "Analysis: %s",
        pt = "Análise: %s",
        fr = "Analyse : %s",
        de = "Analyse: %s",
    },
    ["Normal (como Viñeta)"] = {
        en = "Normal (as in Viñeta)",
        pt = "Normal (como na Viñeta)",
        fr = "Normale (comme Viñeta)",
        de = "Normal (wie in Viñeta)",
    },
    ["Rápido (menos preciso)"] = {
        en = "Fast (less accurate)",
        pt = "Rápida (menos precisa)",
        fr = "Rapide (moins précise)",
        de = "Schnell (weniger genau)",
    },
    ["rápido"] = {
        en = "fast",
        pt = "rápida",
        fr = "rapide",
        de = "schnell",
    },

    -- vineta_viewer.lua
    ["sin zoom"] = {
        en = "no zoom",
        pt = "sem zoom",
        fr = "sans zoom",
        de = "ohne Zoom",
    },
    ["Buscando viñetas…"] = {
        en = "Finding panels…",
        pt = "A procurar vinhetas…",
        fr = "Recherche des cases…",
        de = "Panels werden gesucht…",
    },
    ["Zoom activado: viñeta a viñeta"] = {
        en = "Zoom on: panel by panel",
        pt = "Zoom ativado: vinheta a vinheta",
        fr = "Zoom activé : case par case",
        de = "Zoom an: Panel für Panel",
    },
    ["Zoom desactivado: páginas enteras"] = {
        en = "Zoom off: whole pages",
        pt = "Zoom desativado: páginas inteiras",
        fr = "Zoom désactivé : pages entières",
        de = "Zoom aus: ganze Seiten",
    },
    ["Página %d de %d · paso %d de %d"] = {
        en = "Page %d of %d · step %d of %d",
        pt = "Página %d de %d · passo %d de %d",
        fr = "Page %d sur %d · étape %d sur %d",
        de = "Seite %d von %d · Schritt %d von %d",
    },
    ["Sentido: manga (derecha a izquierda)"] = {
        en = "Direction: manga (right to left)",
        pt = "Sentido: manga (da direita para a esquerda)",
        fr = "Sens : manga (de droite à gauche)",
        de = "Leserichtung: Manga (von rechts nach links)",
    },
    ["Sentido: occidental (izquierda a derecha)"] = {
        en = "Direction: western (left to right)",
        pt = "Sentido: ocidental (da esquerda para a direita)",
        fr = "Sens : occidental (de gauche à droite)",
        de = "Leserichtung: westlich (von links nach rechts)",
    },
    ["Activar el zoom (viñeta a viñeta)"] = {
        en = "Turn zoom on (panel by panel)",
        pt = "Ativar o zoom (vinheta a vinheta)",
        fr = "Activer le zoom (case par case)",
        de = "Zoom einschalten (Panel für Panel)",
    },
    ["Desactivar el zoom (páginas enteras)"] = {
        en = "Turn zoom off (whole pages)",
        pt = "Desativar o zoom (páginas inteiras)",
        fr = "Désactiver le zoom (pages entières)",
        de = "Zoom ausschalten (ganze Seiten)",
    },
    ["Volver a la viñeta"] = {
        en = "Back to the panel",
        pt = "Voltar à vinheta",
        fr = "Revenir à la case",
        de = "Zurück zum Panel",
    },
    ["Ver la página completa"] = {
        en = "Show the whole page",
        pt = "Ver a página inteira",
        fr = "Voir la page entière",
        de = "Ganze Seite anzeigen",
    },
    ["Salir del modo viñeta"] = {
        en = "Exit panel mode",
        pt = "Sair do modo vinheta",
        fr = "Quitter le mode case par case",
        de = "Panel-Modus beenden",
    },
}

-- "es", "en", "pt", "fr" or "de" from a KOReader language code ("pt_BR", "de", "C"…).
function M.normalize(code)
    local l = type(code) == "string" and code:match("^(%a%a)") or nil
    l = l and l:lower()
    if l == "es" or l == "pt" or l == "fr" or l == "de" then return l end
    return "en"
end

-- KOReader's interface language. It only changes after a restart, so it is read once.
local current
function M.lang()
    if current then return current end
    local code
    local ok, gettext = pcall(require, "gettext")
    if ok and type(gettext) == "table" and type(gettext.current_lang) == "string" then
        code = gettext.current_lang
    end
    if (not code or code == "C") and G_reader_settings then
        code = G_reader_settings:readSetting("language") or code
    end
    current = M.normalize(code)
    return current
end

-- For tests: force a language (nil: read KOReader's again).
function M.setLang(code)
    current = code and M.normalize(code) or nil
end

function M.T(text, ...)
    local lang = M.lang()
    if lang ~= "es" then
        local t = M.STRINGS[text]
        text = t and t[lang] or text
    end
    if select("#", ...) > 0 then return text:format(...) end
    return text
end

return M
