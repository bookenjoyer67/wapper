--!nonstrict
-- Bar button: open the custom Wallpaper Browser panel.
--
-- Left click  : toggle the wallhaven browser panel
--               (computing/wallpaper-browser:browser)
-- Right click : one random switch, through the canonical funnel
--               (<WALLPAPER_SCRIPTS>/random-wallpaper.sh -> apply-wallpaper.sh),
--               launched via niri so it gets the session env.
--
-- The scripts live in $WALLPAPER_SCRIPTS, else the niri config dir that
-- config.kdl actually spawns, else ~/.local/bin (legacy).

local PANEL_ID = "computing/wallpaper-browser:browser"
local GLYPH = "photo"

local function resolveScriptsDir()
    local env = noctalia.getenv and noctalia.getenv("WALLPAPER_SCRIPTS")
    if type(env) == "string" and env ~= "" then
        return env
    end
    for _, candidate in ipairs({ "~/.config/niri/scripts", "~/.local/bin" }) do
        local dir = noctalia.expandPath and noctalia.expandPath(candidate) or ""
        if dir ~= "" and noctalia.fileExists and noctalia.fileExists(dir .. "/random-wallpaper.sh") then
            return dir
        end
    end
    return ""
end

local function render()
    if barWidget == nil then
        return
    end
    if barWidget.setGlyph then barWidget.setGlyph(GLYPH) end
    if barWidget.setGlyphColor then barWidget.setGlyphColor("primary") end
    if barWidget.setTooltip then
        barWidget.setTooltip(noctalia.tr("widget.tooltip"))
    end
end

function onClick()
    noctalia.togglePanel(PANEL_ID)
end

function onRightClick()
    local scriptsDir = resolveScriptsDir()
    if scriptsDir == "" then
        noctalia.notifyError(
            noctalia.tr("notify.failed_title"),
            "random-wallpaper.sh not found (looked in $WALLPAPER_SCRIPTS, ~/.config/niri/scripts, ~/.local/bin)"
        )
        return
    end
    noctalia.runAsync(
        "niri msg action spawn -- bash " .. scriptsDir .. "/random-wallpaper.sh",
        function(result)
            if result and result.exitCode ~= 0 then
                noctalia.notifyError(
                    noctalia.tr("notify.failed_title"),
                    tostring(result.stderr or "random-wallpaper.sh failed")
                )
            end
        end,
        60000
    )
end

render()
