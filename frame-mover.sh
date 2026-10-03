#!/usr/bin/env bash
# frame-mover.sh — while running, watch for the portal's virtual screen and
# send game windows to it. Existing game windows are moved DELAY seconds after
# the screen appears; games launched afterwards are moved as they open.
#
# Tunables (env):
#   VIRT_PREFIX  output-name prefix to match      (default: Virtual-)
#   GAME_RE      JS regex vs. window class/app_id (default: steam_app_|\.exe$)
#                no forward slashes — it's spliced into a /regex/ literal
#   DELAY        seconds to wait after detection   (default: 5)
#   POLL         poll interval in seconds          (default: 2)

set -uo pipefail

PREFIX="${VIRT_PREFIX:-Virtual-}"
GAME_RE="${GAME_RE:-steam_app_|\\.exe\$}"
DELAY="${DELAY:-5}"
POLL="${POLL:-2}"
NAME="frame-mover"
JS="${XDG_RUNTIME_DIR:-/tmp}/${NAME}.js"

QDBUS=$(command -v qdbus6 || command -v qdbus-qt6 || command -v qdbus || true)
[[ -n $QDBUS ]] || { echo "qdbus not found (install qt6-tools)" >&2; exit 1; }
command -v kscreen-doctor >/dev/null || { echo "kscreen-doctor not found" >&2; exit 1; }

scripting() { "$QDBUS" org.kde.KWin /Scripting "org.kde.kwin.Scripting.$1" "${@:2}"; }

# Prints "name uuid" of the virtual output, or nothing if absent.
virt_id() {
    kscreen-doctor -o 2>/dev/null \
        | sed 's/\x1b\[[0-9;]*m//g' \
        | awk -v p="$PREFIX" '$1=="Output:" && index($3,p)==1 {print $3, $4; exit}'
}

write_js() {
    cat >"$JS" <<EOF
const re = /${GAME_RE}/i;
const prefix = "${PREFIX}";

function target() {
    return workspace.screens.find(s => s.name.startsWith(prefix));
}

function move(w) {
    if (!w || !w.normalWindow || !re.test(w.resourceClass)) return;
    const out = target();
    if (!out || w.output === out) return;
    const fs = w.fullScreen;
    if (fs) w.fullScreen = false;          // un-fullscreen so it can migrate
    workspace.sendClientToScreen(w, out);
    if (fs) w.fullScreen = true;           // re-fullscreen on the new output
    print("${NAME}: moved " + w.resourceClass + " -> " + out.name);
}

workspace.windowList().forEach(move);
workspace.windowAdded.connect(move);
EOF
}

unload() {
    if [[ $(scripting isScriptLoaded "$NAME" 2>/dev/null) == "true" ]]; then
        scripting unloadScript "$NAME" >/dev/null
    fi
}

load() {
    unload
    write_js
    local id
    id=$(scripting loadScript "$JS" "$NAME") || { echo "loadScript failed" >&2; return 1; }
    # KWin 6 path first, older layout as fallback.
    "$QDBUS" org.kde.KWin "/Scripting/Script${id}" org.kde.kwin.Script.run 2>/dev/null \
        || "$QDBUS" org.kde.KWin "/${id}" org.kde.kwin.Script.run
}

cleanup() { unload; rm -f "$JS"; }
trap cleanup EXIT
trap 'exit 0' INT TERM

echo "frame-mover: watching for '${PREFIX}*' (Ctrl-C to stop)"
current=""
while :; do
    v=$(virt_id)
    if [[ -n $v && $v != "$current" ]]; then
        echo "virtual screen detected: $v — waiting ${DELAY}s"
        sleep "$DELAY"
        if [[ $(virt_id) == "$v" ]]; then
            load && echo "mover active on ${v%% *}"
            current=$v
        fi
    elif [[ -z $v && -n $current ]]; then
        echo "virtual screen gone — mover unloaded"
        unload
        current=""
    fi
    sleep "$POLL"
done
