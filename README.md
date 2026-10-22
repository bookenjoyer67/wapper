# wapper

Wallhaven wallpapers for a Wayland desktop: a random fetcher, the scripts that
apply and reject a wallpaper, and a Noctalia v5 panel for browsing wallhaven.cc
by hand. The image on screen drives a Material 3 palette (matugen) through
`apply-wallpaper.sh`.

Built for niri + awww + matugen + Noctalia v5, but only `apply-wallpaper.sh`
touches the compositor-facing tools, so the rest works anywhere bash does.

## Pieces

    scripts/fetch-wallpaper.sh        pull one random wallpaper into the cache
    scripts/apply-wallpaper.sh        paint it, repoint the backdrop link, recolour
    scripts/random-wallpaper.sh       fetch + apply (the "next" key)
    scripts/start-wallpaper-one.sh    startup: paint one, never rotate
    scripts/swipe-delete-wallpaper.sh reject this id, fetch the next
    scripts/wallpaper-hotplug.sh      repaint a newly connected output

    plugin/wallpaper-browser/         Noctalia v5 plugin: panel + bar button
    pool.txt                          default search queries, one per line

One image is cached at a time in `~/.cache/wallpaper/`, along with
`current.id`, `recent`, `rejected` and `history` — the panel and the swipe
scripts read the same files.

## Requirements

`bash curl jq` for fetching, `awww` to paint, `matugen` for the palette,
`noctalia` v5 for the panel, ImageMagick (`magick`) for the saturation check.
`xdg-open` is used by the panel's "open source" button.

## Install

    install -Dm755 scripts/*.sh ~/.local/bin/
    cp -r plugin/wallpaper-browser ~/.config/noctalia-v5-plugins/
    mkdir -p ~/.config/wallpaper && cp pool.txt ~/.config/wallpaper/pool.txt
    noctalia msg plugins enable computing/wallpaper-browser

Then bind the scripts in your compositor, e.g. for niri:

    binds {
        Mod+Shift+B { spawn "bash" "-lc" "random-wallpaper.sh"; }
        Super+X     { spawn "bash" "-lc" "swipe-delete-wallpaper.sh"; }
    }
    spawn-at-startup "bash" "-lc" "start-wallpaper-one.sh"

The panel opens from the bar button or
`noctalia msg panel-toggle computing/wallpaper-browser:browser`.

## Configuration

    ~/.config/wallpaper/pool.txt   search queries, one per line; blank lines
                                   skipped. Both the fetcher and the panel's
                                   query list read this file.

Environment:

    WALLPAPER_POOL      pool file path (default ~/.config/wallpaper/pool.txt)
    WALLPAPER_SCRIPTS   where the plugin looks for the scripts (default ~/.local/bin)
    WALLPAPER_MIN_SAT   minimum mean saturation, 0..1 (default 0.30)
    WALLPAPER_DEBUG     set to 1 to print the query each fetch uses

`apply-wallpaper.sh` repoints `~/.config/backgrounds/current-wallpaper` at the
new image; the lock screen and the hotplug healer follow that symlink.

## Licence

MIT
