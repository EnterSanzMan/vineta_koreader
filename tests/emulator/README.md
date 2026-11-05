# Emulador de KOReader en Docker

KOReader de escritorio (AppImage x86_64) en una pantalla virtual de 1264×1680. Sirve para probar el plugin sin el lector: se maneja con toques y teclas simuladas (`xdotool`) y se ven capturas.

**Disco de Docker:** desde el 2026-11-04, el disco de datos de Docker (distro WSL `docker-desktop-data`) está en `D:\Docker\wsl\data\ext4.vhdx`. Se movió con `wsl --export` / `--unregister` / `--import` porque C: se había llenado. Si Docker Desktop se reinstala o se purgan sus datos, puede volver a crearlo en C:.

## Preparar (una vez)

1. Descargar `koreader-v2026.07.1-x86_64.AppImage` de las releases de KOReader en GitHub y guardarlo como `tests/emulator/.cache/koreader.AppImage` (carpeta ignorada por git).
2. Construir la imagen y extraer KOReader dentro de un contenedor:

```bash
export MSYS_NO_PATHCONV=1   # en Git Bash, para que no reescriba las rutas
docker --context desktop-linux build -t vineta-koreader-emu tests/emulator
docker --context desktop-linux run -d --name koemu -v "D:/Code/vineta-koreader:/repo" -v "D:/Code/vineta-koreader/tests/emulator/.cache:/kodl:ro" -v "D:/Code/vineta-koreader/tests/emulator/.cache/out:/out" vineta-koreader-emu sleep infinity
docker --context desktop-linux exec koemu sh -c 'cp /kodl/koreader.AppImage /tmp/k && chmod +x /tmp/k && cd /opt && /tmp/k --appimage-extract >/dev/null && mv squashfs-root koreader'
```

## Usar

```bash
docker --context desktop-linux exec koemu luajit tests/lua/panels_spec.lua
docker --context desktop-linux exec koemu sh tests/emulator/ko.sh start tests/fixtures/sintetico.cbz tests/fixtures/sintetico.panels.json
docker --context desktop-linux exec koemu sh tests/emulator/ko.sh shot 01-abierto
docker --context desktop-linux exec koemu sh tests/emulator/ko.sh tap 1100 840
docker --context desktop-linux exec koemu sh tests/emulator/ko.sh key Next
docker --context desktop-linux exec koemu sh tests/emulator/ko.sh hold 632 840
docker --context desktop-linux exec koemu sh tests/emulator/ko.sh stop
```

- **Capturas y registro:** van a `tests/emulator/.cache/out/` (`ko.log` es la salida de KOReader).
- **Teclas:** en el emulador, `Next`/`Prior` (AvPág/RePág) hacen de botones de página.
- **Al terminar:** `docker --context desktop-linux rm -f koemu`.
