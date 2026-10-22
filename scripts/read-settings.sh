#!/usr/bin/env bash
# read-settings.sh — the settings file for wapper: read, materialise, write.
#
# Sourced by the scripts (via $DER, so it works from both ~/Projects/wapper/
# scripts and the deployed ~/.config/niri/scripts) and by set-setting.sh.
# It never changes shell options: callers run either `set -euo pipefail` or
# `set -uo pipefail`, and both must keep working.
#
# Grammar (the panel implements the same one):
#   key = value, one per line; split on the FIRST '=' only; blank lines skip;
#   a line whose first non-space character is '#' is a comment; no inline
#   comments; a duplicate key means the LAST occurrence wins; unknown keys are
#   ignored; an empty value falls back to the built-in default.
#
# Precedence: environment variable > settings file > built-in default.
#
# Executed (`bash read-settings.sh`, i.e. --print) it prints the resolved
# key=value set, for the tester and for the panel's manual checklist.

ws_file() {
    printf '%s' "${WALLPAPER_SETTINGS:-$HOME/.config/wallpaper/settings}"
}

ws_debug() {
    [ -n "${WALLPAPER_DEBUG:-}" ]
}

# Trims leading and trailing whitespace without forking.
ws_trim() {
    local s="${1-}"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# A leading ~/ in a path value means $HOME (values are otherwise verbatim:
# no shell expansion, no quote stripping).
ws_tilde() {
    local p="${1-}"
    case "$p" in
        '~/')   printf '%s' "$HOME" ;;
        '~/'*) printf '%s/%s' "$HOME" "${p#'~/'}" ;;
        *)     printf '%s' "$p" ;;
    esac
}

ws_env_name() {
    case "${1-}" in
        source)    printf '%s' WALLPAPER_SOURCE ;;
        query)     printf '%s' WALLPAPER_QUERY ;;
        set)       printf '%s' WALLPAPER_SET ;;
        nsfw)      printf '%s' WALLPAPER_NSFW ;;
        apikey)    printf '%s' WALLPAPER_APIKEY ;;
        favorites) printf '%s' WALLPAPER_FAVORITES ;;
        pool)      printf '%s' WALLPAPER_POOL ;;
        min_sat)   printf '%s' WALLPAPER_MIN_SAT ;;
        min_res)   printf '%s' WALLPAPER_MIN_RES ;;
        *)         printf '%s' "" ;;
    esac
}

ws_is_key() {
    case "${1-}" in
        source|query|set|nsfw|apikey|favorites|pool|min_sat|min_res) return 0 ;;
        *) return 1 ;;
    esac
}

ws_is_path_key() {
    case "${1-}" in
        favorites|pool) return 0 ;;
        *) return 1 ;;
    esac
}

# Emits the commented default settings file. The `set` key name is
# interpolated so this file contains no line starting with `set `: the
# strict-mode gate greps for that to prove the lib sets no shell options.
ws_template() {
    local WS_K=set
    cat <<WS_TEMPLATE
# wapper settings — read by scripts/*.sh and the wallpaper-browser panel.
# Format: key = value, one per line. Lines starting with '#' are comments.
# WALLPAPER_* environment variables override anything here.

# Where a random pick comes from: pool | favorites | query
source = pool

# Search term used when source = query. Empty means "pick a random pool term".
query =

# Named query list: when set, the fetcher reads
# ~/.config/wallpaper/sets/<set>.txt instead of the pool file below.
${WS_K} =

# Wallhaven purity: off = SFW only (100), sketchy = 110, all = 111.
# sketchy and all need an apikey — anonymous requests only ever return SFW.
nsfw = off

# Optional wallhaven API key, appended to API calls as apikey=...
# Leave empty for anonymous (SFW-only) requests.
apikey =

# Local favourites: wallhaven ids, one per line (the panel's star adds them).
favorites = ~/.config/wallpaper/favorites

# Search-query pool: one term per line. A trailing " * N" makes the line N
# times more likely (e.g. "synthwave * 3").
pool = ~/.config/wallpaper/pool.txt

# Minimum mean HSL saturation, 0..1 — a duller pick is re-rolled.
min_sat = 0.30

# Minimum resolution, sent as atleast= (e.g. 2560x1440).
min_res = 2560x1440
WS_TEMPLATE
}

