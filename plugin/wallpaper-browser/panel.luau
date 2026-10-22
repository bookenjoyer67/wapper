--!nonstrict
-- Wallpaper Browser: browse wallhaven.cc thumbnails and apply one by hand.
--
-- Same source as scripts/fetch-wallpaper.sh (wallhaven API v1,
-- SFW only), but you pick. Applying runs apply.sh, which updates the same
-- ~/.cache/wallpaper cache/current.id/recent bookkeeping and then calls
-- apply-wallpaper.sh (awww + matugen + Noctalia palette + lock backdrops).

local UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36"
local SITE = "https://wallhaven.cc/api/v1/search"

local TILE_W, TILE_H, COLS, GAP = 276, 155, 4, 14
local GRID_H = 596

-- Queries are read from the shared query list: the pool file, or
-- ~/.config/wallpaper/sets/<set>.txt when `set` is configured.

local SORTS = { "random", "toplist", "date_added", "relevance" }
local SORT_LABELS = { random = "Random", toplist = "Top rated", date_added = "Newest", relevance = "Relevance" }
local MINS = { "any", "1920x1080", "2560x1440", "3840x2160" }
local MIN_LABELS = { any = "Any size", ["1920x1080"] = "1080p+", ["2560x1440"] = "1440p+", ["3840x2160"] = "4K+" }

local pluginDir = noctalia.pluginDir()
local dataDir = noctalia.pluginDataDir() or "/tmp/noctalia-wallpaper-browser"
local thumbDir = dataDir .. "/thumbs"
local cacheDir = (noctalia.expandPath("~/.cache/wallpaper") or "") .. ""

noctalia.mkdirAll(thumbDir)

