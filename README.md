# wapper

Wallhaven wallpapers for a Wayland desktop: a random fetcher, the scripts that
apply and reject a wallpaper, and a Noctalia v5 panel for browsing wallhaven.cc
by hand. The image on screen drives a Material 3 palette (matugen) through
`apply-wallpaper.sh`.

Built for niri + awww + matugen + Noctalia v5, but only `apply-wallpaper.sh`
touches the compositor-facing tools, so the rest works anywhere bash does.

## Pieces

    scripts/fetch-wallpaper.sh        pull one random wallpaper into the cache
    scripts/read-settings.sh          the settings file: read, create, write
    scripts/set-setting.sh            change one setting (the panel's slider and size select)
    scripts/apply-wallpaper.sh        paint it, repoint the backdrop link, recolour
    scripts/random-wallpaper.sh       fetch + apply (the "next" key)
    scripts/start-wallpaper-one.sh    startup: paint one, never rotate
    scripts/swipe-delete-wallpaper.sh reject this id, fetch the next
    scripts/wallpaper-hotplug.sh      repaint a newly connected output

    plugin/wallpaper-browser/         Noctalia v5 plugin: panel + bar button
    pool.txt                          default search queries, one per line

One image is cached at a time in `~/.cache/wallpaper/`, along with
`current.id`, `recent`, `rejected` and `history` — the panel and the swipe
scripts read the same files. Settings, the query list(s) and the local
favourites live in `~/.config/wallpaper/`.

## Requirements

`bash curl jq` for fetching, `awww` to paint, `matugen` for the palette,
`noctalia` v5 for the panel, ImageMagick (`magick`) for the saturation check.
`xdg-open` is used by the panel's "open source" button.

## Deploy

The scripts run from the niri config directory (that is what `config.kdl`
spawns), and the plugin runs from the Noctalia plugin directory. Neither lives
in `~/.local/bin`.

    install -Dm755 scripts/*.sh ~/.config/niri/scripts/
    install -Dm644 plugin/wallpaper-browser/panel.luau \
                   plugin/wallpaper-browser/button.luau \
                   plugin/wallpaper-browser/shortcut.luau \
                   plugin/wallpaper-browser/plugin.toml \
                   plugin/wallpaper-browser/translations/en.json \
                                               ~/.config/noctalia-v5-plugins/wallpaper-browser/
    install -Dm755 plugin/wallpaper-browser/apply.sh \
                   plugin/wallpaper-browser/thumbs.sh \
                   plugin/wallpaper-browser/open-source.sh \
                                               ~/.config/noctalia-v5-plugins/wallpaper-browser/
    mkdir -p ~/.config/wallpaper/sets
    cp pool.txt ~/.config/wallpaper/pool.txt      # first install only
    bash ~/.config/niri/scripts/read-settings.sh --print   # creates the settings file

Then enable/reload the plugin with `noctalia msg plugins enable
computing/wallpaper-browser` (a shell restart also picks it up).

Bind the scripts in your compositor, e.g. for niri:

    binds {
        Mod+Shift+B { spawn "bash" "~/.config/niri/scripts/random-wallpaper.sh"; }
        Super+X     { spawn "bash" "~/.config/niri/scripts/swipe-delete-wallpaper.sh"; }
    }
    spawn-at-startup "bash" "~/.config/niri/scripts/start-wallpaper-one.sh"
    spawn-at-startup "bash" "~/.config/niri/scripts/wallpaper-hotplug.sh"

The panel opens from the bar button or
`noctalia msg panel-toggle computing/wallpaper-browser:browser`.

## Settings

`~/.config/wallpaper/settings`, one `key = value` per line, mode 600 (it may
hold an API key). Created with commented defaults the first time anything reads
it, so it is safe to edit by hand or leave alone.

    # Where a random pick comes from: pool | favorites | query
    source = pool
    # Search term used when source = query (empty = a random pool term)
    query =
    # Named query list: sets/<set>.txt instead of the pool file
    set =
    # off -> purity 100, sketchy -> 110, all -> 111
    nsfw = off
    # Optional wallhaven API key, appended to API calls
    apikey =
    # Local favourites: wallhaven ids, one per line
    favorites = ~/.config/wallpaper/favorites
    # Query list for source = pool
    pool = ~/.config/wallpaper/pool.txt
    # Mean HSL saturation floor, 0..1 (a duller pick is re-rolled)
    min_sat = 0.30
    # Sent as atleast=
    min_res = 2560x1440

| key | default | environment | meaning |
|---|---|---|---|
| `source` | `pool` | `WALLPAPER_SOURCE` | `pool`, `favorites` or `query` |
| `query` | empty | `WALLPAPER_QUERY` | search term for `source = query` |
| `set` | empty | `WALLPAPER_SET` | use `~/.config/wallpaper/sets/<name>.txt` as the query list |
| `nsfw` | `off` | `WALLPAPER_NSFW` | `off` → purity 100, `sketchy` → 110, `all` → 111 |
| `apikey` | empty | `WALLPAPER_APIKEY` | appended to API calls; empty = anonymous |
| `favorites` | `~/.config/wallpaper/favorites` | `WALLPAPER_FAVORITES` | wallhaven ids for `source = favorites` |
| `pool` | `~/.config/wallpaper/pool.txt` | `WALLPAPER_POOL` | query list for `source = pool` |
| `min_sat` | `0.30` | `WALLPAPER_MIN_SAT` | mean-saturation floor, 0..1 |
| `min_res` | `2560x1440` | `WALLPAPER_MIN_RES` | value of `atleast=`; `any` (the panel's "Any size") sends no `atleast=` at all |

**Precedence: environment variable > settings file > built-in default.** The
grammar: split on the first `=`, so a value may contain `=`; blank lines skip;
a line starting with `#` is a comment; there are no inline comments; a repeated
key means the last one wins; an unknown key is ignored; an empty value falls
back to the default. A leading `~/` in a path value means `$HOME`.

### Query lists (weights, sets)

`pool` and `sets/<name>.txt` are one term per line. `TERM * N` makes the line N
times more likely (`synthwave * 3`); a plain line counts once, so an existing
weightless `pool.txt` keeps behaving exactly as before. Blank lines and `#`
comments are skipped.

Named sets are just files:

    ~/.config/wallpaper/sets/neon.txt
    synthwave * 3
    # a comment
    neon

and `set = neon` in the settings file (or `WALLPAPER_SET=neon`) selects one.

### Favourites

`~/.config/wallpaper/favorites` holds wallhaven ids, one per line — the panel's
star adds and removes them, and `source = favorites` picks one and resolves it
through the public `https://wallhaven.cc/api/v1/w/<id>` endpoint (no key
needed). Ids on the reject list are never picked.

### NSFW caveat

`sketchy` and `all` only return anything beyond SFW results when `apikey` is
set: wallhaven answers anonymous requests with SFW results only. Both the
fetcher and the panel say so instead of pretending the level took effect. The
panel's purity slider writes this key through `scripts/set-setting.sh`, which
edits the one line and keeps every comment in the file; if the scripts cannot
be found at runtime the panel says the change is session-only instead of
failing silently.

## Environment

    WALLPAPER_POOL        query list path (default ~/.config/wallpaper/pool.txt)
    WALLPAPER_SOURCE      pool | favorites | query
    WALLPAPER_QUERY       search term for source=query
    WALLPAPER_SET         named query set (sets/<name>.txt)
    WALLPAPER_NSFW        off | sketchy | all
    WALLPAPER_APIKEY      wallhaven API key
    WALLPAPER_FAVORITES   favourites file path
    WALLPAPER_MIN_SAT     minimum mean saturation, 0..1 (default 0.30)
    WALLPAPER_MIN_RES     minimum resolution (default 2560x1440)
    WALLPAPER_SETTINGS    settings file path (default ~/.config/wallpaper/settings)
    WALLPAPER_SCRIPTS     where the plugin looks for the scripts (default: the
                          niri config dir, then ~/.local/bin)
    WALLPAPER_DEBUG       set to 1 to print the full request URL (query,
                          purity and apikey included)
    WALLPAPER_DRY_RUN     set to 1 to print the settings and the URL a fetch
                          would request, then exit without touching the network
                          or the cache

`apply-wallpaper.sh` repoints `~/.config/backgrounds/current-wallpaper` at the
new image; the lock screen and the hotplug healer follow that symlink.

## Scratch directories

`.hermes/` and `.memory/` are local planning/editor scratch and are untracked
(see `.gitignore`). They are not part of the project and must not be committed.

## Licence

MIT
