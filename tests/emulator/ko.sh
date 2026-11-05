#!/bin/sh
# Drives KOReader inside the emulator container (see README.md).
#   ko.sh start <comic> [sidecar]   install the plugin, copy the comic to /books and open it
#   ko.sh shot <name>               screenshot to /out/<name>.png
#   ko.sh tap <x> <y>               tap (screen pixels, 1264×1680)
#   ko.sh hold <x> <y>              long press
#   ko.sh key <key>                 key press (xdotool name: Next, Prior, Escape…)
#   ko.sh stop                      close KOReader (saves settings) and show its log
set -e
W=1264
H=1680
KO=/opt/koreader
CONF=/root/.config/koreader

wait_window() {
    for _ in $(seq 1 60); do
        xdotool search --name KOReader >/dev/null 2>&1 && return 0
        sleep 0.5
    done
    echo "KOReader window not found" >&2
    return 1
}

case "$1" in
start)
    pgrep Xvfb >/dev/null || { Xvfb :99 -screen 0 ${W}x${H}x24 >/dev/null 2>&1 & sleep 1; }
    mkdir -p "$CONF/plugins" /books
    rm -rf "$CONF/plugins/vineta.koplugin"
    cp -r /repo/vineta.koplugin "$CONF/plugins/"
    cp "$2" /books/
    [ -n "$3" ] && cp "$3" /books/
    book="/books/$(basename "$2")"
    cd "$KO"
    EMULATE_READER_W=$W EMULATE_READER_H=$H EMULATE_READER_DPI=300 \
        nohup ./AppRun "$book" > /out/ko.log 2>&1 &
    wait_window
    sleep 4
    ;;
shot)
    import -window root "/out/$2.png"
    ;;
tap)
    xdotool mousemove "$2" "$3" click 1
    sleep 1.5
    ;;
hold)
    xdotool mousemove "$2" "$3" mousedown 1 sleep 1.2 mouseup 1
    sleep 1.5
    ;;
key)
    xdotool search --name KOReader windowactivate --sync >/dev/null 2>&1 || true
    xdotool key "$2"
    sleep 1.5
    ;;
stop)
    pkill -f reader.lua || true
    sleep 2
    grep -i -E "vineta|error|warn" /out/ko.log | tail -40 || true
    ;;
esac
