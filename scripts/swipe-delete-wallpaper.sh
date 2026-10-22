#!/usr/bin/env bash
# Tinder-swipe wallpaper rejection — SUPER+X by default.
#
# With a remote source there is no local file to delete, so "reject" means
# "never show me this one again": the id of the wallpaper currently on screen
# is added to the reject list, then a fresh random one is fetched and applied.
set -euo pipefail

CACHE_DIR="$HOME/.cache/wallpaper"
REJECTED="$CACHE_DIR/rejected"
STATE_ID="$CACHE_DIR/current.id"
LINK="$HOME/.config/backgrounds/current-wallpaper"
DER="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
FETCH="$DER/fetch-wallpaper.sh"
MAX_REJECT=500

mkdir -p "$CACHE_DIR"
touch "$REJECTED"

# Identify what is showing right now: the id we recorded on the last fetch,
# or otherwise parse it back out of the wallhaven-<id>.<ext> filename.
cur_id=""
if [ -f "$STATE_ID" ]; then
    cur_id="$(tr -d '[:space:]' < "$STATE_ID")"
fi
if [ -z "$cur_id" ]; then
    cur_path="$(readlink -f "$LINK" 2>/dev/null || true)"
    [ -n "$cur_path" ] && cur_id="$(basename "$cur_path" | sed -n 's/^wallhaven-\(.*\)\..*$/\1/p')"
fi

if [ -z "$cur_id" ]; then
    notify-send -a "wallpaper" "Swipe-reject" "Could not determine current wallpaper" 2>/dev/null || true
    exit 1
fi

# Blocklist it (idempotent), then cap the list so it can't grow forever.
grep -qxF -- "$cur_id" "$REJECTED" 2>/dev/null || printf '%s\n' "$cur_id" >> "$REJECTED"
tail -n "$MAX_REJECT" "$REJECTED" > "$REJECTED.tmp" && mv "$REJECTED.tmp" "$REJECTED"
echo "rejected: $cur_id"

img="$(bash "$FETCH" 2>/dev/null || true)"
if [ -n "$img" ]; then
    bash "$DER/apply-wallpaper.sh" "$img"
    echo "now showing: $img"
    notify-send -a "wallpaper" "Swipe-reject" "Banned $cur_id
Now showing $(basename "$img")" 2>/dev/null || true
else
    notify-send -a "wallpaper" "Swipe-reject" "No replacement available" 2>/dev/null || true
fi
