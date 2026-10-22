--!nonstrict
-- Control-center tile: open/close the wallpaper browser.
local function paint()
    if shortcut == nil then
        return
    end
    shortcut.setLabel(noctalia.tr("shortcut.label"))
    shortcut.setIcon("photo")
end

function onClick()
    noctalia.togglePanel("computing/wallpaper-browser:browser")
end

paint()