# Creates the settings file with the commented defaults when it is missing.
# The file may hold an API key, so it is written 600. Never fails.
ws_materialise() {
    local file dir tmp
    file="$(ws_file)"
    if [ -r "$file" ]; then
        return 0
    fi
    dir="$(dirname "$file")"
    if ! mkdir -p "$dir" 2>/dev/null; then
        printf 'read-settings: cannot create %s\n' "$dir" >&2
        return 0
    fi
    tmp="$file.tmp.$$"
    if ( umask 077; ws_template > "$tmp" ) 2>/dev/null; then
        mv -f "$tmp" "$file" 2>/dev/null || rm -f "$tmp" 2>/dev/null
    else
        rm -f "$tmp" 2>/dev/null
    fi
    return 0
}

# Last matching value in the file, trimmed. Empty when absent. Never fails.
ws_file_get() {
    local key="${1-}" file line t k found=""
    file="$(ws_file)"
    if [ ! -r "$file" ]; then
        printf '%s' ""
        return 0
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        t="$(ws_trim "$line")"
        case "$t" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac
        k="$(ws_trim "${line%%=*}")"
        if [ "$k" = "$key" ]; then
            found="$(ws_trim "${line#*=}")"
        fi
    done < "$file"
    if ws_is_path_key "$key"; then
        found="$(ws_tilde "$found")"
    fi
    printf '%s' "$found"
    return 0
}

# env > file > DEFAULT. Never fails; an empty env var counts as unset.
ws_get() {
    local key="${1-}" default="${2-}" name value=""
    name="$(ws_env_name "$key")"
    if [ -n "$name" ]; then
        eval "value=\"\${$name-}\""
        value="$(ws_trim "$value")"
        if [ -n "$value" ] && ws_is_path_key "$key"; then
            value="$(ws_tilde "$value")"
        fi
    fi
    if [ -z "$value" ]; then
        value="$(ws_file_get "$key")"
    fi
    if [ -z "$value" ]; then
        value="$default"
    fi
    printf '%s' "$value"
}

ws_purity() {
    case "${1-}" in
        sketchy) printf '%s' 110 ;;
        all)     printf '%s' 111 ;;
        *)       printf '%s' 100 ;;
    esac
}

# Rewrites KEY = VALUE in place, preserving comments and every other key.
# Earlier duplicates of the same key are dropped: the last occurrence is the
# one that was being honoured, and collapsing them keeps the file converged.
# Returns 0 on success, 1 on write failure, and 3 when the key is not one of
# the known keys — that last check is the library's own guard for a direct
# caller; set-setting.sh screens unknown keys itself and exits 2.
ws_set() {
    local key="${1-}" value="${2-}" file tmp line t k n=0 target=0 wrote=0
    if ! ws_is_key "$key"; then
        return 3
    fi
    file="$(ws_file)"
    ws_materialise
    if [ ! -r "$file" ]; then
        return 1
    fi
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        t="$(ws_trim "$line")"
        case "$t" in
            ''|'#'*) continue ;;
        esac
        case "$line" in
            *=*) ;;
            *) continue ;;
        esac
        k="$(ws_trim "${line%%=*}")"
        if [ "$k" = "$key" ]; then
            target=$n
        fi
    done < "$file"

    tmp="$file.tmp.$$"
    if ! cp -p -- "$file" "$tmp" 2>/dev/null; then
        if ! ( umask 077; : > "$tmp" ) 2>/dev/null; then
            return 1
        fi
    fi
    : > "$tmp" 2>/dev/null || { rm -f "$tmp" 2>/dev/null; return 1; }

    n=0
    while IFS= read -r line || [ -n "$line" ]; do
        n=$((n + 1))
        t="$(ws_trim "$line")"
        case "$t" in
            ''|'#'*) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        case "$line" in
            *=*) ;;
            *) printf '%s\n' "$line" >> "$tmp"; continue ;;
        esac
        k="$(ws_trim "${line%%=*}")"
        if [ "$k" = "$key" ]; then
            if [ "$n" -eq "$target" ]; then
                printf '%s = %s\n' "$key" "$value" >> "$tmp"
                wrote=1
            fi
        else
            printf '%s\n' "$line" >> "$tmp"
        fi
    done < "$file"
    if [ "$wrote" -eq 0 ]; then
        printf '%s = %s\n' "$key" "$value" >> "$tmp"
    fi

    if ! mv -f "$tmp" "$file" 2>/dev/null; then
        rm -f "$tmp" 2>/dev/null
        return 1
    fi
    return 0
}

