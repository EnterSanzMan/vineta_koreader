# Viñeta pour KOReader

[English](README.md) · [Español](README.es.md) · [Português](README.pt.md) · **Français** · [Deutsch](README.de.md)

> **Basé sur [Viñeta](https://play.google.com/store/apps/details?id=com.dsp.vineta), l'application Android pour lire les BD case par case.**
> Ce plugin apporte aux liseuses e-ink sous KOReader le même détecteur de cases que l'application.

<a href="https://play.google.com/store/apps/details?id=com.dsp.vineta"><img alt="Disponible sur Google Play" src="https://play.google.com/intl/fr/badges/static/images/badges/fr_badge_web_generic.png" height="64"></a>

Plugin [KOReader](https://koreader.rocks) pour lire les BD **case par case** sur les liseuses e-ink. C'est la liseuse elle-même qui trouve les cases avec le détecteur de Viñeta, pendant la lecture : rien à préparer sur l'ordinateur et le fichier de la BD n'est pas modifié.

> **Remarque :** pour l'instant, les menus du plugin sont en espagnol. Ci-dessous, les options sont citées telles qu'elles apparaissent à l'écran, suivies de leur traduction.

## Installation

1. Installez [KOReader](https://github.com/koreader/koreader/releases) sur votre liseuse.
2. Copiez le dossier `vineta.koplugin` dans le dossier `plugins` de KOReader. Par exemple :
   - PocketBook : `applications/koreader/plugins/`
   - Kobo : `.adds/koreader/plugins/`
   - Kindle : `koreader/plugins/`
3. Redémarrez KOReader et ouvrez une BD CBZ ou CBR depuis son explorateur de fichiers.

## Lecture

La BD s'ouvre automatiquement en mode case par case. Chaque page s'affiche d'abord en entier, puis case par case. Les grandes cases, qui ne gagneraient presque rien à être agrandies à l'écran, s'affichent en deux moitiés : d'abord la gauche, puis la droite. Si la BD contient un `ComicInfo.xml` indiquant qu'il s'agit d'un manga, elle se lit de droite à gauche sans rien régler. Un petit nombre dans le coin (« 3/7 ») indique à quelle étape de la page vous êtes.

Chaque page est analysée en arrière-plan la première fois qu'elle est lue, et le résultat est enregistré : quand vous revenez à la BD, plus besoin d'attendre.

Le menu de KOReader → onglet de navigation → « Viñeta a viñeta » (case par case) contient l'interrupteur **« Activado »** (activé) pour allumer ou éteindre le plugin. C'est aussi par là que l'on entre dans le mode avec un PDF, ou si on en est sorti.

| | |
|---|---|
| Toucher à droite / bouton suivant | Case suivante |
| Toucher à gauche / bouton précédent | Case précédente |
| Appui long | Page entière ↔ case |
| Pincer (rapprocher deux doigts) / glisser vers le haut ou le bas | Désactiver le zoom : pages entières, on passe de page en page |
| Écarter deux doigts / glisser vers le haut ou le bas | Réactiver le zoom : case par case à partir de la première case |
| Toucher au centre | Menu (sens manga, zoom, page entière, quitter) |

Sans zoom, le coin affiche « sin zoom » (sans zoom). Chaque BD se souvient si vous l'avez quittée avec le zoom activé ou désactivé.

Dans le menu « Viñeta a viñeta » de KOReader, vous pouvez aussi :

- commencer chaque page en entier ou directement par sa première case ;
- couper en deux moitiés les cases qui ne gagnent pas 10, 20, 30 ou 50 % en largeur, ou aucune ;
- zoomer sur les bulles des cases très larges ou très hautes ;
- voir d'abord chaque moitié des doubles pages ;
- augmenter le contraste (les BD en couleur paraissent délavées en 16 niveaux de gris) ;
- masquer le numéro d'étape ;
- choisir la fréquence du rafraîchissement complet de l'écran, y compris « au changement de page » ;
- analyser 2 pages à l'avance, 5 ou toute la BD, et choisir l'analyse rapide (moins précise) ;
- relancer la détection des cases d'une BD.

Dans « Toques y gestos » (appuis et gestes), vous pouvez associer à un geste l'action « Activar o desactivar Viñeta a viñeta » (activer ou désactiver le case par case).

Comment le détecteur est écrit en Lua (en espagnol) : [docs/detector-lua.md](docs/detector-lua.md).

## Licence

[AGPL-3.0](LICENSE), la même que KOReader. Vous pouvez utiliser, modifier et redistribuer le plugin à condition de partager le code sous la même licence.

En outre, en vertu de l'article 7 b) de l'AGPL, quiconque redistribue le plugin ou une œuvre dérivée (y compris le seul détecteur de cases) doit conserver l'attribution à son auteur. Les détails figurent dans [NOTICE](NOTICE).
