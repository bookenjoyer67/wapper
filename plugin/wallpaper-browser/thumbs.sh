#!/usr/bin/env bash
# Pull wallhaven thumbnails for one result page.
# Usage: thumbs.sh <thumb-dir> <list-file>   (list lines: "id<TAB>url")
# Skips ids already cached; six in flight at a time.
set -uo pipefail

DIR="${1:-}"
LIST="${2:-}"
[ -n "$DIR" ] && [ -n "$LIST" ] && [ -f "$LIST" ] || exit 2
mkdir -p "$DIR"

UA="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
n=0
while IFS=$'\t' read -r id url; do
    [ -n "${id:-}" ] && [ -n "${url:-}" ] || continue
    [ -s "$DIR/$id.jpg" ] && continue
    curl -fsS --max-time 25 -A "$UA" -o "$DIR/$id.part" "$url" \
        && mv -f "$DIR/$id.part" "$DIR/$id.jpg" &
    n=$((n + 1))
    if [ $((n % 6)) -eq 0 ]; then wait; fi
done < "$LIST"
wait
exit 0
