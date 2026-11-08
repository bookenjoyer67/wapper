#!/usr/bin/env bash
set -uo pipefail

IMG="${1:-}"
shift || true
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
    echo "apply-wallpaper: no such image: ${IMG:-<empty>}" >&2
    exit 1
fi
IMG="$(readlink -f "$IMG")"

LINK="$HOME/.config/backgrounds/current-wallpaper"

# The transition is drawn, not chosen from awww's list: wallfx-gpu paints the
# character's outline over awww and swaps it underneath (see its header). It
# needs the cut-out maps of the NEW image; `wallfx elige` prepares them once
# per wallpaper (cached by path/size/date) and notifies while it works. With no
# character, no maps, or no old image on screen (startup, hotplug), awww changes
# with a plain fade — the wallpaper must change even if the effect cannot play.
OLD_IMG="$(awww query 2>/dev/null | sed -n 's/.*currently displaying: image: //p' | head -n1)"
CHOICE=""
# Only ask for the cut-out when it can actually be used (there is a previous
# image on screen): at startup and on a fresh output this would cost seconds
# and then be thrown away, and the desktop would appear late for nothing.
if [ -n "$OLD_IMG" ] && [ -f "$OLD_IMG" ] && [ "$(readlink -f "$OLD_IMG")" != "$IMG" ] \
   && [ -x "$HOME/.local/bin/wallfx" ]; then
    CHOICE="$("$HOME/.local/bin/wallfx" elige "$IMG" 2>/dev/null || true)"
fi

PAINTED=0
if [ "${CHOICE%% *}" = "perfil" ] && [ -n "$OLD_IMG" ] && [ -f "$OLD_IMG" ] \
   && [ "$(readlink -f "$OLD_IMG")" != "$IMG" ] \
   && [ -x "$HOME/.local/bin/wallfx-gpu" ]; then
    read -r _kind CAMPO LINEA <<<"$CHOICE"
    if "$HOME/.local/bin/wallfx-gpu" "$OLD_IMG" "$IMG" "$CAMPO" "$LINEA" 2>/dev/null; then
        PAINTED=1
    fi
fi
if [ "$PAINTED" -eq 0 ]; then
    if awww img "$IMG" --transition-type fade --transition-duration 0.5 "$@" 2>/dev/null \
       || awww img "$IMG" "$@" 2>/dev/null; then
        PAINTED=1
    elif awww query 2>/dev/null | grep -q "image: $IMG"; then
        PAINTED=1   # already showing this image (awww refuses a no-op re-apply)
    fi
fi
if [ "$PAINTED" -eq 0 ]; then
    echo "apply-wallpaper: awww did not paint $IMG (is awww-daemon running?)" >&2
    exit 1
fi

ln -sf "$IMG" "$LINK"

if command -v matugen >/dev/null 2>&1; then
    if ! matugen image "$IMG" -m dark --prefer darkness --quiet >/dev/null 2>&1; then
        echo "apply-wallpaper: matugen failed — wallpapers will not re-colour" >&2
    fi
fi

if command -v noctalia >/dev/null 2>&1; then
    if ! noctalia msg wallpaper-set "$IMG" >/dev/null 2>&1; then
        echo "apply-wallpaper: noctalia wallpaper-set failed — shell palette stale" >&2
    fi
fi

(
    BRAVE_TPL="$HOME/.local/state/noctalia/community-templates/brave"
    BRAVE_OUT="$HOME/.cache/noctalia/brave-theme/manifest.json"
    if command -v noctalia >/dev/null 2>&1 && [ -f "$BRAVE_TPL/manifest.json" ]; then
        if noctalia theme "$IMG" --scheme "${NOCTALIA_SCHEME:-vibrant}" \
                -r "$BRAVE_TPL/manifest.json:$BRAVE_OUT" >/dev/null 2>&1; then
            bash "$BRAVE_TPL/apply.sh" dark >/dev/null 2>&1 || true
        fi
    fi
) &

if [ -x "$HOME/.local/bin/refresh-lock-backdrops.sh" ]; then
    "$HOME/.local/bin/refresh-lock-backdrops.sh" >/dev/null 2>&1 &
fi
