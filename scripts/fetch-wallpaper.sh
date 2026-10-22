#!/usr/bin/env bash
# fetch-wallpaper.sh — pull ONE random wallpaper from the source and cache it.
#
# Source: wallhaven.cc. The look is psychedelic, with surreal, vaporwave and
# synthwave mixed in, and anime-category psychedelia included (see the pool).
#
# Where the pick comes from is the `source` setting in
# ~/.config/wallpaper/settings (or $WALLPAPER_SOURCE, or the pool file):
#
#   pool       a random term from the query list (weighted: "term * 3")
#   query      the `query` setting as one search term
#   favorites  a random id from ~/.config/wallpaper/favorites, resolved
#              through the public /api/v1/w/<id> endpoint (no key needed)
#
# `set = <name>` swaps the query list for ~/.config/wallpaper/sets/<name>.txt.
# `nsfw` picks the purity: off → 100 (SFW), sketchy → 110, all → 111; sketchy
# and all only return anything beyond SFW with an `apikey`, which is appended
# to the API call when set. WALLPAPER_* environment variables win over the file.
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
# See the full request URL (query, purity, apikey): WALLPAPER_DEBUG=1.
# WALLPAPER_DRY_RUN=1 prints the settings and the URL it would request, then
# exits 0 without touching the cache or the network.
set -euo pipefail

DER="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$DER/read-settings.sh"
ws_apply

CACHE_DIR="$HOME/.cache/wallpaper"
REJECTED="$CACHE_DIR/rejected"
RECENT="$CACHE_DIR/recent"
STATE_ID="$CACHE_DIR/current.id"
UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
MIN_BYTES=100000
# Default minimum resolution for a pick (from the settings file).
MIN_RES="$WS_MIN_RES"
# Psychedelic means vivid: mean HSL saturation below this is treated as a dud
# and re-rolled (dark game art, greyscale minimalism, muted landscapes).
MIN_SATURATION="$WS_MIN_SAT"
MAX_ATTEMPTS=4

# The query list to draw from: the pool file, or sets/<name>.txt when `set` is
# non-empty (resolved once, in read-settings.sh).
LIST_FILE="$WS_LIST_FILE"
CATEGORIES="111"
SOURCE="$WS_SOURCE"
QE="$WS_QUERY"
NSFW="$WS_NSFW"
PURITY="$WS_PURITY"
APIKEY="$WS_APIKEY"
FAV_FILE="$WS_FAVORITES"
FAV_TRIES=6
MAX_EXPANDED=10000

# Wallhaven answers an anonymous sketchy/NSFW request with SFW results only, so
# say so instead of implying the level took effect. Never a failing status: the
# callers run under `set -e` and only the fetched path matters to them.
if [ "$NSFW" != "off" ] && [ -z "$APIKEY" ]; then
    printf 'fetch-wallpaper: nsfw=%s needs apikey — wallhaven will still return SFW only\n' "$NSFW" >&2
fi

# ------------------------------------------------------------ query lists

TERMS=()
TERM_WEIGHTED=0

