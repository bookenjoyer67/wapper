#!/usr/bin/env bash
# Keep the current wallpaper painted on every connected, enabled output.
#
# Why this exists: niri 26.04 exposes no output events on its IPC event
# stream, and awww only paints the outputs that exist at the moment
# `awww img` runs -- it does not backfill an output that connects (or
# re-connects) afterwards. The HDMI TV flaps at every boot
# (connect -> disconnect -> reconnect, see `journalctl -b | grep HDMI-A-1`),
# so it routinely ends up with no wallpaper while eDP-1 is fine.
#
# This watches for any enabled output that is not showing an image and
# re-applies the current wallpaper to all outputs. Cheap: three short-lived
# processes every INTERVAL seconds, and it does nothing when all is well.
set -uo pipefail

LINK="$HOME/.config/backgrounds/current-wallpaper"
CACHE_DIR="$HOME/.cache/wallpaper"
INTERVAL=3

log() { printf '[wallpaper-hotplug] %s\n' "$*"; }

# Same wallpaper fetch-wallpaper.sh cached (there is only ever one file).
current_image() {
    local img=""
    [ -L "$LINK" ] && img="$(readlink -f "$LINK" 2>/dev/null || true)"
    if [ -z "$img" ] || [ ! -f "$img" ]; then
        img="$(ls "$CACHE_DIR"/wallpaper.* 2>/dev/null | head -n 1)"
    fi
    printf '%s' "$img"
}

heal_if_needed() {
    awww query &>/dev/null || return 0            # daemon not up yet

    local enabled shown o line
    # Outputs niri considers connected AND enabled (logical is null when off).
    enabled="$(niri msg --json outputs 2>/dev/null \
        | jq -r 'to_entries[] | select(.value.logical != null) | .key')"
    [ -z "$enabled" ] && return 0

    shown="$(awww query 2>/dev/null)"

    while IFS= read -r o; do
        [ -z "$o" ] && continue
        line="$(printf '%s\n' "$shown" | grep -F ": $o: " | head -n1)"
        case "$line" in
            *"image:"*) ;;                        # already painted, nothing to do
            *)                                    # missing entirely, or a solid color
                local img; img="$(current_image)"
                if [ -n "$img" ]; then
                    log "output $o has no image; applying $(basename "$img")"
                    awww img "$img" --transition-type none 2>/dev/null
                fi
                return 0
                ;;
        esac
    done <<<"$enabled"
}

while :; do
    sleep "$INTERVAL"
    heal_if_needed
done