# Resolves every key once into the WS_* globals. The fetcher and set-setting
# both start here, so the grammar has exactly one implementation.
ws_apply() {
    ws_materialise

    WS_SOURCE="$(ws_get source pool)"
    case "$WS_SOURCE" in
        pool|favorites|query) ;;
        *)
            printf 'read-settings: unknown source=%s (want pool, favorites or query) — using pool\n' "$WS_SOURCE" >&2
            WS_SOURCE="pool"
            ;;
    esac

    WS_QUERY="$(ws_get query "")"
    WS_SET="$(ws_get set "")"
    WS_NSFW="$(ws_get nsfw off)"
    case "$WS_NSFW" in
        off|sketchy|all) ;;
        *)
            printf 'read-settings: unknown nsfw=%s (want off, sketchy or all) — using off\n' "$WS_NSFW" >&2
            WS_NSFW="off"
            ;;
    esac
    WS_PURITY="$(ws_purity "$WS_NSFW")"
    WS_APIKEY="$(ws_get apikey "")"
    WS_FAVORITES="$(ws_get favorites "$HOME/.config/wallpaper/favorites")"
    WS_POOL="$(ws_get pool "$HOME/.config/wallpaper/pool.txt")"
    WS_MIN_SAT="$(ws_get min_sat "0.30")"
    WS_MIN_RES="$(ws_get min_res "2560x1440")"

    # The one place the "named set replaces the pool list" rule lives.
    if [ -n "$WS_SET" ]; then
        WS_LIST_FILE="$HOME/.config/wallpaper/sets/$WS_SET.txt"
    else
        WS_LIST_FILE="$WS_POOL"
    fi

    if ws_debug; then
        local key_state="empty"
        if [ -n "$WS_APIKEY" ]; then
            key_state="set"
        fi
        printf 'read-settings: file=%s source=%s set=%s nsfw=%s purity=%s apikey=%s list=%s\n' \
            "$(ws_file)" "$WS_SOURCE" "$WS_SET" "$WS_NSFW" "$WS_PURITY" "$key_state" "$WS_LIST_FILE" >&2
    fi
    return 0
}

# Executed rather than sourced: print the resolved settings and exit.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    ws_apply
    printf 'settings=%s\n' "$(ws_file)"
    printf 'source=%s\n' "$WS_SOURCE"
    printf 'query=%s\n' "$WS_QUERY"
    printf 'set=%s\n' "$WS_SET"
    printf 'nsfw=%s\n' "$WS_NSFW"
    printf 'purity=%s\n' "$WS_PURITY"
    printf 'min_sat=%s\n' "$WS_MIN_SAT"
    printf 'min_res=%s\n' "$WS_MIN_RES"
    printf 'list=%s\n' "$WS_LIST_FILE"
    printf 'favorites=%s\n' "$WS_FAVORITES"
    if [ -n "$WS_APIKEY" ]; then
        printf 'apikey=set\n'
    else
        printf 'apikey=\n'
    fi
    exit 0
fi