# Reads a query list: blank lines and '#' comments skip, "TERM * N" adds TERM
# N times, anything else adds TERM once. The weights are expanded here so the
# pick stays a plain $RANDOM index, and the existing unweighted pool.txt keeps
# behaving exactly as before.
load_terms() {
    local file="$1" line term weight i capped=0 total unique
    local -A seen=()
    while IFS= read -r line || [ -n "$line" ]; do
        line="$(ws_trim "$line")"
        case "$line" in
            ''|'#'*) continue ;;
        esac
        term="$line"
        weight=1
        if [[ "$line" =~ ^(.+[^[:space:]])[[:space:]]+\*[[:space:]]*([0-9]+)$ ]]; then
            term="$(ws_trim "${BASH_REMATCH[1]}")"
            weight="${BASH_REMATCH[2]}"
            TERM_WEIGHTED=$((TERM_WEIGHTED + 1))
        fi
        if [ -z "$term" ]; then
            continue
        fi
        if [ "$weight" -lt 1 ]; then
            weight=1
        fi
        if [ "$weight" -gt 100 ]; then
            weight=100
        fi
        i=0
        while [ "$i" -lt "$weight" ]; do
            if [ "${#TERMS[@]}" -ge "$MAX_EXPANDED" ]; then
                if [ "$capped" -eq 0 ]; then
                    printf 'fetch-wallpaper: %s expands past %d terms — weights capped\n' "$file" "$MAX_EXPANDED" >&2
                    capped=1
                fi
                break
            fi
            TERMS[${#TERMS[@]}]="$term"
            i=$((i + 1))
        done
        seen["$term"]=1
    done < "$file"
    total="${#TERMS[@]}"
    unique="${#seen[@]}"
    if ws_debug; then
        printf 'fetch-wallpaper: terms total=%d unique=%d weighted=%d\n' "$total" "$unique" "$TERM_WEIGHTED" >&2
    fi
}

# Preconditions. The query list is only needed by the sources that draw a term
# from it: favorites are ids, and a non-empty `query` term is used as it stands.
NEED_TERMS=1
if [ "$SOURCE" = "favorites" ]; then
    NEED_TERMS=0
elif [ "$SOURCE" = "query" ] && [ -n "$QE" ]; then
    NEED_TERMS=0
fi

if [ "$NEED_TERMS" -eq 1 ]; then
    if [ ! -r "$LIST_FILE" ]; then
        if [ -n "$WS_SET" ]; then
            printf 'fetch-wallpaper: no query list at %s (set=%s)\n' "$LIST_FILE" "$WS_SET" >&2
        else
            printf 'fetch-wallpaper: no query list at %s\n' "$LIST_FILE" >&2
        fi
        exit 1
    fi
    load_terms "$LIST_FILE"
    if [ "${#TERMS[@]}" -eq 0 ]; then
        printf 'fetch-wallpaper: %s is empty\n' "$LIST_FILE" >&2
        exit 1
    fi
fi

if [ "$SOURCE" = "favorites" ] && [ ! -r "$FAV_FILE" ]; then
    printf 'fetch-wallpaper: no favorites file at %s\n' "$FAV_FILE" >&2
    exit 1
fi

# ------------------------------------------------------------ request URLs

# Percent-encodes the query: % first, then the characters that would otherwise
# change the URL's meaning (space, &, #, +, comma).
encode_query() {
    local s="$1"
    s="${s//'%'/%25}"
    s="${s//' '/%20}"
    s="${s//'&'/%26}"
    s="${s//'#'/%23}"
    s="${s//'+'/%2B}"
    s="${s//','/%2C}"
    printf '%s' "$s"
}

search_url() {
    local term="$1" seed="$2" qq url atleast
    qq="$(encode_query "$term")"
    # The panel's "Any size" writes min_res = any, which is the absence of a
    # floor: send no atleast= rather than a value wallhaven cannot parse.
    case "$MIN_RES" in
        ''|any) atleast="" ;;
        *)      atleast="&atleast=$MIN_RES" ;;
    esac
    url="https://wallhaven.cc/api/v1/search?q=$qq&categories=$CATEGORIES&purity=$PURITY$atleast&ratios=16x9,16x10,21x9&sorting=random&seed=$seed&page=1"
    if [ -n "$APIKEY" ]; then
        url="$url&apikey=$APIKEY"
    fi
    printf '%s' "$url"
}

# /w/<id> has no query string yet, so the key is introduced with '?'.
detail_url() {
    local id="$1" url="https://wallhaven.cc/api/v1/w/$id"
    if [ -n "$APIKEY" ]; then
        url="$url?apikey=$APIKEY"
    fi
    printf '%s' "$url"
}

# Prints the usable favourite ids, one per line: comments and blanks skip, ids
# already swiped away always skip, and the recently shown ones skip until the
# final attempt (SKIP_RECENT) so a short list cannot dead-end.
favorite_ids() {
    local line id
    local -A skip=()
    if [ -r "$REJECTED" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(ws_trim "$line")"
            if [ -n "$line" ]; then
                skip["$line"]=1
            fi
        done < "$REJECTED"
    fi
    if [ -z "${SKIP_RECENT:-}" ] && [ -r "$RECENT" ]; then
        while IFS= read -r line || [ -n "$line" ]; do
            line="$(ws_trim "$line")"
            if [ -n "$line" ]; then
                skip["$line"]=1
            fi
        done < "$RECENT"
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        id="$(ws_trim "$line")"
        case "$id" in
            ''|'#'*) continue ;;
        esac
        if [ -z "${skip[$id]:-}" ]; then
            printf '%s\n' "$id"
        fi
    done < "$FAV_FILE"
}

