# wallfx

The character-draw wallpaper transition: a model cuts the character out of the
incoming wallpaper, and the change is drawn as that character's outline first —
the line traces its silhouette, the character fills in, then the rest of the
world spreads out of it in 4 px cells.

Ported from the same feature in diegoMalagrida/pocket-dots (wallfx + the
WallpaperFx shader), reduced to the outline transition: no contagion, no
colonies. A wallpaper with no character just gets the plain awww fade.

## Pieces

    .local/bin/wallfx              the maps (Python): cut-out, outline, arrival order
    .local/src/wallfx-gpu/         the renderer (C + GLES3, wlr-layer-shell)
    .local/bin/wallfx-gpu          built and installed by install.sh

`wallfx` runs on demand; `wallfx-gpu` lives only for the ~2 s of a change.

## How a change happens

`~/.config/niri/scripts/apply-wallpaper.sh` is still the only place that paints.
It asks `wallfx elige NEW` which transition the new image gets, and then hands
the change to `wallfx-gpu OLD NEW CAMPO LINEA`, which:

1. fades in over awww (at t=0 the animation IS the old wallpaper, so the
   hand-over is invisible);
2. switches awww underneath with `--transition-type none` once fully covered;
3. finishes the animation on the new image, which awww now shows too;
4. fades out and exits.

If anything fails it runs a plain `awww img NEW --transition-type fade` itself:
the wallpaper must change even if the effect cannot play.

## The cut-out

BiRefNet (`birefnet-general-lite` through rembg) runs once per wallpaper and is
cached by path, size and date in `~/.cache/wallfx/perfil`:

    <key>-mascara.png   the model's raw mask
    <key>-campo.png     R glow distance, G inward fill depth, B signed distance
    <key>-linea.png     R outline parameter, G/B 16-bit outside arrival order
    <key>.json          the decision: ok / cover / unsure

A picture only gets the outline when the model is sure and the subject takes
part of the frame (cover 0.008–0.72, "unsure" ≤ 0.06). Wallpapers that should
never get it even though the model finds something go in
`~/.config/wallfx/sin-perfil`, one file name per line.

## Setup (once per machine)

    wallfx instalar     # uv venv + rembg + onnxruntime + opencv (~1 GB)
    wallfx warm         # optional: cut out what is already cached

OpenVINO (Intel GPU) is tried first and, if it cannot load the model, the
failure is remembered in `~/.cache/wallfx/ov-off` so later runs go straight to
the CPU. Delete that file to retry the GPU. Steady state on the CPU here:
~13 s per new wallpaper, cached ones are free.

## Feedback

- Keybind (`Mod+Shift+W` / the swipe-reject key): `wallfx elige` sends a
  notification after 1.5 s ("Cutting out its character…"), and gives up at
  25 s with a plain fade.
- Wallpaper browser: the apply status line says it is preparing and cutting
  out the character; a cached wallpaper still applies immediately.

## Testing without a screen

    WALLFX_GPU_SELFTEST=/tmp/dir wallfx-gpu OLD NEW CAMPO LINEA

renders the transition at seven instants into `t-*.ppm` (1280x720) and exits.
It needs no awww and no window. `WALLFX_GPU_DEBUG=1` logs to stderr.
