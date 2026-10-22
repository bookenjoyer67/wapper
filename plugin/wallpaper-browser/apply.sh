#!/usr/bin/env bash
# Apply one wallhaven result by id + full-image URL.
#
# Mirrors what fetch-wallpaper.sh's download() records (single-file cache,
# current.id, the recent ring buffer) and then hands the image to
# apply-wallpaper.sh, which is the one place that paints (awww), regenerates
# the legacy palettes (matugen), feeds the Noctalia shell palette and refreshes
# the lock backdrops.
#
# Usage: apply.sh <wallhaven-id> <full-image-url>
set -uo pipefail

ID="${1:-}"
URL="${2:-}"
if [ -z "$ID" ] || [ -z "$URL" ]; then
    echo "apply.sh: usage: apply.sh <id> <url>" >&2
    exit 2
fi

CACHE_DIR="$HOME/.cache/wallpaper"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
MIN_BYTES=100000

ext="${URL##*.}"
ext="${ext%%\?*}"
case "$ext" in
    jpg|jpeg|png|webp) ;;
    *) ext="jpg" ;;
esac

mkdir -p "$CACHE_DIR"
dest="$CACHE_DIR/wallpaper.$ext"
tmp="$dest.part"

# Bounded well under Noctalia's 60 s runAsync clamp (see panel.luau apply()).
if ! curl -fsS --connect-timeout 10 --max-time 45 -A "$UA" -o "$tmp" "$URL"; then
    rm -f "$tmp"
    echo "apply.sh: download failed for $ID" >&2
    exit 1
fi

size="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"
if [ "$size" -lt "$MIN_BYTES" ]; then
    rm -f "$tmp"
    echo "apply.sh: download too small ($size bytes)" >&2
    exit 1
fi

mv -f "$tmp" "$dest"
find "$CACHE_DIR" -maxdepth 1 -type f -name 'wallpaper.*' ! -name "wallpaper.$ext" -delete 2>/dev/null || true
printf '%s\n' "$ID" > "$CACHE_DIR/current.id"
# append-only history for the browser (recent stays the 30-entry ring buffer)
printf '%s\t%s\n' "$ID" "$(date +%s)" >> "$CACHE_DIR/history"
tail -n 1000 "$CACHE_DIR/history" > "$CACHE_DIR/history.tmp" 2>/dev/null \
    && mv "$CACHE_DIR/history.tmp" "$CACHE_DIR/history"
grep -qxF -- "$ID" "$CACHE_DIR/recent" 2>/dev/null || printf '%s\n' "$ID" >> "$CACHE_DIR/recent"
tail -n 30 "$CACHE_DIR/recent" > "$CACHE_DIR/recent.tmp" 2>/dev/null && mv "$CACHE_DIR/recent.tmp" "$CACHE_DIR/recent"

# The scripts live in the niri config dir (that is what config.kdl spawns);
# ~/.local/bin is only a legacy fallback. WALLPAPER_SCRIPTS still wins.
SCRIPTS_DIR="${WALLPAPER_SCRIPTS:-}"
if [ -z "$SCRIPTS_DIR" ]; then
    for candidate in "$HOME/.config/niri/scripts" "$HOME/.local/bin"; do
        if [ -x "$candidate/apply-wallpaper.sh" ]; then
            SCRIPTS_DIR="$candidate"
            break
        fi
    done
fi
if [ -z "$SCRIPTS_DIR" ] || [ ! -x "$SCRIPTS_DIR/apply-wallpaper.sh" ]; then
    echo "apply.sh: apply-wallpaper.sh not found (looked in \$WALLPAPER_SCRIPTS, $HOME/.config/niri/scripts, $HOME/.local/bin)" >&2
    exit 127
fi

exec bash "$SCRIPTS_DIR/apply-wallpaper.sh" "$dest"
