#!/usr/bin/env bash
# fetch-wallpaper.sh — pull ONE random wallpaper from the source and cache it.
#
# Source: wallhaven.cc. The look is psychedelic, with surreal, vaporwave and
# synthwave mixed in, and anime-category psychedelia included (see POOL below).
# SFW only (purity=100), at least 2560x1440, 16:9 / 16:10 / 21:9.
#
# This replaces the old "folder full of wallpapers" model: the cache holds
# exactly ONE image at a time and is overwritten on every fetch.
#
# On success it prints the path of the cached image (exit 0).
# If the API/download fails it falls back to the cached image (exit 0) so a
# session can still start offline; only a total miss exits 1.
#
# Swipe-reject: wallhaven ids listed one-per-line in $CACHE_DIR/rejected are
# never returned (see swipe-delete-wallpaper.sh).
#
# See which query was used: WALLPAPER_DEBUG=1 bash fetch-wallpaper.sh
set -euo pipefail

CACHE_DIR="$HOME/.cache/wallpaper"
REJECTED="$CACHE_DIR/rejected"
RECENT="$CACHE_DIR/recent"
STATE_ID="$CACHE_DIR/current.id"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
MIN_BYTES=100000
# Default minimum resolution for a pick.
MIN_RES="2560x1440"
# Psychedelic means vivid: mean HSL saturation below this is treated as a dud
# and re-rolled (dark game art, greyscale minimalism, muted landscapes).
MIN_SATURATION="${WALLPAPER_MIN_SAT:-0.30}"
MAX_ATTEMPTS=4

# Query pool: one search term per line, read from $WALLPAPER_POOL
# (default ~/.config/wallpaper/pool.txt). Blank lines are skipped.
POOL_FILE="${WALLPAPER_POOL:-$HOME/.config/wallpaper/pool.txt}"
CATEGORIES="111"

if [ ! -r "$POOL_FILE" ]; then
    echo "fetch-wallpaper: no query pool at $POOL_FILE" >&2
    exit 1
fi
mapfile -t POOL < <(sed -e 's/[[:space:]]*$//' -e '/^[[:space:]]*$/d' "$POOL_FILE")
if [ "${#POOL[@]}" -eq 0 ]; then
    echo "fetch-wallpaper: $POOL_FILE is empty" >&2
    exit 1
fi

mkdir -p "$CACHE_DIR"
touch "$REJECTED" "$RECENT"

cached() { ls "$CACHE_DIR"/wallpaper.* 2>/dev/null | head -n1; }

# Remember the last few shown ids (ring buffer) so the next switch does not
# land on an image already on screen.
remember() {
    local id="$1"
    grep -qxF -- "$id" "$RECENT" 2>/dev/null || printf '%s\n' "$id" >> "$RECENT"
    tail -n 30 "$RECENT" > "$RECENT.tmp" 2>/dev/null && mv "$RECENT.tmp" "$RECENT"
}

# Mean saturation (0..1) via ImageMagick. Empty when it is not installed.
saturation() {
    local im
    if command -v magick >/dev/null 2>&1; then im=magick
    elif command -v convert >/dev/null 2>&1; then im=convert
    else return 0; fi
    "$im" "$1" -colorspace HSL -channel G -separate -format '%[fx:mean]' info: 2>/dev/null
}

# True when the image is vivid enough to pass as psychedelic.
vivid_enough() {
    local sat
    sat="$(saturation "$1")"
    # no ImageMagick / unreadable → do not block the wallpaper on it
    [ -n "${sat:-}" ] || return 0
    awk -v s="$sat" -v m="$MIN_SATURATION" 'BEGIN { exit !(s >= m) }'
}

