#!/usr/bin/env bash
# apply-wallpaper.sh — THE single place that applies a wallpaper.
#
# Every wallpaper path (startup, random-switch, swipe-delete, rotation) calls
# this, so the desktop stays in sync in one shot:
#
#   1. awww paints the image (awww owns the wallpaper on this box;
#      Noctalia's own [wallpaper] enabled = false).
#   2. ~/.config/backgrounds/current-wallpaper is repointed (lockscreen,
#      hotplug healer and other consumers read this symlink).
#   3. matugen regenerates the app palettes (kitty / nvim).
#   4. Noctalia is handed the image, so its shell palette (bar, panels,
#      widgets, OSD) is re-extracted from the wallpaper — theme.source is
#      "wallpaper", but Noctalia only samples what it is told about.
#
# Usage: apply-wallpaper.sh <image> [extra awww img args...]
#
# NOTE: app theme templates (noctalia msg templates-apply) are deliberately
# NOT run here — they rewrite external app configs (vscode, neovim, obsidian,
# ...) and we do not want that on every wallpaper swipe. Run it by hand when
# you want the app palettes refreshed too.
set -uo pipefail

IMG="${1:-}"
shift || true
if [ -z "$IMG" ] || [ ! -f "$IMG" ]; then
    echo "apply-wallpaper: no such image: ${IMG:-<empty>}" >&2
    exit 1
fi
IMG="$(readlink -f "$IMG")"

LINK="$HOME/.config/backgrounds/current-wallpaper"

# 1. paint
# The exit status of the whole script is what the Noctalia wallpaper browser
# reports as "Could not apply wallpaper", so make that status mean exactly one
# thing: the wallpaper did not land. Palette/template failures below are warned
# about and downgraded, because the image IS on screen at that point.
PAINTED=0
if awww img "$IMG" --transition-type random --transition-duration 2 "$@" 2>/dev/null \
   || awww img "$IMG" "$@" 2>/dev/null; then
    PAINTED=1
elif awww query 2>/dev/null | grep -q "image: $IMG"; then
    PAINTED=1   # already showing this image (awww refuses a no-op re-apply)
fi
if [ "$PAINTED" -eq 0 ]; then
    echo "apply-wallpaper: awww did not paint $IMG (is awww-daemon running?)" >&2
    exit 1
fi

# 2. remember
ln -sf "$IMG" "$LINK"

# 3. app palettes (kitty, nvim, starship, lock palette). A failure here means the
#    image is painted but the theme did not follow — say so instead of exiting
#    silently, which is what made "applied but nothing changed" so confusing.
if command -v matugen >/dev/null 2>&1; then
    if ! matugen image "$IMG" -m dark --prefer darkness --quiet >/dev/null 2>&1; then
        echo "apply-wallpaper: matugen failed — wallpapers will not re-colour" >&2
    fi
fi

# 4. Noctalia shell palette follows the wallpaper
if command -v noctalia >/dev/null 2>&1; then
    if ! noctalia msg wallpaper-set "$IMG" >/dev/null 2>&1; then
        echo "apply-wallpaper: noctalia wallpaper-set failed — shell palette stale" >&2
    fi
fi

# 5. Brave theme (Noctalia community "brave" template). Noctalia only re-renders
#    community templates on an explicit `templates-apply`, which this rice does
#    NOT run on every wallpaper change because it also rewrites vscode/obsidian/
#    neovim configs. Render just the Brave manifest here instead, with the same
#    scheme the shell uses (settings.toml: wallpaper_scheme), then reinstall the
#    unpacked theme. Brave itself only re-reads prefs on start, so the seed
#    (user_color) lands the next time the browser is launched.
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

# 6. lockscreen backdrops (swaylock draws a pre-graded image per output; baking it
#    here keeps the lock instant instead of grading on the first lock after a change)
if [ -x "$HOME/.local/bin/refresh-lock-backdrops.sh" ]; then
    "$HOME/.local/bin/refresh-lock-backdrops.sh" >/dev/null 2>&1 &
fi

