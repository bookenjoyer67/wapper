--!nonstrict

local CACHE_DIR = noctalia.expandPath("~/.cache/wallpaper")
local PREVIEW_DIR = CACHE_DIR .. "/preview"
local SETTINGS = noctalia.expandPath("~/.config/wallpaper/settings")
local API = "https://wallhaven.cc/api/v1/w/"

local IMG_W, IMG_H = 1160, 664

local state = {
    id = nil,
    phase = "idle", -- idle | loading | ready | error
    message = nil,
    path = nil,
    resolution = nil,
    purity = nil,
}
local gen = 0

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function readLine(path, key)
    local ok, text = pcall(noctalia.readFile, path)
    if not ok or type(text) ~= "string" then
        return ""
    end
    local value = ""
    for line in text:gmatch("[^\n]+") do
        local t = trim(line)
        if t:sub(1, 1) ~= "#" then
            local k, v = t:match("^([^=]*)=(.*)$")
            if k ~= nil and trim(k) == key then
                value = trim(v)
            end
        end
    end
    return value
end

local function extFromUrl(url)
    local e = tostring(url or ""):match("%.([%w]+)$")
    if e == nil then
        return "jpg"
    end
    return e:lower()
end

local captionText = function()
    local parts = {}
    if state.id ~= nil and state.id ~= "" then
        parts[#parts + 1] = state.id
    end
    if state.resolution ~= nil and state.resolution ~= "" then
        parts[#parts + 1] = state.resolution
    end
    if state.purity ~= nil and state.purity ~= "" then
        parts[#parts + 1] = state.purity
    end
    return table.concat(parts, "   •   ")
end

function render()
    local body
    if state.phase == "ready" and state.path ~= nil then
        body = ui.image({
            key = "preview-" .. tostring(state.id),
            path = state.path,
            width = IMG_W,
            height = IMG_H,
            fit = "contain",
            radius = 10,
        })
    elseif state.phase == "loading" then
        body = ui.column({ flexGrow = 1, align = "center", justify = "center", width = IMG_W, height = IMG_H }, {
            ui.label({ text = noctalia.tr("preview.loading"), fontSize = 14, color = "on_surface_variant" }),
        })
    else
        body = ui.column({ flexGrow = 1, align = "center", justify = "center", gap = 8, width = IMG_W, height = IMG_H }, {
            ui.label({
                text = state.message or noctalia.tr("preview.no_id"),
                fontSize = 14,
                color = "error",
            }),
        })
    end

    local caption = ui.row({ gap = 10, align = "center" }, {
        ui.label({ text = noctalia.tr("preview.title"), fontSize = 16, fontWeight = "bold", color = "primary" }),
        ui.label({
            text = captionText(),
            fontSize = 12,
            color = "on_surface_variant",
            flexGrow = 1,
            maxLines = 1,
        }),
        ui.button({
            glyph = "close",
            variant = "ghost",
            controlSize = "sm",
            tooltip = noctalia.tr("tooltip.close"),
            onClick = function()
                panel.close()
            end,
        }),
    })

    panel.render(ui.column({ flexGrow = 1, gap = 10, padding = 14, align = "stretch" }, { caption, body }))
end

local function prepare(id)
    gen = gen + 1
    local my = gen
    state.id = id
    state.phase = "loading"
    state.message = nil
    state.path = nil
    state.resolution = nil
    state.purity = nil
    render()

    if id == nil or id == "" then
        state.phase = "error"
        state.message = noctalia.tr("preview.no_id")
        render()
        return
    end

    local url = API .. id
    local key = readLine(SETTINGS, "apikey")
    if key ~= "" then
        url = url .. "?apikey=" .. key
    end

    noctalia.http({ url = url, headers = { "Accept: application/json" } }, function(res)
        if my ~= gen then
            return
        end
        if res == nil or res.ok ~= true then
            state.phase = "error"
            state.message = noctalia.tr("preview.error", { status = tostring(res and res.status or 0) })
            render()
            return
        end
        local decoded, data = pcall(noctalia.json.decode, res.body)
        if not decoded or type(data) ~= "table" or type(data.data) ~= "table" then
            state.phase = "error"
            state.message = noctalia.tr("preview.bad_json")
            render()
            return
        end

        local d = data.data
        state.resolution = d.resolution
        state.purity = d.purity
        local dest = PREVIEW_DIR .. "/" .. tostring(id) .. "." .. extFromUrl(d.path)
        if noctalia.fileExists(dest) then
            state.path = dest
            state.phase = "ready"
            render()
            return
        end

        noctalia.mkdirAll(PREVIEW_DIR)
        noctalia.download(d.path, dest, function(ok)
            if my ~= gen then
                return
            end
            if ok == true and noctalia.fileExists(dest) then
                state.path = dest
                state.phase = "ready"
            else
                state.phase = "error"
                state.message = noctalia.tr("preview.download_failed")
            end
            render()
        end)
    end)
end

function onOpen(context)
    local id = trim(context)
    if id == "" then
        local ok, text = pcall(noctalia.readFile, CACHE_DIR .. "/current.id")
        if ok and type(text) == "string" then
            id = trim(text)
        end
    end
    prepare(id)
end

function onClose()
    noctalia.runAsync({ "noctalia", "msg", "panel-open", "computing/wallpaper-browser:browser" })
end

render()
