# Viñeta für KOReader

[English](README.md) · [Español](README.es.md) · [Português](README.pt.md) · [Français](README.fr.md) · **Deutsch**

> **Basiert auf [Viñeta](https://play.google.com/store/apps/details?id=com.dsp.vineta), der Android-App, mit der man Comics Panel für Panel liest.**
> Dieses Plugin bringt den Panel-Detektor der App auf E-Ink-Reader mit KOReader.

<a href="https://play.google.com/store/apps/details?id=com.dsp.vineta"><img alt="Jetzt bei Google Play" src="https://play.google.com/intl/de/badges/static/images/badges/de_badge_web_generic.png" height="64"></a>

Ein [KOReader](https://koreader.rocks)-Plugin, um Comics auf E-Ink-Readern **Panel für Panel** zu lesen. Der Reader findet die Panels selbst mit dem Detektor von Viñeta, während du liest: Am Computer musst du nichts vorbereiten, und die Comic-Datei wird nicht verändert.

> **Hinweis:** Die Menüs des Plugins sind vorerst auf Spanisch. Unten werden die Menüpunkte so zitiert, wie sie auf dem Bildschirm erscheinen, gefolgt von ihrer Bedeutung.

## Installation

1. Installiere [KOReader](https://github.com/koreader/koreader/releases) auf deinem Reader.
2. Kopiere den Ordner `vineta.koplugin` in den Ordner `plugins` von KOReader. Zum Beispiel:
   - PocketBook: `applications/koreader/plugins/`
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
3. Starte KOReader neu und öffne einen CBZ- oder CBR-Comic über den Dateibrowser.

## Lesen

Comics öffnen sich automatisch im Panel-für-Panel-Modus. Jede Seite wird zuerst ganz und dann Panel für Panel angezeigt. Große Panels, die auf dem Bildschirm kaum größer würden, werden in zwei Hälften gezeigt: zuerst die linke, dann die rechte. Enthält der Comic eine `ComicInfo.xml`, die ihn als Manga ausweist, wird er ohne weitere Einstellung von rechts nach links gelesen. Eine kleine Zahl in der Ecke („3/7“) zeigt, bei welchem Schritt der Seite du bist.

Jede Seite wird beim ersten Lesen im Hintergrund analysiert, und das Ergebnis wird gespeichert: Wenn du zum Comic zurückkehrst, musst du nicht mehr warten.

Im KOReader-Menü → Navigations-Tab → „Viñeta a viñeta“ (Panel für Panel) gibt es den Schalter **„Activado“** (aktiviert), um das Plugin ein- oder auszuschalten. Von dort aus startest du den Modus auch mit einem PDF oder wenn du ihn verlassen hast.

| | |
|---|---|
| Tippen rechts / Vorwärts-Taste | Nächstes Panel |
| Tippen links / Rückwärts-Taste | Vorheriges Panel |
| Langes Drücken | Ganze Seite ↔ Panel |
| Zusammenziehen (zwei Finger zusammen) / nach oben oder unten wischen | Zoom aus: ganze Seiten, es wird Seite für Seite geblättert |
| Auseinanderziehen (zwei Finger) / nach oben oder unten wischen | Zoom wieder an: Panel für Panel ab dem ersten Panel |
| Tippen in der Mitte | Menü (Manga-Leserichtung, Zoom, ganze Seite, beenden) |

Ohne Zoom zeigt die Ecke „sin zoom“ (ohne Zoom). Jeder Comic merkt sich, ob du ihn mit ein- oder ausgeschaltetem Zoom verlassen hast.

Im KOReader-Menü „Viñeta a viñeta“ kannst du außerdem:

- jede Seite ganz beginnen oder direkt mit ihrem ersten Panel;
- Panels, die nicht um 10, 20, 30 oder 50 % breiter würden, in zwei Hälften teilen – oder keine;
- in die Sprechblasen sehr breiter oder sehr hoher Panels zoomen;
- bei Doppelseiten zuerst jede Hälfte ansehen;
- den Kontrast erhöhen (Farbcomics wirken in 16 Graustufen blass);
- die Schrittnummer ausblenden;
- festlegen, wie oft der Bildschirm komplett aufgefrischt wird, auch „beim Seitenwechsel“;
- 2 Seiten, 5 Seiten oder den ganzen Comic im Voraus analysieren und die schnelle Analyse wählen (weniger genau);
- die Panels eines Comics neu erkennen lassen.

Unter „Toques y gestos“ (Tippen und Gesten) kannst du einer Geste „Activar o desactivar Viñeta a viñeta“ (Panel für Panel ein-/ausschalten) zuweisen.

Wie der Detektor in Lua aufgebaut ist (auf Spanisch): [docs/detector-lua.md](docs/detector-lua.md).

## Lizenz

[AGPL-3.0](LICENSE), dieselbe wie KOReader. Du darfst das Plugin nutzen, verändern und weitergeben, solange du den Code unter derselben Lizenz teilst.

Zusätzlich muss nach Abschnitt 7 b) der AGPL jeder, der das Plugin oder ein davon abgeleitetes Werk weitergibt (auch nur den Panel-Detektor), die Namensnennung des Autors beibehalten. Einzelheiten stehen in [NOTICE](NOTICE).
