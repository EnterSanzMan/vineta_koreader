# KOReader de escritorio (AppImage x86_64) en una pantalla virtual, para probar el plugin
# sin el lector. Ver tests/emulator/README.md.
FROM ubuntu:24.04
RUN apt-get update && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        xvfb xdotool imagemagick x11-utils luajit ca-certificates \
        libglib2.0-0t64 libgl1 libegl1 libxkbcommon0 \
    && rm -rf /var/lib/apt/lists/*
ENV DISPLAY=:99
WORKDIR /repo