# Offline proof that the settings reach the request: prints what it would ask
# for and stops before any cache write, lock or network call.
dry_run() {
    local term="" id="" url="" line
    local -a ids=()
    printf 'fetch-wallpaper: dry-run source=%s nsfw=%s purity=%s min_sat=%s min_res=%s list=%s favorites=%s\n' \
        "$SOURCE" "$NSFW" "$PURITY" "$MIN_SATURATION" "$MIN_RES" "$LIST_FILE" "$FAV_FILE" >&2
    case "$SOURCE" in
        favorites)
            while IFS= read -r line; do
                if [ -n "$line" ]; then
                    ids[${#ids[@]}]="$line"
                fi
            done < <(favorite_ids)
            if [ "${#ids[@]}" -eq 0 ]; then
                printf 'fetch-wallpaper: dry-run: no usable favorites in %s\n' "$FAV_FILE" >&2
                exit 1
            fi
            id="${ids[$((RANDOM % ${#ids[@]}))]}"
            url="$(detail_url "$id")"
            printf 'fetch-wallpaper: dry-run favorite=%s (purity is checked by the API at fetch time)\n' "$id" >&2
            printf 'fetch-wallpaper: url=%s\n' "$url" >&2
            ;;
        *)
            if [ "$SOURCE" = "query" ] && [ -n "$QE" ]; then
                term="$QE"
            else
                term="${TERMS[$((RANDOM % ${#TERMS[@]}))]}"
            fi
            url="$(search_url "$term" "$RANDOM$RANDOM$RANDOM")"
            printf 'fetch-wallpaper: dry-run term=%s\n' "$term" >&2
            printf 'fetch-wallpaper: url=%s\n' "$url" >&2
            ;;
    esac
    exit 0
}

if [ -n "${WALLPAPER_DRY_RUN:-}" ]; then
    dry_run
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

# Pick a random result from a random pool entry (or the one `query` term),
# skipping rejected ids. Prints "id<TAB>path" (or nothing when every result
# was rejected).
pick_search() {
    local term seed idx recfile url
    if [ "$SOURCE" = "query" ] && [ -n "$QE" ]; then
        term="$QE"
    else
        term="${TERMS[$((RANDOM % ${#TERMS[@]}))]}"
    fi
    seed="$RANDOM$RANDOM$RANDOM"
    idx="$RANDOM"
    recfile="$RECENT"
    # SKIP_RECENT is set on the final attempt: stop excluding recent picks so a
    # small pool cannot dead-end into "no image".
    if [ -n "${SKIP_RECENT:-}" ]; then
        recfile=/dev/null
    fi
    url="$(search_url "$term" "$seed")"

    if ws_debug; then
        printf 'fetch-wallpaper: q=%s\n' "$term" >&2
        printf 'fetch-wallpaper: url=%s\n' "$url" >&2
    fi

    curl -fsS --max-time 30 -A "$UA" "$url" 2>/dev/null \
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

# Pick one favourite id and resolve its full image path through the public
# detail endpoint, at most FAV_TRIES times. Prints "id<TAB>path"; returns 1
# when the list is exhausted, which the caller treats like an empty search.
pick_favorite() {
    local -a ids=()
    local line id path purity data meta start len k url
    while IFS= read -r line; do
        if [ -n "$line" ]; then
            ids[${#ids[@]}]="$line"
        fi
    done < <(favorite_ids)

    len=${#ids[@]}
    if [ "$len" -eq 0 ]; then
        if ws_debug; then
            printf 'fetch-wallpaper: no usable favorites in %s\n' "$FAV_FILE" >&2
        fi
        return 1
    fi

    start=$((RANDOM % len))
    k=0
    while [ "$k" -lt "$FAV_TRIES" ] && [ "$k" -lt "$len" ]; do
        id="${ids[$(((start + k) % len))]}"
        k=$((k + 1))
        url="$(detail_url "$id")"
        if ws_debug; then
            printf 'fetch-wallpaper: favorite=%s url=%s\n' "$id" "$url" >&2
        fi
        data="$(curl -fsS --max-time 30 -A "$UA" "$url" 2>/dev/null || true)"
        meta="$(printf '%s' "$data" | jq -r '[(.data.path // ""), (.data.purity // "")] | @tsv' 2>/dev/null || true)"
        path="${meta%%$'\t'*}"
        purity="${meta#*$'\t'}"
        if [ -z "$path" ]; then
            if ws_debug; then
                printf 'fetch-wallpaper: skip %s (no data)\n' "$id" >&2
            fi
            continue
        fi
        if [ "$NSFW" = "off" ] && [ "$purity" != "sfw" ]; then
            if ws_debug; then
                printf 'fetch-wallpaper: skip %s purity=%s\n' "$id" "$purity" >&2
            fi
            continue
        fi
        printf '%s\t%s\n' "$id" "$path"
        return 0
    done
    return 1
}

next_candidate() {
    case "$SOURCE" in
        favorites) pick_favorite ;;
        *)         pick_search ;;
    esac
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
    entry="$(next_candidate || true)"
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
