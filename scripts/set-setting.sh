#!/usr/bin/env bash
# set-setting.sh — write one key in the settings file.
#
# The panel's NSFW slider and its resolution select call this instead of
# writing the file themselves, so the commented template survives (Noctalia's
# writeFile replaces the whole file) and the settings grammar has exactly one
# implementation.
#
# Usage: set-setting.sh <key> <value>
#   prints "<key>=<value>" on success; apikey prints "apikey=set" when a key is
#   given and "apikey=cleared" when it is empty, never the key itself.
set -euo pipefail

DER="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
. "$DER/read-settings.sh"

if [ "$#" -lt 2 ]; then
    echo "usage: set-setting.sh <key> <value>" >&2
    echo "keys: source query set nsfw apikey favorites pool min_sat min_res" >&2
    exit 2
fi

key="$1"
value="$2"

case "$key" in
    source)
        case "$value" in
            pool|favorites|query) ;;
            *)
                echo "set-setting: source must be one of: pool favorites query" >&2
                exit 2
                ;;
        esac
        ;;
    nsfw)
        case "$value" in
            off|sketchy|all) ;;
            *)
                echo "set-setting: nsfw must be one of: off sketchy all" >&2
                exit 2
                ;;
        esac
        ;;
    query|set|apikey|favorites|pool|min_sat|min_res) ;;
    *)
        echo "set-setting: unknown setting: $key" >&2
        exit 2
        ;;
esac

if ! ws_set "$key" "$value"; then
    echo "set-setting: could not write $(ws_file)" >&2
    exit 1
fi

if [ "$key" = "apikey" ]; then
    if [ -n "$value" ]; then
        echo "apikey=set"
    else
        echo "apikey=cleared"
    fi
else
    printf '%s=%s\n' "$key" "$value"
fi
