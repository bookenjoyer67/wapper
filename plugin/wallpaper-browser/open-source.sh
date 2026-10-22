#!/usr/bin/env bash
# Open a wallpaper's wallhaven page and actually bring it into view.
#
# xdg-open alone is not enough on niri when the browser is already running on
# another workspace: it delivers the URL to the existing instance, which appends
# a tab and leaves the window where it was (usually behind the panel / on
# another workspace), so the click looks like a no-op. After handing the URL
# off, find the window that now shows the page and focus it.
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

# Only niri can be asked to raise a window here; elsewhere the opener's own
# activation handling is all we get.
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
