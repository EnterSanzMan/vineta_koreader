# Viñeta for KOReader

**English** · [Español](README.es.md) · [Português](README.pt.md) · [Français](README.fr.md) · [Deutsch](README.de.md)

> **Based on [Viñeta](https://play.google.com/store/apps/details?id=com.dsp.vineta), the Android app for reading comics panel by panel.**
> This plugin brings the app's panel detector to e-ink readers running KOReader.

<a href="https://play.google.com/store/apps/details?id=com.dsp.vineta"><img alt="Get it on Google Play" src="https://play.google.com/intl/en_us/badges/static/images/badges/en_badge_web_generic.png" height="64"></a>

A [KOReader](https://koreader.rocks) plugin for reading comics **panel by panel** on e-ink readers. The reader itself finds the panels with Viñeta's detector while you read: there is nothing to prepare on your computer and the comic file is never modified.

> **Note:** the plugin's menus are in Spanish for now. Below, menu entries are quoted as they appear on screen, followed by their meaning.

## Installation

1. Install [KOReader](https://github.com/koreader/koreader/releases) on your reader.
2. Copy the `vineta.koplugin` folder into KOReader's `plugins` folder. For example:
   - PocketBook: `applications/koreader/plugins/`
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
3. Restart KOReader and open a CBZ or CBR comic from its file browser.

## Reading

Comics open in panel-by-panel mode automatically. Each page is first shown whole and then panel by panel. Large panels, which would barely get any bigger on screen, are shown in two halves: first the left one, then the right one. If the comic includes a `ComicInfo.xml` saying it is manga, it is read right to left with no setup. A small number in the corner ("3/7") shows which step of the page you are on.

Each page is analysed in the background the first time it is read, and the result is saved: when you come back to the comic there is no waiting.

KOReader's menu → navigation tab → «Viñeta a viñeta» (panel by panel) has the **«Activado»** (enabled) switch to turn the plugin on or off. From there you can also enter the mode with a PDF, or if you left it.

| | |
|---|---|
| Tap on the right / forward button | Next panel |
| Tap on the left / back button | Previous panel |
| Long press | Whole page ↔ panel |
| Pinch (two fingers together) / swipe up or down | Turn zoom off: whole pages, turning page by page |
| Spread (two fingers apart) / swipe up or down | Turn zoom back on: panel by panel from the first panel |
| Tap in the centre | Menu (manga direction, zoom, whole page, exit) |

With zoom off, the corner shows «sin zoom» (no zoom). Each comic remembers whether you left it with zoom on or off.

In KOReader's «Viñeta a viñeta» menu you can also:

- start each page whole or go straight to its first panel;
- split into two halves the panels that don't gain 10, 20, 30 or 50 % in width, or none;
- zoom into the speech balloons of very wide or very tall panels;
- see each half of double-page spreads first;
- raise the contrast (colour comics look washed out in 16 greys);
- hide the step number;
- choose how often the screen is fully refreshed, including "on page change";
- analyse 2 pages ahead, 5, or the whole comic, and choose the fast analysis (less accurate);
- detect the panels of a comic again.

In «Toques y gestos» (Taps and gestures) you can assign «Activar o desactivar Viñeta a viñeta» (toggle panel by panel) to a gesture.

How the detector is built in Lua (in Spanish): [docs/detector-lua.md](docs/detector-lua.md).

## Licence

[AGPL-3.0](LICENSE), the same as KOReader. You may use, modify and redistribute the plugin as long as you share the code under the same licence.

In addition, under section 7(b) of the AGPL, anyone who redistributes the plugin or a work based on it (including just the panel detector) must preserve the attribution to its author. See [NOTICE](NOTICE) for details.
