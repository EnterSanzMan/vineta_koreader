# Viñeta para KOReader

[English](README.md) · **Español** · [Português](README.pt.md) · [Français](README.fr.md) · [Deutsch](README.de.md)

> **Basado en [Viñeta](https://play.google.com/store/apps/details?id=com.dsp.vineta), la app de Android para leer cómics viñeta a viñeta.**
> Este plugin lleva a los lectores e-ink con KOReader el mismo detector de viñetas de la app.

<a href="https://play.google.com/store/apps/details?id=com.dsp.vineta"><img alt="Disponible en Google Play" src="https://play.google.com/intl/es/badges/static/images/badges/es_badge_web_generic.png" height="64"></a>

Plugin de [KOReader](https://koreader.rocks) para leer cómics **viñeta a viñeta** en lectores e-ink. Las viñetas las busca el propio lector con el detector de Viñeta, mientras lees: no hay que preparar nada en el PC y el cómic no se modifica.

## Instalar

1. Instala [KOReader](https://github.com/koreader/koreader/releases) en tu lector.
2. Copia la carpeta `vineta.koplugin` dentro de la carpeta `plugins` de KOReader. Por ejemplo:
   - PocketBook: `applications/koreader/plugins/`
   - Kobo: `.adds/koreader/plugins/`
   - Kindle: `koreader/plugins/`
3. Reinicia KOReader y abre un cómic CBZ o CBR desde su explorador de archivos.

## Leer

El cómic se abre solo en el modo viñeta a viñeta. Cada página se ve primero entera y después viñeta a viñeta. Las viñetas grandes, que casi no se agrandarían en la pantalla, se ven en dos mitades: primero la izquierda y luego la derecha. Si el cómic trae un `ComicInfo.xml` que dice que es manga, se lee de derecha a izquierda sin tocar nada. Un número pequeño en la esquina («3/7») indica por qué paso de la página vas.

Cada página se analiza en segundo plano la primera vez que se lee, y lo detectado se guarda: al volver al cómic ya no hay que esperar.

El menú de KOReader → pestaña de navegación → «Viñeta a viñeta» tiene el interruptor **«Activado»** para encender o apagar el plugin. Desde ahí también se entra en el modo con un PDF o si saliste de él.

| | |
|---|---|
| Toque a la derecha / botón de avance | Siguiente viñeta |
| Toque a la izquierda / botón de retroceso | Viñeta anterior |
| Pulsación larga | Página completa ↔ viñeta |
| Pellizcar (juntar dos dedos) / deslizar arriba o abajo | Desactivar el zoom: páginas enteras, se pasa de página en página |
| Separar dos dedos / deslizar arriba o abajo | Volver a activar el zoom: viñeta a viñeta desde la primera viñeta |
| Toque en el centro | Menú (sentido manga, zoom, página completa, salir) |

Sin zoom, la esquina muestra «sin zoom». Cada cómic recuerda si lo dejaste con el zoom activado o desactivado.

En el menú «Viñeta a viñeta» de KOReader también puedes:

- empezar cada página entera o directamente en su primera viñeta;
- partir en dos mitades las viñetas que no ganan un 10, 20, 30 o 50 % de ancho, o ninguna;
- hacer zoom a los bocadillos de las viñetas muy anchas o muy altas;
- ver primero cada mitad de las páginas dobles;
- subir el contraste (los cómics en color salen lavados en 16 grises);
- ocultar el número de paso;
- elegir cada cuánto se limpia la pantalla, también «al cambiar de página»;
- analizar 2 páginas por delante, 5 o el cómic entero, y elegir el análisis rápido (menos preciso);
- volver a buscar las viñetas de un cómic.

En «Toques y gestos» puedes asignar a un gesto «Activar o desactivar Viñeta a viñeta».

Cómo está hecho el detector en Lua: [docs/detector-lua.md](docs/detector-lua.md).

## Licencia

[AGPL-3.0](LICENSE), la misma que KOReader. Puedes usar, modificar y redistribuir el plugin siempre que compartas el código con la misma licencia.

Además, con el apartado 7 b) de la AGPL, quien redistribuya el plugin o una obra derivada (también solo el detector de viñetas) debe conservar la atribución a su autor. Los detalles están en [NOTICE](NOTICE).