local function trim(s)
    return (tostring(s or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function expandPath(p)
    if type(p) ~= "string" or p == "" then
        return ""
    end
    local ok, out = pcall(noctalia.expandPath, p)
    if ok and type(out) == "string" and out ~= "" then
        return out
    end
    return p
end

-- Settings: ~/.config/wallpaper/settings, the same file, grammar and
-- precedence as scripts/read-settings.sh (env > file > default).
local WALLPAPER_DIR = expandPath("~/.config/wallpaper")
local SETS_DIR = WALLPAPER_DIR .. "/sets"
local FAV_FILE = WALLPAPER_DIR .. "/favorites"
local LEGACY_FAV = dataDir .. "/favorites.txt"
local SETTINGS_FILE = expandPath("~/.config/wallpaper/settings")

local DEFAULTS = {
    source = "pool",
    query = "",
    set = "",
    nsfw = "off",
    apikey = "",
    favorites = "~/.config/wallpaper/favorites",
    pool = "~/.config/wallpaper/pool.txt",
    min_sat = "0.30",
    min_res = "2560x1440",
}
local ENV_NAMES = {
    source = "WALLPAPER_SOURCE",
    query = "WALLPAPER_QUERY",
    set = "WALLPAPER_SET",
    nsfw = "WALLPAPER_NSFW",
    apikey = "WALLPAPER_APIKEY",
    favorites = "WALLPAPER_FAVORITES",
    pool = "WALLPAPER_POOL",
    min_sat = "WALLPAPER_MIN_SAT",
    min_res = "WALLPAPER_MIN_RES",
}
local PATH_KEYS = { favorites = true, pool = true }
local NSFW_LEVELS = { "off", "sketchy", "all" }

local function settingsPath()
    local env = noctalia.getenv and noctalia.getenv("WALLPAPER_SETTINGS") or nil
    if type(env) == "string" and trim(env) ~= "" then
        return expandPath(trim(env))
    end
    return SETTINGS_FILE
end

local function readSettings()
    local s = {}
    for k, v in pairs(DEFAULTS) do
        s[k] = v
    end
    local ok, text = pcall(noctalia.readFile, settingsPath())
    if ok and type(text) == "string" then
        for line in text:gmatch("[^\n]+") do
            local t = trim(line)
            if t ~= "" and t:sub(1, 1) ~= "#" then
                local key, value = t:match("^([^=]*)=(.*)$")
                if key ~= nil then
                    key = trim(key)
                    if DEFAULTS[key] ~= nil then
                        value = trim(value)
                        s[key] = (value ~= "" and value or DEFAULTS[key])
                    end
                end
            end
        end
    end
    if noctalia.getenv then
        for key, name in pairs(ENV_NAMES) do
            local v = noctalia.getenv(name)
            if type(v) == "string" and trim(v) ~= "" then
                s[key] = trim(v)
            end
        end
    end
    if s.source ~= "pool" and s.source ~= "favorites" and s.source ~= "query" then
        s.source = "pool"
    end
    if s.nsfw ~= "off" and s.nsfw ~= "sketchy" and s.nsfw ~= "all" then
        s.nsfw = "off"
    end
    for key in pairs(PATH_KEYS) do
        s[key] = expandPath(s[key])
    end
    return s
end

-- `set = <name>` swaps the pool for ~/.config/wallpaper/sets/<name>.txt, which
-- is the same rule scripts/fetch-wallpaper.sh applies.
local function effectiveListFile(settings)
    local s = settings or readSettings()
    if s.set ~= "" then
        return SETS_DIR .. "/" .. s.set .. ".txt"
    end
    return s.pool
end

-- The fetcher's "TERM * N" syntax, parsed the same way.
local function parseQueryLine(line)
    local t = trim(line)
    local term, weight = t:match("^(.-)%s+%*%s*(%d+)$")
    if term ~= nil then
        term = trim(term)
        weight = tonumber(weight) or 1
    else
        term = t
        weight = 1
    end
    if weight < 1 then
        weight = 1
    end
    if weight > 100 then
        weight = 100
    end
    return term, weight
end

-- The query list is the pool file, or the named set. Reads hand back the raw
-- lines, comments and blanks included, because the editor rewrites the file:
-- only the term line it adds or removes may change.
local function readListLines()
    local lines = {}
    local file = effectiveListFile()
    if file == "" then
        return lines
    end
    local ok, text = pcall(noctalia.readFile, file)
    if not ok or type(text) ~= "string" or text == "" then
        return lines
    end
    if text:sub(-1) ~= "\n" then
        text = text .. "\n"
    end
    -- "(.-)\n", not "[^\n]+": an empty line is a line the file has.
    for line in text:gmatch("(.-)\n") do
        lines[#lines + 1] = line
    end
    return lines
end

local function isTermLine(line)
    local t = trim(line)
    return t ~= "" and t:sub(1, 1) ~= "#"
end

-- Term lines only, trimmed, weights included, so "synthwave * 3" round-trips.
local function poolQueries()
    local out = {}
    for _, line in ipairs(readListLines()) do
        if isTermLine(line) then
            out[#out + 1] = trim(line)
        end
    end
    return out
end

local function saveListLines(lines)
    local file = effectiveListFile()
    if file == "" then
        return
    end
    noctalia.writeFile(file, table.concat(lines, "\n") .. "\n")
end

-- Mirror of the file for the current render: the term text plus the raw line it
-- came from, so Delete removes that line and leaves every other byte alone.
local queries = {}
local queryLines = {}

local function loadQueryRows()
    queries = {}
    queryLines = {}
    for i, line in ipairs(readListLines()) do
        if isTermLine(line) then
            queries[#queries + 1] = trim(line)
            queryLines[#queryLines + 1] = i
        end
    end
end

local function addQuery(text)
    local q = trim(text)
    if q == "" then
        return
    end
    local term = parseQueryLine(q)
    local lines = readListLines()
    for _, line in ipairs(lines) do
        if isTermLine(line) then
            local existing = parseQueryLine(trim(line))
            if existing:lower() == term:lower() then
                return
            end
        end
    end
    lines[#lines + 1] = q
    saveListLines(lines)
    render()
end

local function removeQuery(at)
    local lines = readListLines()
    if at == nil or lines[at] == nil or not isTermLine(lines[at]) then
        return
    end
    table.remove(lines, at)
    saveListLines(lines)
    render()
end

local query = ""
local inputText = ""
local view = "results" -- results | queries | history
local historyItems = {}
local favorites = {}
local favoriteIndex = {}
local loadHistory -- forward declaration, defined with the history reader
local persistNsfw -- forward declaration, defined with the settings writer
local cfg = nil -- last readSettings() for the current render
local nsfwIdx = nil -- slider position 1..3; nil until read from the file
local newQueryText = ""
local newQueryGen = 0
local sortMode = "random"
local minRes = "1920x1080"
local seed = tostring(math.random(100000, 999999))
local page = 1
local lastPage = 1
local total = 0
local items = {}
local status = nil
local busy = false
local currentId = nil
local inputGen = 0

-- ---------------------------------------------------------------- helpers

local function pct(s)
    return (tostring(s):gsub("[^%w%-%._~]", function(c)
        return string.format("%%%02X", string.byte(c))
    end))
end

-- nsfw -> wallhaven purity. sketchy and all only widen the results when an
-- apikey is set; the status line says so when it is not.
local function purity(settings)
    if settings.nsfw == "sketchy" then
        return 110
    end
    if settings.nsfw == "all" then
        return 111
    end
    return 100
end

-- /search already carries a query string ('&'), /w/<id> does not ('?').
local function apiKeyFor(settings, kind)
    if settings.apikey == "" then
        return ""
    end
    if kind == "detail" then
        return "?apikey=" .. settings.apikey
    end
    return "&apikey=" .. settings.apikey
end

local function nsfwIndexFrom(level)
    for i, v in ipairs(NSFW_LEVELS) do
        if v == level then
            return i
        end
    end
    return 1
end

local function clampNsfw(value)
    local n = tonumber(value) or 1
    if n < 1 then
        n = 1
    elseif n > 3 then
        n = 3
    end
    return math.floor(n)
end

-- Same weight rule the fetcher applies, so the dice button and a random fetch
-- agree on what "a random pool term" means.
local function weightedPick(lines)
    local expanded = {}
    for _, line in ipairs(lines) do
        local term, weight = parseQueryLine(line)
        if term ~= "" then
            for _ = 1, weight do
                if #expanded >= 10000 then
                    break
                end
                expanded[#expanded + 1] = term
            end
        end
    end
    if #expanded == 0 then
        return nil
    end
    return expanded[math.random(#expanded)]
end

local function knownMinRes(value)
    for _, m in ipairs(MINS) do
        if m == value then
            return true
        end
    end
    return false
end

-- Seeded once, at module load: the select persists its choice through
-- set-setting.sh, so re-seeding on every open would discard what was picked.
do
    local stored = readSettings().min_res
    if knownMinRes(stored) then
        minRes = stored
    end
end

local function readCurrentId()
    local ok, text = pcall(noctalia.readFile, cacheDir .. "/current.id")
    if ok and type(text) == "string" then
        return (text:gsub("%s+$", ""))
    end
    return nil
end

local function inRecentOrRejected(id)
    for _, name in ipairs({ "recent", "rejected" }) do
        local ok, text = pcall(noctalia.readFile, cacheDir .. "/" .. name)
        if ok and type(text) == "string" then
            for line in text:gmatch("[^\n]+") do
                if line == id then
                    return true
                end
            end
        end
    end
    return false
end

local function ban(id)
    if id == nil or id == "" then
        return
    end
    local path = cacheDir .. "/rejected"
    local ok, text = pcall(noctalia.readFile, path)
    text = (ok and type(text) == "string") and text or ""
    if not text:find("%f[%w]" .. id .. "%f[%W]") then
        noctalia.writeFile(path, text .. (text ~= "" and not text:match("\n$") and "\n" or "") .. id .. "\n")
    end
    noctalia.notify(noctalia.tr("notify.banned_title"), noctalia.tr("notify.banned_body", { id = id }))
    render()
end

-- Open the wallpaper's page on wallhaven (its "source") in the default browser.
-- open-source.sh raises the browser window too: on niri, xdg-open alone appends
-- a tab to the existing instance and leaves it on whatever workspace it was on.
local function openSource(it)
    if type(it) ~= "table" or type(it.id) ~= "string" or it.id == "" then
        return
    end
    noctalia.runAsync({ "bash", pluginDir .. "/open-source.sh", "https://wallhaven.cc/w/" .. it.id }, function(res)
        if res ~= nil and res.exitCode ~= 0 then
            noctalia.notifyError(noctalia.tr("notify.open_failed_title"),
                tostring(res.stderr or ""):sub(1, 200))
        end
    end)
end

-- ---------------------------------------------------------------- network

local function fetchThumbs(list)
    list = list or items
    local lines = {}
    for _, it in ipairs(list) do
        local thumb = it.thumbs and (it.thumbs.large or it.thumbs.original or it.thumbs.small)
        if thumb == nil and type(it.id) == "string" and it.id:match("^%w%w%w%w+$") then
            -- history entries carry only the id; wallhaven thumb paths are derived from it
            thumb = "https://th.wallhaven.cc/lg/" .. it.id:sub(1, 2) .. "/" .. it.id .. ".jpg"
        end
        if thumb and not noctalia.fileExists(thumbDir .. "/" .. it.id .. ".jpg") then
            lines[#lines + 1] = it.id .. "\t" .. thumb
        end
    end
    if #lines == 0 then
        return
    end
    local listFile = dataDir .. "/thumbs.list"
    noctalia.writeFile(listFile, table.concat(lines, "\n") .. "\n")
    noctalia.runAsync({ "bash", pluginDir .. "/thumbs.sh", thumbDir, listFile }, function()
        render()
    end)
end

local function search(q, p, fresh)
    q = trim(q)
    if q == "" then
        status = noctalia.tr("status.need_query")
        view = "results"
        render()
        return
    end
    query = q
    page = p or 1
    if fresh then
        seed = tostring(math.random(100000, 999999))
    end
    busy = true
    status = noctalia.tr("status.searching")
    render()

    local s = readSettings()
    cfg = s
    local url = SITE .. "?q=" .. pct(q) .. "&purity=" .. tostring(purity(s)) .. "&sorting=" .. (sortMode == "random" and "random" or sortMode)
        .. "&ratios=16x9,16x10,21x9&page=" .. tostring(page)
    if sortMode == "random" then
        url = url .. "&seed=" .. seed
    end
    if minRes ~= "any" then
        url = url .. "&atleast=" .. minRes
    end
    url = url .. apiKeyFor(s, "search")

    noctalia.http({ url = url, headers = { "User-Agent: " .. UA, "Accept: application/json" } }, function(res)
        busy = false
        if res == nil or res.ok ~= true then
            status = noctalia.tr("status.network", { status = tostring(res and res.status or 0) })
            render()
            return
        end
        local decoded, data = pcall(noctalia.json.decode, res.body)
        if not decoded or type(data) ~= "table" or type(data.data) ~= "table" then
            status = noctalia.tr("status.bad_json")
            render()
            return
        end
        items = data.data
        local meta = data.meta or {}
        total = tonumber(meta.total) or #items
        lastPage = math.max(1, tonumber(meta.last_page) or 1)
        page = tonumber(meta.current_page) or page
        status = nil
        render()
        fetchThumbs()
    end)
end

local function apply(it)
    if busy or it == nil then
        return
    end
    busy = true
    status = noctalia.tr("status.applying", { id = it.id })
    render()
    -- 60000 is the API's clamp maximum. Without it the call used the default
    -- (a few seconds) and a normal wallhaven download + palette regeneration blew
    -- through it: the process was killed after awww painted but before matugen
    -- ran, which surfaced as "Could not apply wallpaper" with an empty stderr,
    -- a wallpaper that WAS applied, and a theme that never changed.
    noctalia.runAsync({ "bash", pluginDir .. "/apply.sh", it.id, it.path }, function(res)
        busy = false
        if res ~= nil and res.exitCode == 0 then
            currentId = it.id
            status = noctalia.tr("status.applied", { id = it.id })
            if view == "history" then
                -- apply.sh appended the id; re-read so it lands at the top
                local refreshed = loadHistory and loadHistory() or nil
                if refreshed ~= nil and #refreshed > 0 then
                    historyItems = refreshed
                else
                    local reordered = { { id = it.id } }
                    for _, other in ipairs(historyItems) do
                        if other.id ~= it.id then
                            reordered[#reordered + 1] = other
                        end
                    end
                    historyItems = reordered
                end
            end
            noctalia.notify(noctalia.tr("notify.applied_title"),
                noctalia.tr("notify.applied_body", { id = it.id, res = tostring(it.resolution or "") }))
        else
            status = noctalia.tr("status.apply_failed", { id = it.id })
            noctalia.notifyError(noctalia.tr("notify.failed_title"),
                (res and tostring(res.stderr or ""):sub(1, 200)) or "")
        end
        render()
    end, 60000)
end

-- Where the scripts live: $WALLPAPER_SCRIPTS, then the two real deploy dirs.
-- ~/.local/bin is only a fallback: the scripts deploy to the niri dir.
local function resolveScriptsDir(name)
    local env = noctalia.getenv and noctalia.getenv("WALLPAPER_SCRIPTS") or nil
    if type(env) == "string" and trim(env) ~= "" then
        return expandPath(trim(env))
    end
    for _, candidate in ipairs({ "~/.config/niri/scripts", "~/.local/bin" }) do
        local dir = expandPath(candidate)
        if dir ~= "" and noctalia.fileExists(dir .. "/" .. name) then
            return dir
        end
    end
    return ""
end

-- The slider writes through bash, not through writeFile: set-setting.sh edits
-- the one line and keeps the commented template (writeFile would replace the
-- whole file), and there is exactly one implementation of the grammar.
persistNsfw = function(level)
    local dir = resolveScriptsDir("set-setting.sh")
    if dir == "" then
        status = noctalia.tr("status.save_unavailable")
        noctalia.notifyError(noctalia.tr("settings.title"), status)
        render()
        return
    end
    noctalia.runAsync({ "bash", dir .. "/set-setting.sh", "nsfw", level }, function(res)
        if res ~= nil and res.exitCode == 0 then
            cfg = readSettings()
            nsfwIdx = nsfwIndexFrom(cfg.nsfw)
            status = noctalia.tr("status.saved", { level = level })
        else
            status = noctalia.tr("status.save_failed")
            noctalia.notifyError(noctalia.tr("settings.title"), tostring((res and res.stderr) or ""):sub(1, 200))
        end
        render()
    end, 15000)
end

-- The resolution select persists through the same writer, and re-reads what
-- landed in the file, so the choice survives a restart and not just the panel.
local function persistMinRes(value)
    local dir = resolveScriptsDir("set-setting.sh")
    if dir == "" then
        status = noctalia.tr("status.save_unavailable")
        noctalia.notifyError(noctalia.tr("settings.min_res"), status)
        render()
        return
    end
    noctalia.runAsync({ "bash", dir .. "/set-setting.sh", "min_res", value }, function(res)
        if res ~= nil and res.exitCode == 0 then
            local stored = readSettings().min_res
            if knownMinRes(stored) then
                minRes = stored
            end
            status = noctalia.tr("status.min_res_saved", { value = value })
        else
            status = noctalia.tr("status.min_res_save_failed")
            noctalia.notifyError(noctalia.tr("settings.min_res"), tostring((res and res.stderr) or ""):sub(1, 200))
        end
        render()
    end, 15000)
end

-- ---------------------------------------------------------------- ui

-- History tiles carry only an id (the cache keeps one image), so resolve the
-- full image url from the API before applying.
local function pick(it)
    if type(it.path) == "string" and it.path ~= "" then
        apply(it)
        return
    end
    if busy then
        return
    end
    busy = true
    status = noctalia.tr("status.resolving", { id = it.id })
    render()
    local s = readSettings()
    noctalia.http({
        url = "https://wallhaven.cc/api/v1/w/" .. tostring(it.id) .. apiKeyFor(s, "detail"),
        headers = { "User-Agent: " .. UA, "Accept: application/json" },
    }, function(res)
        local decoded, data = false, nil
        if res ~= nil and res.ok == true then
            decoded, data = pcall(noctalia.json.decode, res.body)
        end
        local entry = decoded and type(data) == "table" and data.data or nil
        busy = false
        if type(entry) ~= "table" or type(entry.path) ~= "string" then
            status = noctalia.tr("status.apply_failed", { id = tostring(it.id) })
            render()
            return
        end
        it.path = entry.path
        it.resolution = entry.resolution
        it.thumbs = entry.thumbs
        apply(it)
    end)
end

-- Previous wallpapers: ~/.cache/wallpaper/history (append-only, "id<TAB>epoch",
-- capped at 1000 by the writers). Falls back to the 30-entry `recent` ring the
-- first time, so an existing setup still shows something.
local function readIds(path, withStamp)
    local ids = {}
    local ok, text = pcall(noctalia.readFile, path)
    if ok and type(text) == "string" then
        for line in text:gmatch("[^\n]+") do
            local raw = trim(line)
            local id, stamp = raw, nil
            if withStamp then
                id, stamp = raw:match("^(%S+)%s*(%S*)$")
            end
            id = trim(id or "")
            if id:match("^%w%w%w%w+$") then
                ids[#ids + 1] = { id = id, stamp = tonumber(stamp or "") }
            end
        end
    end
    return ids
end

loadHistory = function()
    local ids = readIds(cacheDir .. "/history", true)
    if #ids == 0 then
        -- first run: seed from the ring buffer so the view isn't empty
        local recent = readIds(cacheDir .. "/recent", false)
        if #recent > 0 then
            local lines = {}
            for _, it in ipairs(recent) do
                lines[#lines + 1] = it.id .. "\t0"
            end
            noctalia.writeFile(cacheDir .. "/history", table.concat(lines, "\n") .. "\n")
            ids = readIds(cacheDir .. "/history", true)
        end
    end

    -- newest first, and one entry per id (re-applying moves it to the top)
    local list = {}
    local seen = {}
    for i = #ids, 1, -1 do
        local it = ids[i]
        if not seen[it.id] then
            seen[it.id] = true
            list[#list + 1] = it
        end
    end
    return list
end

-- Favourites: wallhaven ids, one per line, in the same file the random fetcher
-- reads (~/.config/wallpaper/favorites). Only the id is stored — path and
-- resolution are resolved through /w/<id> when a tile is applied.
local function favoritesPath()
    local s = readSettings()
    if s.favorites ~= "" then
        return s.favorites
    end
    return FAV_FILE
end

local function saveFavorites()
    local path = favoritesPath()
    if path == "" then
        return
    end
    local lines = {}
    for _, f in ipairs(favorites) do
        lines[#lines + 1] = f.id
    end
    noctalia.mkdirAll(WALLPAPER_DIR)
    noctalia.writeFile(path, table.concat(lines, "\n") .. (#lines > 0 and "\n" or ""))
end

-- The old list lived in the plugin data dir as "id<TAB>path<TAB>resolution".
-- Move the ids into the shared file once, then it is the only list.
local function migrateLegacyFavorites(path)
    if path == "" or path == LEGACY_FAV then
        return
    end
    if noctalia.fileExists(path) or not noctalia.fileExists(LEGACY_FAV) then
        return
    end
    local ok, text = pcall(noctalia.readFile, LEGACY_FAV)
    if not ok or type(text) ~= "string" then
        return
    end
    local ids = {}
    local seen = {}
    for line in text:gmatch("[^\n]+") do
        local id = trim(line:match("^([^\t]*)") or "")
        if id:match("^%w%w%w%w+$") and not seen[id] then
            seen[id] = true
            ids[#ids + 1] = id
        end
    end
    if #ids == 0 then
        return
    end
    noctalia.mkdirAll(WALLPAPER_DIR)
    if noctalia.writeFile(path, table.concat(ids, "\n") .. "\n") then
        status = noctalia.tr("favorites.migrated", { count = #ids })
    end
end

local function loadFavorites()
    local list = {}
    local index = {}
    local path = favoritesPath()
    if path ~= "" then
        migrateLegacyFavorites(path)
        local ok, text = pcall(noctalia.readFile, path)
        if ok and type(text) == "string" then
            for line in text:gmatch("[^\n]+") do
                local id = trim(line)
                if id:match("^%w%w%w%w+$") and index[id] == nil then
                    list[#list + 1] = { id = id }
                    index[id] = #list
                end
            end
        end
    end
    favorites = list
    favoriteIndex = index
    return list
end

local function toggleFavorite(it)
    if type(it) ~= "table" or type(it.id) ~= "string" then
        return
    end
    local at = favoriteIndex[it.id]
    if at ~= nil then
        table.remove(favorites, at)
    else
        table.insert(favorites, 1, { id = it.id })
    end
    saveFavorites()
    loadFavorites()
    render()
end

local function tile(it)
    local path = thumbDir .. "/" .. it.id .. ".jpg"
    local have = noctalia.fileExists(path)
    local isCurrent = currentId ~= nil and currentId == it.id

    local preview
    if have then
        preview = ui.image({
            key = "img-" .. it.id,
            path = path,
            width = TILE_W,
            height = TILE_H,
            radius = 8,
            fit = "cover",
            border = isCurrent and "primary" or nil,
            borderWidth = isCurrent and 2 or nil,
            onClick = function()
                pick(it)
            end,
        })
    else
        preview = ui.box({
            key = "ph-" .. it.id,
            width = TILE_W,
            height = TILE_H,
            radius = 8,
            fill = "surface_variant",
            onClick = function()
                pick(it)
            end,
        })
    end

    local isFav = favoriteIndex[it.id] ~= nil
    local caption = ui.row({ justify = "space_between", align = "center", width = TILE_W, gap = 2 }, {
        ui.label({
            text = tostring(it.resolution or it.id or "") .. (isCurrent and "  •current" or ""),
            fontSize = 10,
            color = isCurrent and "primary" or "on_surface_variant",
            maxLines = 1,
            flexGrow = 1,
        }),
        ui.button({
            key = "src-" .. it.id,
            glyph = "external-link",
            glyphSize = 12,
            variant = "ghost",
            controlSize = "sm",
            tooltip = noctalia.tr("tooltip.source"),
            onClick = function()
                openSource(it)
            end,
        }),
        ui.button({
            glyph = "star",
            glyphSize = 12,
            variant = isFav and "primary" or "ghost",
            controlSize = "sm",
            tooltip = noctalia.tr(isFav and "tooltip.unfavorite" or "tooltip.favorite"),
            onClick = function()
                toggleFavorite(it)
            end,
        }),
        ui.button({
            glyph = "ban",
            glyphSize = 12,
            variant = "ghost",
            controlSize = "sm",
            tooltip = noctalia.tr("tooltip.ban"),
            onClick = function()
                ban(it.id)
            end,
        }),
    })

    return ui.column({ key = it.id, gap = 4, width = TILE_W, flexGrow = 1, align = "center" }, { preview, caption })
end

local function grid(list, emptyText)
    list = list or items
    if #list == 0 then
        return ui.column({ gap = 8, align = "center" }, {
            ui.label({ text = emptyText or status or noctalia.tr("empty.none"), color = "on_surface_variant", fontSize = 13 }),
        })
    end

    local rows = {}
    local row = {}
    for index, it in ipairs(list) do
        row[#row + 1] = tile(it)
        if #row == COLS or index == #list then
            rows[#rows + 1] = ui.row({ gap = GAP, align = "start" }, row)
            row = {}
        end
    end

    return ui.column({ gap = 12, align = "stretch" }, rows)
end

local function selectOptions(list)
    local out = {}
    for i, v in ipairs(list) do
        out[i] = v
    end
    return out
end

-- The status slot doubles as the honesty hint: nsfw above off returns only SFW
-- results until an apikey is set, and the panel must not imply otherwise.
local function statusText()
    if status ~= nil then
        return status
    end
    local s = cfg or readSettings()
    if s.nsfw ~= "off" and s.apikey == "" then
        return noctalia.tr("settings.nsfw_needs_key")
    end
    return string.format("%d images · %s", total, query)
end

local function header()
    local sortLabels = {}
    for _, s in ipairs(SORTS) do
        sortLabels[#sortLabels + 1] = SORT_LABELS[s] or s
    end
    local minLabels = {}
    for _, m in ipairs(MINS) do
        minLabels[#minLabels + 1] = MIN_LABELS[m] or m
    end

    local sortIdx = 1
    for i, s in ipairs(SORTS) do
        if s == sortMode then
            sortIdx = i - 1
        end
    end
    local minIdx = 1
    for i, m in ipairs(MINS) do
        if m == minRes then
            minIdx = i - 1
        end
    end
    local curNsfw = nsfwIdx or nsfwIndexFrom(cfg and cfg.nsfw or "off")

    local row1 = ui.row({ gap = 10, align = "center" }, {
        ui.label({ text = "Wallpapers", fontSize = 16, fontWeight = "bold", color = "primary" }),
        ui.input({
            key = "q-" .. tostring(inputGen),
            value = inputText,
            placeholder = noctalia.tr("search.placeholder"),
            flexGrow = 1,
            submitOnEnter = true,
            onChange = function(value)
                inputText = value
            end,
            onSubmit = function(value)
                inputText = value
                search(value, 1, true)
            end,
        }),
        ui.button({
            text = noctalia.tr("button.search"),
            variant = "primary",
            onClick = function()
                search(inputText, 1, true)
            end,
        }),
        ui.button({
            glyph = "dice",
            text = noctalia.tr("button.shuffle"),
            variant = "secondary",
            tooltip = noctalia.tr("tooltip.shuffle"),
            onClick = function()
                local terms = poolQueries()
                local term = weightedPick(terms)
                if term == nil then
                    status = noctalia.tr("queries.empty")
                    view = "queries"
                    render()
                    return
                end
                inputText = term
                inputGen = inputGen + 1
                search(inputText, 1, true)
            end,
        }),
        ui.button({
            glyph = "close",
            variant = "ghost",
            tooltip = noctalia.tr("tooltip.close"),
            onClick = function()
                panel.close()
            end,
        }),
    })

    local row2 = ui.row({ gap = 10, align = "center" }, {
        ui.select({
            options = selectOptions(sortLabels),
            selectedIndex = sortIdx,
            width = 140,
            controlSize = "sm",
            onChange = function(index)
                sortMode = SORTS[(tonumber(index) or 0) + 1] or "random"
                search(query, 1, true)
            end,
        }),
        ui.select({
            options = selectOptions(minLabels),
            selectedIndex = minIdx,
            width = 130,
            controlSize = "sm",
            onChange = function(index)
                minRes = MINS[(tonumber(index) or 0) + 1] or "any"
                persistMinRes(minRes)
                search(query, 1, true)
            end,
        }),
        ui.slider({
            key = "nsfw",
            min = 1,
            max = 3,
            step = 1,
            value = curNsfw,
            controlSize = "sm",
            width = 140,
            onChange = function(value)
                nsfwIdx = clampNsfw(value)
                render()
            end,
            onDragEnd = function(value)
                nsfwIdx = clampNsfw(value)
                persistNsfw(NSFW_LEVELS[nsfwIdx])
            end,
        }),
        ui.label({
            text = noctalia.tr("settings.nsfw_" .. NSFW_LEVELS[curNsfw]),
            fontSize = 12,
            color = "on_surface_variant",
            maxLines = 1,
        }),
        ui.button({
            glyph = "chevron-left",
            variant = "ghost",
            controlSize = "sm",
            enabled = page > 1 and not busy,
            onClick = function()
                search(query, math.max(1, page - 1), false)
            end,
        }),
        ui.label({ text = string.format("%d / %d", page, lastPage), fontSize = 12, color = "on_surface_variant" }),
        ui.button({
            glyph = "chevron-right",
            variant = "ghost",
            controlSize = "sm",
            enabled = page < lastPage and not busy,
            onClick = function()
                search(query, math.min(lastPage, page + 1), false)
            end,
        }),
        ui.button({
            glyph = "list",
            text = noctalia.tr("button.queries"),
            variant = view == "queries" and "secondary" or "ghost",
            controlSize = "sm",
            tooltip = noctalia.tr("tooltip.queries"),
            onClick = function()
                view = view == "queries" and "results" or "queries"
                render()
            end,
        }),
        ui.button({
            glyph = "history",
            text = noctalia.tr("button.history"),
            variant = view == "history" and "secondary" or "ghost",
            controlSize = "sm",
            tooltip = noctalia.tr("tooltip.history"),
            onClick = function()
                if view == "history" then
                    view = "results"
                    render()
                    return
                end
                view = "history"
                historyItems = loadHistory()
                render()
                fetchThumbs(historyItems)
            end,
        }),
        ui.button({
            glyph = "star",
            text = noctalia.tr("button.favorites"),
            variant = view == "favorites" and "secondary" or "ghost",
            controlSize = "sm",
            tooltip = noctalia.tr("tooltip.favorites"),
            onClick = function()
                if view == "favorites" then
                    view = "results"
                    render()
                    return
                end
                view = "favorites"
                loadFavorites()
                render()
                fetchThumbs(favorites)
            end,
        }),
        ui.separator({ orientation = "vertical", spacing = 4 }),
        ui.label({
            text = statusText(),
            fontSize = 12,
            color = status and "primary" or "on_surface_variant",
            flexGrow = 1,
            maxLines = 1,
        }),
    })

    return ui.column({ gap = 10 }, { row1, row2 })
end

local function queriesPanel()
    local rows = {}
    for i, q in ipairs(queries) do
        rows[#rows + 1] = ui.row({ key = "qrow-" .. q, gap = 8, align = "center" }, {
            ui.label({ text = q, fontSize = 13, flexGrow = 1, maxLines = 1, color = "on_surface" }),
            ui.button({
                glyph = "search",
                glyphSize = 12,
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr("tooltip.use"),
                onClick = function()
                    local term = parseQueryLine(q)
                    inputText = term
                    inputGen = inputGen + 1
                    view = "results"
                    search(term, 1, true)
                end,
            }),
            ui.button({
                glyph = "trash",
                glyphSize = 12,
                variant = "ghost",
                controlSize = "sm",
                tooltip = noctalia.tr("tooltip.delete"),
                onClick = function()
                    removeQuery(queryLines[i])
                end,
            }),
        })
    end
    if #rows == 0 then
        rows[1] = ui.label({ text = noctalia.tr("queries.empty"), color = "on_surface_variant", fontSize = 12 })
    end

    local addRow = ui.row({ gap = 8, align = "center" }, {
        ui.input({
            key = "newq-" .. tostring(newQueryGen),
            value = newQueryText,
            placeholder = noctalia.tr("queries.placeholder"),
            flexGrow = 1,
            submitOnEnter = true,
            onChange = function(value)
                newQueryText = value
            end,
            onSubmit = function(value)
                newQueryText = ""
                newQueryGen = newQueryGen + 1
                addQuery(value)
            end,
        }),
        ui.button({
            glyph = "plus",
            text = noctalia.tr("queries.add"),
            variant = "primary",
            onClick = function()
                local value = newQueryText
                newQueryText = ""
                newQueryGen = newQueryGen + 1
                addQuery(value)
            end,
        }),
    })

    return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({ text = noctalia.tr("queries.title"), fontSize = 14, fontWeight = "bold", color = "primary", flexGrow = 1 }),
            ui.label({ text = string.format("%d", #queries), fontSize = 12, color = "on_surface_variant" }),
        }),
        addRow,
        ui.scroll({ flexGrow = 1, gap = 4 }, rows),
    })
end

local function historyPanel()
    local body
    if #historyItems == 0 then
        body = ui.column({ gap = 8, align = "center" }, {
            ui.label({ text = noctalia.tr("history.empty"), color = "on_surface_variant", fontSize = 13 }),
        })
    else
        body = ui.scroll({ flexGrow = 1, gap = 12 }, { grid(historyItems) })
    end
    return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({
                text = noctalia.tr("history.title"),
                fontSize = 14,
                fontWeight = "bold",
                color = "primary",
                flexGrow = 1,
            }),
            ui.label({ text = string.format("%d", #historyItems), fontSize = 12, color = "on_surface_variant" }),
            ui.button({
                glyph = "refresh",
                controlSize = "sm",
                variant = "ghost",
                tooltip = noctalia.tr("history.reload"),
                onClick = function()
                    historyItems = loadHistory()
                    render()
                    fetchThumbs(historyItems)
                end,
            }),
        }),
        body,
    })
end

local function favoritesPanel()
    local body
    if #favorites == 0 then
        body = ui.column({ gap = 8, align = "center" }, {
            ui.label({ text = noctalia.tr("favorites.empty"), color = "on_surface_variant", fontSize = 13 }),
        })
    else
        body = ui.scroll({ flexGrow = 1, gap = 12 }, { grid(favorites) })
    end
    return ui.column({ gap = 10, flexGrow = 1, align = "stretch" }, {
        ui.row({ gap = 8, align = "center" }, {
            ui.label({
                text = noctalia.tr("favorites.title"),
                fontSize = 14,
                fontWeight = "bold",
                color = "primary",
                flexGrow = 1,
            }),
            ui.label({ text = string.format("%d", #favorites), fontSize = 12, color = "on_surface_variant" }),
            ui.button({
                glyph = "refresh",
                controlSize = "sm",
                variant = "ghost",
                tooltip = noctalia.tr("favorites.reload"),
                onClick = function()
                    loadFavorites()
                    render()
                    fetchThumbs(favorites)
                end,
            }),
        }),
        body,
    })
end

function render()
    cfg = readSettings()
    loadQueryRows()
    local body
    if view == "queries" then
        body = queriesPanel()
    elseif view == "favorites" then
        body = favoritesPanel()
    elseif view == "history" then
        body = historyPanel()
    else
        body = ui.scroll({ flexGrow = 1, gap = 12 }, { grid() })
    end
    panel.render(ui.column({ flexGrow = 1, gap = 12, padding = 16, align = "stretch" }, { header(), body }))
end

-- ---------------------------------------------------------------- lifecycle

function onOpen()
    currentId = readCurrentId()
    cfg = readSettings()
    nsfwIdx = nsfwIndexFrom(cfg.nsfw)
    if view == "history" then
        historyItems = loadHistory()
        render()
        fetchThumbs(historyItems)
        return
    end
    if view == "favorites" then
        loadFavorites()
        render()
        fetchThumbs(favorites)
        return
    end
    render()
    if #items > 0 then
        fetchThumbs()
    end
end

function onIpc(event, payload)
    if event == "search" and type(payload) == "string" and payload ~= "" then
        inputText = payload
        inputGen = inputGen + 1
        search(payload, 1, true)
    elseif event == "opensrc" and type(payload) == "string" then
        openSource({ id = payload })
    elseif event == "apply" and type(payload) == "string" then
        for _, it in ipairs(items) do
            if it.id == payload then
                apply(it)
                return
            end
        end
    end
end

loadFavorites()
render()