# Pick a random result from a random pool entry, skipping rejected ids.
# Prints "id<TAB>path" (or nothing when every result was rejected).
pick() {
    local term="${POOL[$((RANDOM % ${#POOL[@]}))]}"
    local qq seed idx recfile
    qq="$(printf '%s' "$term" | sed 's/ /%20/g')"
    seed="$RANDOM$RANDOM$RANDOM"
    idx="$RANDOM"
    recfile="$RECENT"
    # SKIP_RECENT is set on the final attempt: stop excluding recent picks so a
    # small pool cannot dead-end into "no image".
    if [ -n "${SKIP_RECENT:-}" ]; then
        recfile=/dev/null
    fi

    if [ -n "${WALLPAPER_DEBUG:-}" ]; then
        printf 'fetch-wallpaper: q=%s\n' "$term" >&2
    fi

    curl -fsS --max-time 30 -A "$UA" \
        "https://wallhaven.cc/api/v1/search?q=$qq&categories=$CATEGORIES&purity=100&atleast=$MIN_RES&ratios=16x9,16x10,21x9&sorting=random&seed=$seed&page=1" 2>/dev/null \
    | jq -r --rawfile rej "$REJECTED" --rawfile rec "$recfile" --argjson idx "$idx" '
        # skip swiped-away ids AND the last few we already showed, so a switch
        # never lands on the image that is already on screen
        (($rej | split("\n") | map(select(length > 0)))
         + ($rec | split("\n") | map(select(length > 0)))) as $skip
        | [ .data[] | select(([.id] | inside($skip)) | not) ] as $ok
        | select(($ok | length) > 0)
        # quality floor: pick at random out of the top half of this page by
        # favourites. Taking only the top 3 funnelled every switch into the
        # same handful of popular images (the duplicate problem); half the
        # page keeps a floor without shrinking the pool.
        | ($ok | sort_by(-.favorites) | .[0:12]) as $top
        | $top[ ($idx % ($top | length)) ]
        | "\(.id)\t\(.path)"
      '
}

# Download id/path into the single-file cache. Prints the saved path.
download() {
    local id="$1" url="$2" ext dest tmp size
    ext="${url##*.}"; ext="${ext%%\?*}"
    dest="$CACHE_DIR/wallpaper.$ext"
    tmp="$dest.part"
    if ! curl -fsS --max-time 120 -A "$UA" -o "$tmp" "$url"; then
        rm -f "$tmp"; return 1
    fi
    size="$(stat -c %s "$tmp" 2>/dev/null || echo 0)"
    if [ "$size" -lt "$MIN_BYTES" ]; then
        rm -f "$tmp"; return 1
    fi
    mv -f "$tmp" "$dest"
    # drop any stale image left from a previous extension (.jpg vs .png)
    find "$CACHE_DIR" -maxdepth 1 -type f -name 'wallpaper.*' \
        ! -name "wallpaper.$ext" -delete 2>/dev/null || true
    printf '%s\n' "$id" > "$STATE_ID"
    # append-only history for the wallpaper browser (recent stays a 30-entry ring)
    printf '%s\t%s\n' "$id" "$(date +%s)" >> "$CACHE_DIR/history"
    tail -n 1000 "$CACHE_DIR/history" > "$CACHE_DIR/history.tmp" 2>/dev/null \
        && mv "$CACHE_DIR/history.tmp" "$CACHE_DIR/history"
    printf '%s\n' "$dest"
}

# Serialize fetches. Rapid repeated keypresses would otherwise run two fetches
# at once, both writing $CACHE_DIR/wallpaper.*.part and both running the
# stale-extension cleanup — which can leave a partial file or delete the image
# the other run just saved.
LOCK="$CACHE_DIR/.fetch.lock"
exec 9>"$LOCK"
if ! flock -w 25 9; then
    echo "fetch-wallpaper: another fetch is already running" >&2
    if img="$(cached)" && [ -n "$img" ]; then
        printf '%s\n' "$img"
        exit 0
    fi
    exit 1
fi

# We hold the lock, so any .part here is a leftover from a killed run.
rm -f "$CACHE_DIR"/wallpaper.*.part 2>/dev/null || true

attempt=0
chosen=""
while [ "$attempt" -lt "$MAX_ATTEMPTS" ]; do
    attempt=$((attempt + 1))
    if [ "$attempt" -eq "$MAX_ATTEMPTS" ]; then
        SKIP_RECENT=1
    fi
    entry="$(pick || true)"
    if [ -z "$entry" ]; then
        continue
    fi

    id="${entry%%$'\t'*}"
    url="${entry#*$'\t'}"
    if ! dest="$(download "$id" "$url")"; then
        continue
    fi

    if vivid_enough "$dest"; then
        chosen="$dest"
        remember "$id"
        break
    fi
    if [ -n "${WALLPAPER_DEBUG:-}" ]; then
        printf 'fetch-wallpaper: %s too dull, re-rolling\n' "$id" >&2
    fi
done

if [ -n "$chosen" ]; then
    printf '%s\n' "$chosen"
    exit 0
fi

# Every attempt was dull, or the network/API failed: the last download (if any)
# is already in the cache, so keep showing it rather than nothing.
if img="$(cached)" && [ -n "$img" ]; then
    printf '%s\n' "$img"
    exit 0
fi

echo "fetch-wallpaper: no image available (fetch failed and no cache)" >&2
exit 1
