#!/usr/bin/env bash
set -u

url="${1:-}"
if [ -z "$url" ]; then
    echo "usage: open-source.sh <url>" >&2
    exit 2
fi

if ! command -v xdg-open >/dev/null 2>&1; then
    echo "xdg-open not found" >&2
    exit 127
fi

xdg-open "$url" >/dev/null 2>&1 &
opener_pid=$!

if command -v niri >/dev/null 2>&1 && niri msg version >/dev/null 2>&1; then
    host="${url#https://}"
    host="${host%%/*}"
    for _ in $(seq 1 30); do
        sleep 0.15
        win_id=$(niri msg windows 2>/dev/null | awk -v host="$host" '
            /^Window ID [0-9]+:/ { id = $3; sub(/:$/, "", id) }
            /Title: "/ { if (index($0, host)) { print id; exit } }
        ')
        if [ -n "${win_id:-}" ]; then
            niri msg action focus-window --id "$win_id" >/dev/null 2>&1
            break
        fi
    done
fi

wait "$opener_pid" 2>/dev/null
exit 0
