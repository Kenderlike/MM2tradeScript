local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")
local TextService = game:GetService("TextService")

local PartnerUserBox
local ToggleOpponentAcceptance
local PartnerFakeOwned = {} 

local function FormatValue(v)
    if v == nil then return "?" end
    if type(v) == "number" then
        local s = tostring(math.floor(v))
        local k
        repeat s, k = string.gsub(s, "^(-?%d+)(%d%d%d)", "%1,%2") until k == 0
        return s
    end
    return tostring(v)
end

if not table.clear then
    function table.clear(t)
        for k in pairs(t) do
            t[k] = nil
        end
    end
end

setthreadidentity(2)
local ProfileData = require(game.ReplicatedStorage.Modules.ProfileData)
local InventoryModule = require(game.ReplicatedStorage.Modules.InventoryModule)
local ItemModule = require(game.ReplicatedStorage.Modules.ItemModule)
local Sync = require(game.ReplicatedStorage.Database.Sync)
local ItemPopupService = require(game.ReplicatedStorage.ClientServices.ItemPopupService)
setthreadidentity(8)

local TradeRemotes = game.ReplicatedStorage.Trade

local TradeGUI = game.Players.LocalPlayer.PlayerGui.TradeGUI
local TheirOffer = TradeGUI.Container.Trade.TheirOffer
local YourOffer = TradeGUI.Container.Trade.YourOffer

local SearchTextSignal
local TradeInventory

local functions = {}

local Config = {
    ["item"] = "",
    ["in_trade"] = false,
    ["player2"] = nil
}

local UntradableRarities = { Unique = true }
local UntradableRarityExceptions = { corrupt = true }

local UntradableFamilies = {
    "reaver",
    "gingerscythe",
    "icecrusher",
    "synthwave",
}

local EvoPrefixes = {
    Blue = true, Bronze = true, Silver = true, Gold = true,
    Platinum = true, Diamond = true, Emerald = true, Ruby = true,
    Obsidian = true, Crystal = true,
}

local function _isEvoWeapon(name, data)
    if type(data) == "table" then
        if data.Evo == true or data.Evolution == true then return true end
        if data.IsEvo == true or data.EvoTier ~= nil then return true end
        if type(data.MaxStack) == "number" and data.MaxStack <= 1 then return true end
        if type(data.MaxAmount) == "number" and data.MaxAmount <= 1 then return true end
    end
    if name then
        local firstWord = string.match(tostring(name), "^(%S+)")
        if firstWord and EvoPrefixes[firstWord] then return true end
    end
    return false
end

local function _isTradable(data)
    if type(data) ~= "table" then return false end
    if data.Tradable == false then return false end
    if data.CanTrade == false then return false end
    if data.Untradable == true then return false end
    if data.NonTradable == true then return false end
    if data.Locked == true then return false end
    return true
end

local function _blockKey(s)
    return (string.gsub(string.lower(tostring(s or "")), "[^%a%d]", ""))
end

local function WeaponBlockReason(name, rarity, data)
    local flat = _blockKey(name)

    if flat == "" or string.find(tostring(name or ""), "?", 1, true) then
        return "неопубликованный заполнитель"
    end

    for _, family in ipairs(UntradableFamilies) do
        if string.find(flat, family, 1, true) then
            return "эволюционное оружие из gamepass (untradable на всех стадиях)"
        end
    end

    if UntradableRarities[rarity] and not UntradableRarityExceptions[flat] then
        return "не подлежит обмену: " .. tostring(rarity)
    end

    if not _isTradable(data) then
        return "помечено игрой как недоступное для обмена"
    end

    if _isEvoWeapon(name, data) then
        return "эволюционный / рейтинговый вариант"
    end

    return nil
end

local BlockedWeaponKeys = {}

local WeaponCatalog = {}
local WeaponByKey = {}
local WeaponByName = {}
local RareWeaponKeys = {}
local RareRarities = { Godly = true, Ancient = true, Unique = true, Chroma = true, Legendary = true, Classic = true }
do
    local source = Sync.Weapons or Sync.Item
    local blockedCount = 0
    for key, data in pairs(source) do
        if type(data) == "table"
           and (data.ItemType == "Knife" or data.ItemType == "Gun") then
            local rarity = data.Rarity or "Common"
            local isChroma = data.Chroma == true
            local name = data.ItemName or key

            local blockReason = WeaponBlockReason(name, rarity, data)
            if blockReason then
                BlockedWeaponKeys[key] = blockReason
                blockedCount = blockedCount + 1
            else
                local effectiveRarity = isChroma and "Chroma" or rarity
                local entry = {
                    key = key,
                    name = name,
                    rarity = effectiveRarity,
                    type = data.ItemType,
                    chroma = isChroma,
                }
                table.insert(WeaponCatalog, entry)
                WeaponByKey[key] = entry
                WeaponByName[string.lower(entry.name)] = entry
                if RareRarities[effectiveRarity] then
                    table.insert(RareWeaponKeys, key)
                end
            end
        end
    end
    local rarityOrder = {
        Chroma = 1, Godly = 2, Ancient = 3, Unique = 4, Legendary = 5, Classic = 6,
        Vintage = 7, Rare = 8, Uncommon = 9, Common = 10,
    }
    table.sort(WeaponCatalog, function(a, b)
        local ra = rarityOrder[a.rarity] or 99
        local rb = rarityOrder[b.rarity] or 99
        if ra ~= rb then return ra < rb end
        if a.type ~= b.type then return a.type < b.type end
        return a.name < b.name
    end)
end

local MESHES_URL = "https://raw.githubusercontent.com/Mm2script-maker/mm2-mesh-data/refs/heads/main/mm2_meshes_data.lua"
local MESHES = {}
do
    local ok, res = pcall(function()
        local src = game:HttpGet(MESHES_URL)

        src = string.gsub(src, "([%w_]+)%s*%+=%s*1", "%1 = %1 + 1")
        src = string.gsub(src, "([%w_]+)%s*%+=%s*", "%1 = %1 + ")
        local fn, err = loadstring(src)
        if not fn then
            error(err or "не удалось выполнить loadstring")
        end
        return fn()
    end)
    if ok and type(res) == "table" then
        MESHES = res
        local n = 0
        for _ in pairs(MESHES) do
            n = n + 1
        end
        if n == 0 then
        end
    else
    end
end

local function HasMesh(key)
    return type(MESHES) == "table" and type(key) == "string" and MESHES[key] ~= nil
end

local PRICES_URL = "https://raw.githubusercontent.com/OneClickLua/ParserMM2/refs/heads/main/prices.json"
local ItemValues = {}
local AssetPrices = {}
local PricesLoaded = false
local PricesLoadError = nil

local function ParseNumericPrice(value)
    if type(value) == "number" then
        return value
    end
    if type(value) == "table" then
        return ParseNumericPrice(value.value or value.Value or value.price or value.Price)
    end
    if type(value) ~= "string" then
        return nil
    end

    local normalized = string.lower(value)
    normalized = string.gsub(normalized, ",", "")
    normalized = string.gsub(normalized, "%s+", "")

    -- Метки уровней (например, "x2 T1"), Priceless и необмениваемые предметы
    -- не имеют числовой цены и не должны проходить фильтр диапазона.
    local amount, suffix = string.match(normalized, "^([%d]+%.?[%d]*)([km]?)$")
    amount = tonumber(amount)
    if not amount then
        return nil
    end
    if suffix == "k" then
        amount = amount * 1000
    elseif suffix == "m" then
        amount = amount * 1000000
    end
    return amount
end

local function StoreItemValue(name, rawValue)
    local value = ParseNumericPrice(rawValue)
    if value == nil then
        return
    end
    name = tostring(name)
    ItemValues[name] = value
    ItemValues[string.lower(name)] = value
end

local function LoadPriceDatabase()
    local lastError = "неизвестная ошибка"
    for attempt = 1, 4 do
        local ok, result = pcall(function()
            local body = game:HttpGet(PRICES_URL)
            return game:GetService("HttpService"):JSONDecode(body)
        end)

        if ok and type(result) == "table" then
            local byCode = result.by_code or result.byCode or result.values or result.Values or result
            if type(byCode) == "table" then
                for code, rawValue in pairs(byCode) do
                    StoreItemValue(code, rawValue)
                end
            end

            local byAsset = result.by_asset or result.byAsset
            if type(byAsset) == "table" then
                for assetId, rawValue in pairs(byAsset) do
                    AssetPrices[tostring(assetId)] = rawValue
                end
            end

            PricesLoaded = true
            PricesLoadError = nil
            return true
        end

        lastError = ok and "неверная структура JSON" or tostring(result)
        if attempt < 4 then
            task.wait(0.75)
        end
    end

    PricesLoadError = lastError
    return false
end

LoadPriceDatabase()

local function TryGetItemValue(key, displayName)
    if key and ItemValues[key] then return ItemValues[key] end
    if key and ItemValues[string.lower(tostring(key))] then return ItemValues[string.lower(tostring(key))] end
    if displayName and ItemValues[displayName] then return ItemValues[displayName] end
    if displayName and ItemValues[string.lower(tostring(displayName))] then
        return ItemValues[string.lower(tostring(displayName))]
    end
    
    local e = WeaponByKey[key]
    if e then
        if ItemValues[e.name] then return ItemValues[e.name] end
        if ItemValues[string.lower(e.name)] then return ItemValues[string.lower(e.name)] end
    end
    return nil
end

local function GetItemValue(key, displayName)
    local value = TryGetItemValue(key, displayName)
    if value ~= nil then
        return value
    end
    return 0
end

local TradeAvoidFlat = {
    "beachy", "chromabeachy",
    "heartwand", "chromaheartwand",
    "icecream", "chromaicecream",
    "sweet", "chromasweet",
    "treat", "chromatreat",
    "nikscythe", "nikknife", "niksscythe",
    "deathshard", "chromadeathshard",
    "fang", "chromafang",
    "celestial",
    "blizzard", "chromablizzard",
    "cookiecane", "chromacookiecane", "gingermint", "gingermintk", "gingermint_k",
    "snowstorm", "chromasnowstorm",
    "wintersedge", "winteredge",
    "darkshot",
}
local TradeAvoidSet = {}
for _, s in ipairs(TradeAvoidFlat) do
    TradeAvoidSet[s] = true
end

local function _flatKey(s)
    return (string.gsub(string.lower(tostring(s or "")), "[^%a%d]", ""))
end

local function IsTradeAvoided(key, name)
    local fk = _flatKey(key)
    local fn = _flatKey(name)
    if fk ~= "" and TradeAvoidSet[fk] then
        return true
    end
    if fn ~= "" and TradeAvoidSet[fn] then
        return true
    end
    
    for _, bad in ipairs(TradeAvoidFlat) do
        if fk ~= "" and string.find(fk, bad, 1, true) then
            return true
        end
        if fn ~= "" and string.find(fn, bad, 1, true) then
            return true
        end
    end
    return false
end

local function _ownedEntry(k, v)
    if type(k) == "number" then
        if type(v) == "string" then return v, 1 end
        if type(v) == "table" then
            return (v.Name or v.ItemName or v.Key or v.Id), (tonumber(v.Amount) or 1)
        end
        return nil, 0
    end
    if type(v) == "number" then return k, v end
    if type(v) == "table" then return k, (tonumber(v.Amount) or 1) end
    return k, 1
end

local function PurgeBlockedFromInventory()
    local removed = 0
    pcall(function()
        local owned = ProfileData.Weapons and ProfileData.Weapons.Owned
        if type(owned) ~= "table" then return end

        local kill = {}
        for k, v in pairs(owned) do
            local itemKey, amount = _ownedEntry(k, v)
            if itemKey then
                local data = Sync.Weapons and Sync.Weapons[itemKey]
                local displayName = (type(data) == "table" and data.ItemName) or tostring(itemKey)
                local rarity = (type(data) == "table" and (data.Rarity or "Common")) or "?"

                local reason
                if type(data) ~= "table" then
                    reason = "нет записи в базе оружия (отображается как ???)"
                else
                    reason = WeaponBlockReason(displayName, data.Rarity or "Common", data)
                end

                if reason then
                    table.insert(kill, { k = k, name = displayName, reason = reason })
                end
            end
        end

        for _, item in ipairs(kill) do
            owned[item.k] = nil
            removed = removed + 1
        end
    end)

    if removed > 0 then
        pcall(function()
            game.ReplicatedStorage.Remotes.Inventory.InventoryDataChanged:Fire()
        end)
    end
    return removed
end

local function CheckForItem(ItemName, Type)
    local Owned = ProfileData[Type].Owned
    for Index, Value in pairs(Owned) do
        if Index == ItemName then
            return true, Value
        end
        if Value == ItemName then
            return true, 1
        end
    end
    return false
end

local function CheckForItem2(ItemName, Type)
    return true, math.huge
end

local connectionMap = {}
local function hideContainer(container)
    for _, child in pairs(container:GetChildren()) do
        if child:IsA("Frame") then
            child.Visible = false
            if connectionMap[child] then
                connectionMap[child]:Disconnect()
                connectionMap[child] = nil
            end
        end
    end
end

local TradeTable = {
    ["LastOffer"] = os.time(),
    ["Locked"] = false,
    ["Player1"] = {
        ["Player"] = game.Players.LocalPlayer,
        ["Accepted"] = false,
        ["Offer"] = {}
    },
    ["Player2"] = {
        ["Player"] = "Kenderlike",
        ["Accepted"] = false,
        ["Offer"] = {}
    },
}

local function SpawnItem(ItemName, Amount, ItemType)
    Amount = Amount or 1
    ItemType = ItemType or "Weapons"
    if ItemType == "Weapons" and BlockedWeaponKeys[ItemName] then
        return
    end
    pcall(function()
        if ProfileData[ItemType].Owned[ItemName] == nil then
            ProfileData[ItemType].Owned[ItemName] = Amount
        else
            ProfileData[ItemType].Owned[ItemName] = ProfileData[ItemType].Owned[ItemName] + Amount
        end
        game.ReplicatedStorage.Remotes.Inventory.InventoryDataChanged:Fire()
    end)
end

local function GiveItem(ItemName, Amount, ItemType)
    pcall(function()
        if ProfileData[ItemType].Owned[ItemName] == nil then
            ProfileData[ItemType].Owned[ItemName] = Amount
        else
            ProfileData[ItemType].Owned[ItemName] = ProfileData[ItemType].Owned[ItemName] + Amount
        end
        ItemPopupService.ItemReceived:Fire(ItemName, ItemType)
        game.ReplicatedStorage.Remotes.Inventory.InventoryDataChanged:Fire()
    end)
end

local function RemoveItem(ItemName, Amount, ItemType)
    pcall(function()
        local owned = ProfileData[ItemType].Owned[ItemName]
        if not owned then
            return
        end
        if owned - Amount > 0 then
            ProfileData[ItemType].Owned[ItemName] = owned - Amount
        else
            ProfileData[ItemType].Owned[ItemName] = nil
        end
        game.ReplicatedStorage.Remotes.Inventory.InventoryDataChanged:Fire()
    end)
end

local tradeCompleting = false

local ApplyPartnerTradeVisual = nil
local PartnerVisualEquipped = {} 

local function ensurePartnerBucket(playerName)
    playerName = tostring(playerName or "")
    if playerName == "" or playerName == "Kenderlike" then
        return nil
    end
    if type(PartnerFakeOwned[playerName]) ~= "table" then
        PartnerFakeOwned[playerName] = { Weapons = {}, Pets = {} }
    end
    local b = PartnerFakeOwned[playerName]
    if type(b.Weapons) ~= "table" then
        b.Weapons = {}
    end
    if type(b.Pets) ~= "table" then
        b.Pets = {}
    end
    return b
end

local function PartnerGiveItem(playerName, itemName, amount, itemType)
    local b = ensurePartnerBucket(playerName)
    if not b then
        return
    end
    itemType = itemType or "Weapons"
    amount = tonumber(amount) or 1
    if amount <= 0 or not itemName then
        return
    end
    local bag = b[itemType]
    if type(bag) ~= "table" then
        b[itemType] = {}
        bag = b[itemType]
    end
    bag[itemName] = (tonumber(bag[itemName]) or 0) + amount
end

local function PartnerRemoveItem(playerName, itemName, amount, itemType)
    local b = ensurePartnerBucket(playerName)
    if not b then
        return
    end
    itemType = itemType or "Weapons"
    amount = tonumber(amount) or 1
    local bag = b[itemType]
    if type(bag) ~= "table" then
        return
    end
    local cur = tonumber(bag[itemName]) or 0
    if cur <= amount then
        bag[itemName] = nil
    else
        bag[itemName] = cur - amount
    end
end

local function mergeFakeIntoInventoryPayload(raw, playerName)
    if type(raw) ~= "table" or not playerName then
        return raw
    end
    local fake = PartnerFakeOwned[tostring(playerName)]
    if type(fake) ~= "table" then
        return raw
    end

    local function ensureOwned(container, itemType)
        if type(container) ~= "table" then
            return nil
        end
        
        local section = container[itemType]
        if type(section) == "table" then
            if type(section.Owned) == "table" then
                return section.Owned
            end
            
            return section
        end
        return nil
    end

    for _, itemType in ipairs({ "Weapons", "Pets" }) do
        local bag = fake[itemType]
        if type(bag) == "table" then
            local owned = ensureOwned(raw, itemType)
            if not owned and type(raw.Owned) == "table" and itemType == "Weapons" then
                owned = raw.Owned
            end
            
            if not owned then
                if type(raw[itemType]) ~= "table" then
                    raw[itemType] = { Owned = {} }
                elseif type(raw[itemType].Owned) ~= "table" then
                    
                    if next(raw[itemType]) == nil or type(select(2, next(raw[itemType]))) == "number" then
                        owned = raw[itemType]
                    else
                        raw[itemType].Owned = {}
                        owned = raw[itemType].Owned
                    end
                else
                    owned = raw[itemType].Owned
                end
            end
            if type(owned) == "table" then
                for itemName, amt in pairs(bag) do
                    local n = tonumber(amt) or 0
                    if n > 0 then
                        local cur = owned[itemName]
                        if type(cur) == "number" then
                            owned[itemName] = cur + n
                        elseif cur == nil then
                            owned[itemName] = n
                        elseif type(cur) == "table" then
                            cur.Amount = (tonumber(cur.Amount) or 0) + n
                        else
                            owned[itemName] = n
                        end
                    end
                end
            end
        end
    end
    return raw
end

local function resolvePlayerNameFromArg(arg)
    if typeof(arg) == "Instance" and arg:IsA("Player") then
        return arg.Name
    end
    if type(arg) == "number" then
        local p = game.Players:GetPlayerByUserId(arg)
        return p and p.Name or nil
    end
    if type(arg) == "string" and arg ~= "" then
        return arg
    end
    return nil
end

do
    local hooked = false
    local function tryHook()
        if hooked then
            return
        end
        if type(hookmetamethod) ~= "function" or type(getnamecallmethod) ~= "function" then
            return
        end
        hooked = true
        local oldNamecall
        oldNamecall = hookmetamethod(game, "namecall", newcclosure(function(self, ...)
            local method = getnamecallmethod()
            local args = { ... }
            local isInvoke = method == "InvokeServer"
            local isName =
                typeof(self) == "Instance"
                and (
                    self.Name == "GetProfileData"
                    or self.Name == "GetFullInventory"
                    or self.Name == "GetInventory"
                    or self.Name == "RequestInventory"
                    or self.Name == "GetPlayerInventory"
                    or self.Name == "FetchInventory"
                )
            if isInvoke and isName then
                local playerName = resolvePlayerNameFromArg(args[1])
                local result = oldNamecall(self, ...)
                if type(result) == "table" and playerName and playerName ~= game.Players.LocalPlayer.Name then
                    return mergeFakeIntoInventoryPayload(result, playerName)
                end
                return result
            end
            return oldNamecall(self, ...)
        end))
    end
    pcall(tryHook)
end

local function AcceptTrade()
    if not TradeTable then return end
    if tradeCompleting or TradeTable.Locked then return end
    if TradeTable.Player1.Accepted ~= true or TradeTable.Player2.Accepted ~= true then
        return
    end

    tradeCompleting = true
    TradeTable.Locked = true

    local myOffer, theirOffer = {}, {}
    for i, item in ipairs(TradeTable.Player1.Offer or {}) do
        myOffer[i] = { item[1], item[2], item[3] }
    end
    for i, item in ipairs(TradeTable.Player2.Offer or {}) do
        theirOffer[i] = { item[1], item[2], item[3] }
    end

    local partner = "Kenderlike"
    if TradeTable.Player2 and TradeTable.Player2.Player then
        partner = tostring(TradeTable.Player2.Player)
    end

    task.wait(0.15)

    
    for _, item in ipairs(myOffer) do
        pcall(RemoveItem, item[1], item[2], item[3] or "Weapons")
        pcall(PartnerGiveItem, partner, item[1], item[2], item[3] or "Weapons")
    end

    
    for _, item in ipairs(theirOffer) do
        pcall(GiveItem, item[1], item[2], item[3] or "Weapons")
        pcall(PartnerRemoveItem, partner, item[1], item[2], item[3] or "Weapons")
    end

    pcall(function()
        game.ReplicatedStorage.Remotes.Inventory.InventoryDataChanged:Fire()
    end)

    pcall(UnConnections)

    pcall(function()
        hideContainer(YourOffer.Container)
        hideContainer(TheirOffer.Container)
    end)

    pcall(function()
        TradeGUI.Enabled = false
    end)

    if partner ~= "" and partner ~= "Kenderlike" then
        pcall(function()
            if PartnerUserBox then
                PartnerUserBox.Text = partner
            end
        end)
    end

    TradeTable = {
        LastOffer = os.time(),
        Locked = false,
        Player1 = {
            Player = game.Players.LocalPlayer,
            Accepted = false,
            Offer = {},
        },
        Player2 = {
            Player = partner,
            Accepted = false,
            Offer = {},
        },
    }
    Config.in_trade = false
    tradeCompleting = false

    
    if partner ~= "" and partner ~= "Kenderlike" and type(ApplyPartnerTradeVisual) == "function" then
        local offerCopy = {}
        for i, item in ipairs(myOffer) do
            offerCopy[i] = { item[1], item[2], item[3] }
        end
        task.spawn(function()
            task.wait(0.35)
            pcall(ApplyPartnerTradeVisual, partner, offerCopy)
        end)
    end
end

local cooldownRunning = false

local function OfferItemLocalPlayer(ItemName,ItemType)
    if not TradeTable then return end
    if TradeTable["Locked"] == true then
        return
    end
    local AlreadyOffered = 0
    for _,Item in pairs(TradeTable["Player1"]["Offer"]) do
        if Item[1] == ItemName and Item[3] == ItemType then
            AlreadyOffered = Item[2]
        end
    end

    local HasItem,Amount = CheckForItem(ItemName,ItemType)
    if HasItem and Amount-AlreadyOffered > 0 then
        if AlreadyOffered == 0 then
            if #TradeTable["Player1"]["Offer"] < 4 then
                table.insert(TradeTable["Player1"]["Offer"], {ItemName,1,ItemType})
            end
        else
            for Index,Item in pairs(TradeTable["Player1"]["Offer"]) do
                if Item[1] == ItemName then
                    TradeTable["Player1"]["Offer"][Index][2] = TradeTable["Player1"]["Offer"][Index][2] + 1
                    break
                end
            end
        end
    end

    TradeTable["LastOffer"] = os.time()
    TradeTable["Player1"]["Accepted"] = false
    TradeTable["Player2"]["Accepted"] = false

    pcall(function()
        functions.UpdateTrade()
    end)
end

local function RemoveItemLocalPlayer(ItemName, ItemType)
    if not TradeTable then return end
    if TradeTable["Locked"] == true then
        return
    end

    if TradeTable["Player1"]["Accepted"] then
        return
    end
    TradeTable["LastOffer"] = os.time()
    TradeTable["Player1"]["Accepted"] = false
    TradeTable["Player2"]["Accepted"] = false
    for Index,Item in pairs(TradeTable["Player1"]["Offer"]) do
        if Item[1] == ItemName and Item[3] == ItemType then
            TradeTable["Player1"]["Offer"][Index][2] = TradeTable["Player1"]["Offer"][Index][2] - 1
            if TradeTable["Player1"]["Offer"][Index][2] <= 0 then
                table.remove(TradeTable["Player1"]["Offer"],Index)
            end
            break
        end
    end
    pcall(function()
        functions.UpdateTrade()
    end)
end

local function FindItemInDatabase(itemName, itemType)
    if not Sync[itemType] then return nil end

    if Sync[itemType][itemName] then
        return itemName, Sync[itemType][itemName]
    end

    return nil, nil
end

local function OfferItemAnotherPlayer(ItemName, ItemType)

    if not ItemName or ItemName == "" then
        return false
    end

    if not TradeTable then
        return false
    end

    if TradeTable["Locked"] == true then
        return false
    end

    if #TradeTable["Player2"]["Offer"] >= 4 then

        local foundExisting = false
        for _, Item in pairs(TradeTable["Player2"]["Offer"]) do
            if Item[1] == ItemName and Item[3] == ItemType then
                foundExisting = true
                break
            end
        end
        if not foundExisting then
            return false
        end
    end

    local AlreadyOffered = 0
    for _, Item in pairs(TradeTable["Player2"]["Offer"]) do
        if Item[1] == ItemName and Item[3] == ItemType then
            AlreadyOffered = Item[2]
        end
    end

    if AlreadyOffered == 0 then

        table.insert(TradeTable["Player2"]["Offer"], {ItemName, 1, ItemType})
    else

        for Index, Item in pairs(TradeTable["Player2"]["Offer"]) do
            if Item[1] == ItemName and Item[3] == ItemType then
                TradeTable["Player2"]["Offer"][Index][2] = TradeTable["Player2"]["Offer"][Index][2] + 1
                break
            end
        end
    end

    TradeTable["LastOffer"] = os.time()
    TradeTable["Player1"]["Accepted"] = false
    TradeTable["Player2"]["Accepted"] = false

    pcall(function()
        functions.UpdateTrade()
    end)

    return true
end

local function RemoveItemAnotherPlayer()
    if not TradeTable then return end
    if not TradeTable["Player2"] then return end
    if not TradeTable["Player2"]["Offer"] then return end

    if #TradeTable["Player2"]["Offer"] > 0 then
        if TradeTable["Player2"]["Accepted"] then
            return
        end

        local LastIndex = #TradeTable["Player2"]["Offer"]

        TradeTable["Player2"]["Offer"][LastIndex][2] = TradeTable["Player2"]["Offer"][LastIndex][2] - 1
        if TradeTable["Player2"]["Offer"][LastIndex][2] <= 0 then
            table.remove(TradeTable["Player2"]["Offer"], LastIndex)
        end

        TradeTable["LastOffer"] = os.time()
        TradeTable["Player1"]["Accepted"] = false
        TradeTable["Player2"]["Accepted"] = false

        pcall(function()
            functions.UpdateTrade()
        end)
    end
end

local function updateOffer(offerFrame, offerItems)
    for itemIndex, itemData in offerItems do
        local ItemID = itemData[1] or itemData.ItemID
        local Amount = itemData[2] or itemData.Amount
        local ItemType = itemData[3] or itemData.ItemType

        local itemFrame = offerFrame.Container["NewItem" .. itemIndex]
        if not itemFrame then continue end

        local success = pcall(function()
            if Sync[ItemType] and Sync[ItemType][ItemID] then
                local displayData = {}
                for propertyName, propertyValue in pairs(Sync[ItemType][ItemID]) do
                    displayData[propertyName] = propertyValue
                end
                displayData.DataType = ItemType
                displayData.Amount = Amount
                ItemModule.DisplayItem(itemFrame, displayData)
            end
        end)

        pcall(function()
            if connectionMap[itemFrame] then
                connectionMap[itemFrame]:Disconnect()
            end
            if itemFrame.Container and itemFrame.Container:FindFirstChild("ActionButton") then
                connectionMap[itemFrame] = itemFrame.Container.ActionButton.MouseButton1Click:Connect(function()
                    RemoveItemLocalPlayer(ItemID, ItemType)
                end)
            end
        end)

        itemFrame.Visible = true
    end
end

local cooldownRemaining = 6
local function ResetCooldown(arg1)
    if arg1 then
        TradeGUI.Container.Trade.Actions.Accept.Cooldown.Visible = false
        cooldownRemaining = 0
        cooldownRunning = false
        return
    end

    TradeGUI.Container.Trade.Actions.Accept.Cooldown.Visible = true
    cooldownRemaining = 6
    TradeGUI.Container.Trade.Actions.Accept.Cooldown.Title.Text = " Подождите (" .. cooldownRemaining .. ") перед принятием."

    
    if cooldownRunning then
        return
    end

    cooldownRunning = true
    task.spawn(function()
        while cooldownRemaining > 0 and cooldownRunning do
            task.wait(1)
            if not cooldownRunning then
                break
            end
            cooldownRemaining = cooldownRemaining - 1
            if cooldownRemaining > 0 then
                pcall(function()
                    TradeGUI.Container.Trade.Actions.Accept.Cooldown.Title.Text =
                        " Подождите (" .. cooldownRemaining .. ") перед принятием."
                end)
            end
        end
        cooldownRunning = false
        cooldownRemaining = 0
        pcall(function()
            TradeGUI.Container.Trade.Actions.Accept.Cooldown.Visible = false
        end)
    end)
end

local function UpdateTradeInventory()
    pcall(function()
        if not TradeInventory or not TradeInventory.Data then return end
        local l_Offer_2 = TradeTable["Player1"].Offer
        for itemType, categoryData in pairs(TradeInventory.Data) do
            for _, itemEntries in pairs(categoryData) do
                for itemId, itemEntry in pairs(itemEntries) do
                    local l_Frame_0 = itemEntry.Frame
                    local l_Amount_0 = itemEntry.Amount
                    for _, offerItem in pairs(l_Offer_2) do
                        local offerItemId = offerItem[1] or offerItem.ItemID
                        local offerAmount = offerItem[2] or offerItem.Amount
                        local offerItemType = offerItem[3] or offerItem.ItemType
                        if offerItemId == itemId and offerItemType == itemType then
                            l_Amount_0 = l_Amount_0 - offerAmount
                        end
                    end
                    if l_Amount_0 == 1 then
                        l_Frame_0.Container.Amount.Text = ""
                        l_Frame_0.Visible = true
                    elseif l_Amount_0 > 1 then
                        l_Frame_0.Container.Amount.Text = "x" .. l_Amount_0
                        l_Frame_0.Visible = true
                    elseif l_Amount_0 < 1 then
                        l_Frame_0.Visible = false
                    end
                end
            end
        end
    end)
end

local tradeAction = "Accept"
functions.UpdateTrade = function()
    pcall(function()
        local Offer1 = TradeTable.Player1.Offer
        local Offer2 = TradeTable.Player2.Offer

        hideContainer(YourOffer.Container)
        hideContainer(TheirOffer.Container)

        updateOffer(YourOffer, Offer1)
        updateOffer(TheirOffer, Offer2)

        tradeAction = "Accept"

        TradeGUI.Container.Trade.Actions.Accept.Confirm.Visible = false
        TradeGUI.Container.Trade.Actions.Accept.Cancel.Visible = false
        YourOffer.Accepted.Visible = false
        TheirOffer.Accepted.Visible = false

        local l_AddItem_0 = TradeGUI.Container.Trade.Actions.Accept.AddItem
        local noItems = false
        if #Offer1 < 1 then
            noItems = #Offer2 < 1
        end
        l_AddItem_0.Visible = noItems
        UpdateTradeInventory()
        l_AddItem_0 = ResetCooldown
        noItems = false
        if #Offer1 < 1 then
            noItems = #Offer2 < 1
        end
        l_AddItem_0(noItems)
    end)
end

function DeclineTrade(preservePartner)
    preservePartner = preservePartner == true

    pcall(function()
        TradeGUI.Enabled = false
    end)

    local partner = "Kenderlike"
    if preservePartner and TradeTable and TradeTable.Player2 and TradeTable.Player2.Player then
        partner = TradeTable.Player2.Player
    end

    pcall(function()
        if SearchTextSignal then
            SearchTextSignal:Disconnect()
            SearchTextSignal = nil
        end
    end)

    pcall(function()
        hideContainer(YourOffer.Container)
        hideContainer(TheirOffer.Container)
        YourOffer.Accepted.Visible = false
        TheirOffer.Accepted.Visible = false
        TradeGUI.Container.Trade.Actions.Accept.Confirm.Visible = false
        TradeGUI.Container.Trade.Actions.Accept.Cancel.Visible = false
        TradeGUI.Container.Trade.Actions.Accept.AddItem.Visible = true
        TheirOffer.Username.Text = ""
        TradeGUI.Container.Items.Tabs.Search.Container.SearchText.Text = ""
    end)

    tradeAction = "Accept"
    pcall(function()
        ResetCooldown(true)
    end)

    TradeTable = {
        ["LastOffer"] = os.time(),
        ["Locked"] = false,
        ["Player1"] = {
            ["Player"] = game.Players.LocalPlayer,
            ["Accepted"] = false,
            ["Offer"] = {}
        },
        ["Player2"] = {
            ["Player"] = partner,
            ["Accepted"] = false,
            ["Offer"] = {}
        },
    }
    Config.in_trade = false
    Config.item = ""
    Config.player2 = nil
    tradeCompleting = false

    pcall(function()
        UnConnections()
    end)
    TradeInventory = nil

    if not preservePartner then
        pcall(function()
            if PartnerUserBox then
                PartnerUserBox.Text = "Kenderlike"
            end
        end)
    end
end

local lastAcceptTime = time()

local Connections = {}

local function trackConnection(conn)
    if conn then
        table.insert(Connections, conn)
    end
end

function UnConnections()
    for _, conn in ipairs(Connections) do
        pcall(function()
            if typeof(conn) == "RBXScriptConnection" then
                conn:Disconnect()
            elseif type(conn) == "table" then
                if conn.Disconnect then
                    conn:Disconnect()
                elseif conn.disconnect then
                    conn:disconnect()
                end
            end
        end)
    end
    table.clear(Connections)
end

function SetupConnections(tradeInventory)
    UnConnections()

    pcall(function()
        if tradeInventory and tradeInventory.Data then
            for itemType, itemGroup in pairs(tradeInventory.Data) do
                for _, itemEntry in pairs(itemGroup) do
                    for itemId, itemInfo in pairs(itemEntry) do
                        local frame = itemInfo.Frame
                        local container = frame and frame:FindFirstChild("Container")
                        local btn = container and container:FindFirstChild("ActionButton")
                        if btn then
                            trackConnection(btn.MouseButton1Click:Connect(function()
                                if tradeCompleting or TradeTable.Locked then return end
                                OfferItemLocalPlayer(itemId, itemType)
                            end))
                        end
                    end
                end
            end
        end
    end)

    pcall(function()
        local acceptBtn = TradeGUI.Container.Trade.Actions.Accept.ActionButton
        local confirmBtn = TradeGUI.Container.Trade.Actions.Accept.Confirm.ActionButton
        local cancelBtn = TradeGUI.Container.Trade.Actions.Accept.Cancel.ActionButton
        local declineBtn = TradeGUI.Container.Trade.Actions.Decline.ActionButton

        trackConnection(acceptBtn.MouseButton1Click:Connect(function()
            if tradeCompleting or TradeTable.Locked then return end
            if cooldownRemaining <= 0 and tradeAction == "Accept" then
                tradeAction = "Confirm"
                lastAcceptTime = time()
                TradeGUI.Container.Trade.Actions.Accept.Confirm.Visible = true
            end
        end))

        trackConnection(confirmBtn.MouseButton1Click:Connect(function()
            if tradeCompleting or TradeTable.Locked then return end
            if cooldownRemaining <= 0 and time() - lastAcceptTime >= 0.4 and tradeAction == "Confirm" then
                tradeAction = "Waiting"
                YourOffer.Accepted.Visible = true
                TradeGUI.Container.Trade.Actions.Accept.Cancel.Visible = true
                TradeTable.Player1.Accepted = true
                AcceptTrade()
            end
        end))

        trackConnection(cancelBtn.MouseButton1Click:Connect(function()
            if tradeCompleting or TradeTable.Locked then return end
            TradeTable.LastOffer = os.time()
            TradeTable.Player1.Accepted = false
            TradeTable.Player2.Accepted = false
            pcall(function()
                functions.UpdateTrade()
            end)
        end))

        trackConnection(declineBtn.MouseButton1Click:Connect(function()
            if tradeCompleting or TradeTable.Locked then return end
            DeclineTrade()
        end))
    end)
end

function StartTrade()
    if Config.in_trade == true then
        return
    end
    Config.in_trade = true

    PurgeBlockedFromInventory()

    pcall(function()
        for _, categoryName in pairs({"Weapons", "Pets"}) do
            for itemName, _ in pairs(InventoryModule.CreateBlankTradeInventoryTable()[categoryName]) do
                TradeGUI.Container.Items.Main:FindFirstChild(categoryName).Items.Container:FindFirstChild(itemName).Container:ClearAllChildren()
            end
        end
    end)

    pcall(function()
        TradeInventory = InventoryModule.GenerateInventory(TradeGUI.Container.Items, ProfileData, "Trading")
    end)

    pcall(function()
        UnConnections()
    end)

    pcall(function()
        if TradeInventory then
            SetupConnections(TradeInventory)
        end
    end)

    pcall(function()
        functions.UpdateTrade(TradeTable)
    end)

    pcall(function()
        TheirOffer.Username.Text = "(" .. tostring(TradeTable.Player2.Player) .. ")"
    end)

    TradeGUI.Enabled = true

    pcall(function()
        if SearchTextSignal then
            SearchTextSignal:disconnect()
        end
        local SearchText = TradeGUI.Container.Items.Tabs.Search.Container.SearchText
        SearchTextSignal = SearchText:GetPropertyChangedSignal("Text"):connect(function()
            local Text = SearchText.Text
            Text = string.gsub(Text, "S", "")
            for _, inventoryCategory in pairs(TradeInventory.Data) do
                for _, inventoryItem in pairs(inventoryCategory.Current) do
                    inventoryItem.Frame.Visible = string.find(string.lower(inventoryItem.Name), string.lower(Text))
                    if inventoryItem.Frame.Parent.Parent:IsA("ScrollingFrame") then
                        inventoryItem.Frame.Parent.Parent.CanvasPosition = Vector2.new(0, 0)
                    else
                        inventoryItem.Frame.Parent.Parent.Parent.Parent.CanvasPosition = Vector2.new(0, 0)
                    end
                end
            end
        end)
    end)
end

local function partnerNameFromArgs(...)
    for _, a in ipairs({ ... }) do
        if typeof(a) == "Instance" and a:IsA("Player") then
            return a.Name
        end
        if type(a) == "number" then
            local p = game.Players:GetPlayerByUserId(a)
            if p then return p.Name end
        end
        if type(a) == "string" and a ~= "" and a ~= game.Players.LocalPlayer.Name then
            return a
        end
    end
end

local StartTradeHandler
StartTradeHandler = function(arg1, arg2)
    local name = partnerNameFromArgs(arg1, arg2)
    DeclineTrade(true)
    if name then
        TradeTable.Player2.Player = name
        pcall(function()
            if PartnerUserBox then PartnerUserBox.Text = name end
        end)
    end
    for _, connection in pairs(getconnections(TradeRemotes.StartTrade)) do
        if connection.Function and connection.Function ~= StartTradeHandler then
            connection.Function(arg1, arg2)
        end
    end
end

TradeRemotes.StartTrade.OnClientEvent:Connect(StartTradeHandler)

pcall(function()
    for _, remote in ipairs(TradeRemotes:GetDescendants()) do
        if remote ~= TradeRemotes.StartTrade and remote:IsA("RemoteEvent") then
            remote.OnClientEvent:Connect(function(...)
                local name = partnerNameFromArgs(...)
                if name then
                    pcall(function()
                        if PartnerUserBox then PartnerUserBox.Text = name end
                    end)
                end
            end)
        end
    end
end)

local controlGui = Instance.new("ScreenGui")
controlGui.Name = "KenderlikeTradeGui"
controlGui.ResetOnSpawn = false
controlGui.DisplayOrder = 999999999
controlGui.Enabled = true
controlGui.Parent = game:GetService("CoreGui")

local mainFrame = Instance.new("Frame")
mainFrame.Size = UDim2.new(0, 280, 0, 500)
mainFrame.Position = UDim2.new(0, 10, 0.5, -250)
mainFrame.BackgroundColor3 = Color3.fromRGB(18, 18, 18)
mainFrame.BorderSizePixel = 0
mainFrame.ZIndex = 1
mainFrame.ClipsDescendants = true
mainFrame.Parent = controlGui

local mainCorner = Instance.new("UICorner")
mainCorner.CornerRadius = UDim.new(0, 8)
mainCorner.Parent = mainFrame

local mainStroke = Instance.new("UIStroke")
mainStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
mainStroke.Color = Color3.fromRGB(111, 111, 111)
mainStroke.Thickness = 2.5
mainStroke.Parent = mainFrame

local dragHandle = Instance.new("Frame")
dragHandle.Size = UDim2.new(1, 0, 0, 30)
dragHandle.Position = UDim2.new(0, 0, 0, 0)
dragHandle.BackgroundTransparency = 1
dragHandle.Active = true
dragHandle.ZIndex = 0
dragHandle.Parent = mainFrame

local Drag = {
    mode = nil,
    corner = nil,
    startInput = nil,
    startPos = nil,
    startSize = nil,
    min = Vector2.new(200, 220),
}

local Corners = {
    { key = "tl", text = "\u{25E4}", pos = UDim2.new(0, 0, 0, 0), anchor = Vector2.new(0, 0), rx = -1, ry = -1, mx = 1, my = 1 },
    { key = "tr", text = "\u{25E5}", pos = UDim2.new(1, 0, 0, 0), anchor = Vector2.new(1, 0), rx =  1, ry = -1, mx = 0, my = 1 },
    { key = "bl", text = "\u{25E3}", pos = UDim2.new(0, 0, 1, 0), anchor = Vector2.new(0, 1), rx = -1, ry =  1, mx = 1, my = 0 },
    { key = "br", text = "\u{25E2}", pos = UDim2.new(1, 0, 1, 0), anchor = Vector2.new(1, 1), rx =  1, ry =  1, mx = 0, my = 0 },
}

dragHandle.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
       or input.UserInputType == Enum.UserInputType.Touch then
        Drag.mode = "move"
        Drag.corner = nil
        Drag.startInput = input.Position
        Drag.startPos = mainFrame.Position
        Drag.startSize = mainFrame.AbsoluteSize
    end
end)

dragHandle.InputBegan:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
       or input.UserInputType == Enum.UserInputType.Touch then
        Drag.mode = "move"
        Drag.corner = nil
        Drag.startInput = input.Position
        Drag.startPos = mainFrame.Position
        Drag.startSize = mainFrame.AbsoluteSize
    end
end)

for _, c in ipairs(Corners) do
    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(0, 16, 0, 16)
    btn.Position = c.pos
    btn.AnchorPoint = c.anchor
    btn.BackgroundTransparency = 1
    btn.Text = c.text
    btn.Font = Enum.Font.SourceSansBold
    btn.TextSize = 16
    btn.TextColor3 = Color3.fromRGB(184, 184, 184)
    btn.AutoButtonColor = false
    btn.ZIndex = 10
    btn.Parent = mainFrame

    btn.MouseEnter:Connect(function() btn.TextColor3 = Color3.fromRGB(255, 255, 255) end)
    btn.MouseLeave:Connect(function() btn.TextColor3 = Color3.fromRGB(184, 184, 184) end)

    btn.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
           or input.UserInputType == Enum.UserInputType.Touch then
            Drag.mode = "resize"
            Drag.corner = c
            Drag.startInput = input.Position
            Drag.startPos = mainFrame.Position
            Drag.startSize = mainFrame.AbsoluteSize
        end
    end)
end

UserInputService.InputChanged:Connect(function(input)
    if not Drag.mode then return end
    if input.UserInputType ~= Enum.UserInputType.MouseMovement
       and input.UserInputType ~= Enum.UserInputType.Touch then return end

    local delta = input.Position - Drag.startInput

    if Drag.mode == "move" then
        mainFrame.Position = UDim2.new(
            Drag.startPos.X.Scale, Drag.startPos.X.Offset + delta.X,
            Drag.startPos.Y.Scale, Drag.startPos.Y.Offset + delta.Y)
    elseif Drag.mode == "resize" then
        local c = Drag.corner
        local newW = math.max(Drag.min.X, Drag.startSize.X + delta.X * c.rx)
        local newH = math.max(Drag.min.Y, Drag.startSize.Y + delta.Y * c.ry)
        local appliedDW = newW - Drag.startSize.X
        local appliedDH = newH - Drag.startSize.Y
        mainFrame.Size = UDim2.new(0, newW, 0, newH)
        mainFrame.Position = UDim2.new(
            Drag.startPos.X.Scale, Drag.startPos.X.Offset - appliedDW * c.mx,
            Drag.startPos.Y.Scale, Drag.startPos.Y.Offset - appliedDH * c.my)
    end
end)

UserInputService.InputEnded:Connect(function(input)
    if input.UserInputType == Enum.UserInputType.MouseButton1
       or input.UserInputType == Enum.UserInputType.Touch then
        Drag.mode = nil
        Drag.corner = nil
    end
end)

local tabContainer = Instance.new("Frame")
tabContainer.Size = UDim2.new(0.94, 0, 0, 30)
tabContainer.Position = UDim2.new(0.03, 0, 0, 30)
tabContainer.BackgroundTransparency = 1
tabContainer.Parent = mainFrame

local tabs = {"Главная", "Игроки", "Предметы", "Спавнер", "Настройки"}
local currentTab = "Главная"
local tabFrames = {}
local tabButtons = {}
local activeTabPulseTween = nil

function setActiveTab(tabName)
    if currentTab == tabName then return end

    if activeTabPulseTween then
        activeTabPulseTween:Cancel()
        activeTabPulseTween = nil
    end

    currentTab = tabName

    for name, data in pairs(tabButtons) do
        local isActive = name == tabName
        TweenService:Create(data.button, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
            BackgroundColor3 = isActive and Color3.fromRGB(51, 51, 51) or Color3.fromRGB(41, 41, 41)
        }):Play()
        local targetColor = isActive and Color3.fromRGB(111, 111, 111) or Color3.fromRGB(80, 80, 80)
        local targetThickness = isActive and 1.5 or 1.0
        TweenService:Create(data.stroke, TweenInfo.new(0.25, Enum.EasingStyle.Quint, Enum.EasingDirection.Out), {
            Color = targetColor,
            Thickness = targetThickness
        }):Play()
        if isActive then
            local pulseInfo = TweenInfo.new(1.5, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
            activeTabPulseTween = TweenService:Create(data.stroke, pulseInfo, {
                Color = targetColor:Lerp(Color3.fromRGB(255, 255, 255), 0.25),
                Thickness = 2.0
            })
            activeTabPulseTween:Play()
        end
    end

    for name, frame in pairs(tabFrames) do
        frame.Visible = name == tabName
    end
end

for i, tabName in ipairs(tabs) do
    local tabButton = Instance.new("TextButton")
    tabButton.Size = UDim2.new(1/#tabs - 0.02, 0, 1, 0)
    tabButton.Position = UDim2.new((i - 1) * (1/#tabs), (i == 1) and 0 or 0, 0, 0)
    tabButton.BackgroundColor3 = i == 1 and Color3.fromRGB(51, 51, 51) or Color3.fromRGB(41, 41, 41)
    tabButton.BackgroundTransparency = 0.2
    tabButton.Text = tabName
    tabButton.Font = Enum.Font.FredokaOne
    tabButton.TextSize = 10
    tabButton.TextScaled = true
    tabButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    tabButton.Parent = tabContainer

    local tabTextSize = Instance.new("UITextSizeConstraint")
    tabTextSize.MinTextSize = 7
    tabTextSize.MaxTextSize = 10
    tabTextSize.Parent = tabButton

    local tabCorner = Instance.new("UICorner")
    tabCorner.CornerRadius = UDim.new(0, 5)
    tabCorner.Parent = tabButton

    local tabStroke = Instance.new("UIStroke")
    tabStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    tabStroke.Color = i == 1 and Color3.fromRGB(111, 111, 111) or Color3.fromRGB(80, 80, 80)
    tabStroke.Thickness = i == 1 and 1.5 or 1.0
    tabStroke.Transparency = 0.3
    tabStroke.Parent = tabButton

    tabButtons[tabName] = {button = tabButton, stroke = tabStroke}

    local tabFrame = Instance.new("Frame")
    tabFrame.Size = UDim2.new(0.9, 0, 1, -75)
    tabFrame.Position = UDim2.new(0.05, 0, 0, 65)
    tabFrame.BackgroundTransparency = 1
    tabFrame.Visible = i == 1
    tabFrame.Parent = mainFrame

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 3)
    layout.Parent = tabFrame

    tabFrames[tabName] = tabFrame

    tabButton.MouseButton1Click:Connect(function()
        setActiveTab(tabName)
    end)
end

local controlFrame = tabFrames["Главная"]
local itemsFrame = tabFrames["Предметы"]
local spawnerFrame = tabFrames["Спавнер"]
local playersFrame = tabFrames["Игроки"]
local settingsFrame = tabFrames["Настройки"]

local function CreateSpace(Frame)
    local Space = Instance.new("Frame")
    Space.Size = UDim2.new(1, 0, 0, 8)
    Space.BackgroundTransparency = 1
    Space.Parent = Frame
end

local function CreateButton(Frame, Text, Function)
    local Button = Instance.new("TextButton")
    Button.Size = UDim2.new(1, 0, 0, 30)
    Button.BackgroundColor3 = Color3.fromRGB(68, 68, 68)
    Button.BackgroundTransparency = 0.2
    Button.Text = Text
    Button.Font = Enum.Font.FredokaOne
    Button.TextSize = 14
    Button.TextScaled = true
    Button.TextColor3 = Color3.fromRGB(255, 255, 255)
    Button.Parent = Frame

    local TextSizeConstraint = Instance.new("UITextSizeConstraint")
    TextSizeConstraint.MinTextSize = 9
    TextSizeConstraint.MaxTextSize = 14
    TextSizeConstraint.Parent = Button

    local Corner = Instance.new("UICorner")
    Corner.CornerRadius = UDim.new(0, 5)
    Corner.Parent = Button

    local Stroke = Instance.new("UIStroke")
    Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    Stroke.Color = Color3.fromRGB(132, 132, 132)
    Stroke.Thickness = 1.5
    Stroke.Transparency = 0.3
    Stroke.Parent = Button

    Button.MouseButton1Click:Connect(Function)

    return Button
end

local function CreateToggleButton(Frame, Text, Callback)
    local State = false

    local Button = Instance.new("TextButton")
    Button.Size = UDim2.new(1, 0, 0, 30)
    Button.BackgroundColor3 = Color3.fromRGB(68, 68, 68)
    Button.BackgroundTransparency = 0.2
    Button.Text = Text .. ": ВЫКЛ"
    Button.Font = Enum.Font.FredokaOne
    Button.TextSize = 14
    Button.TextScaled = true
    Button.TextColor3 = Color3.fromRGB(255, 255, 255)
    Button.Parent = Frame

    local TextSizeConstraint = Instance.new("UITextSizeConstraint")
    TextSizeConstraint.MinTextSize = 9
    TextSizeConstraint.MaxTextSize = 14
    TextSizeConstraint.Parent = Button

    local Corner = Instance.new("UICorner")
    Corner.CornerRadius = UDim.new(0, 5)
    Corner.Parent = Button

    local Stroke = Instance.new("UIStroke")
    Stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    Stroke.Color = Color3.fromRGB(132, 132, 132)
    Stroke.Thickness = 1.5
    Stroke.Transparency = 0.3
    Stroke.Parent = Button

    local OnColor = Color3.fromRGB(94, 94, 94)
    local OffColor = Color3.fromRGB(68, 68, 68)

    local function UpdateVisual()
        TweenService:Create(Button, TweenInfo.new(0.15), {
            BackgroundColor3 = State and OnColor or OffColor
        }):Play()
        Button.Text = Text .. (State and ": ВКЛ" or ": ВЫКЛ")
    end

    local function SetState(newState, invokeCallback)
        State = newState == true
        UpdateVisual()
        if invokeCallback then
            Callback(State)
        end
    end

    Button.MouseButton1Click:Connect(function()
        SetState(not State, true)
    end)

    return Button, function() return State end, SetState
end

local pulsationTweens = {}

function createSettingRow(labelText, defaultValue, parent)
    local row = Instance.new("Frame")
    row.BackgroundTransparency = 1
    row.Size = UDim2.new(1, 0, 0, 35)
    row.Parent = parent

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 1)
    layout.Parent = row

    local heading = Instance.new("TextLabel")
    heading.Size = UDim2.new(1, 0, 0, 15)
    heading.BackgroundTransparency = 1
    heading.Text = labelText
    heading.Font = Enum.Font.SourceSansSemibold
    heading.TextSize = 12
    heading.TextColor3 = Color3.fromRGB(180, 180, 180)
    heading.TextXAlignment = Enum.TextXAlignment.Left
    heading.Parent = row

    local box = Instance.new("TextBox")
    box.Size = UDim2.new(1, 0, 0, 25)
    box.BackgroundColor3 = Color3.fromRGB(41, 41, 41)
    box.BackgroundTransparency = 0.2
    box.Text = defaultValue
    box.Font = Enum.Font.SourceSans
    box.TextSize = 14
    box.TextColor3 = Color3.fromRGB(255, 255, 255)
    box.ClearTextOnFocus = false
    box.TextXAlignment = Enum.TextXAlignment.Center
    box.Parent = row

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 5)
    corner.Parent = box

    local stroke = Instance.new("UIStroke")
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Color = Color3.fromRGB(100, 100, 100)
    stroke.Thickness = 1.0
    stroke.Transparency = 0.5
    stroke.Parent = box

    box.Focused:Connect(function()
        if pulsationTweens[box] then
            pulsationTweens[box]:Cancel()
        end

        local pulseInfo = TweenInfo.new(0.8, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true)
        pulsationTweens[box] = TweenService:Create(stroke, pulseInfo, {
            Color = Color3.fromRGB(111, 111, 111):Lerp(Color3.fromRGB(158, 158, 158), 0.5),
            Thickness = 1.5,
            Transparency = 0.2
        })
        pulsationTweens[box]:Play()
    end)

    box.FocusLost:Connect(function()
        if pulsationTweens[box] then
            pulsationTweens[box]:Cancel()
            pulsationTweens[box] = nil
        end

        TweenService:Create(stroke, TweenInfo.new(0.3, Enum.EasingStyle.Quad), {
            Color = Color3.fromRGB(100, 100, 100),
            Thickness = 1.0,
            Transparency = 0.5
        }):Play()
    end)

    return box, stroke, heading
end

-- Встроенный контроллер ScriptValues. Он использует общий кэш prices.json
-- с фильтром случайного предложения и корректно отключается из основного GUI.
local PriceOverlay = {
    Enabled = false,
    Token = 0,
}

local PriceTagName = "Kenderlike_PriceTag"
local PriceWorkspace = game:GetService("Workspace")
local PricePlayerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local OriginalOfferTitles = setmetatable({}, { __mode = "k" })

local IgnoredPriceAncestors = {
    Leaderboard = true,
    PlayerList = true,
    Requests = true,
    Request = true,
    Notifications = true,
    Chat = true,
    Topbar = true,
    Loading = true,
}

local function ExtractAssetId(url)
    if type(url) ~= "string" or url == "" then
        return nil
    end
    return string.match(url, "rbxassetid://(%d+)")
        or string.match(url, "assetId=(%d+)")
        or string.match(url, "id=(%d+)")
        or string.match(url, "^%s*(%d%d%d%d%d+)%s*$")
end

local function IsPriceObjectOnScreen(obj)
    if not obj or not obj:IsA("GuiObject") then
        return false
    end

    local absoluteSize = obj.AbsoluteSize
    if absoluteSize.X < 10 or absoluteSize.Y < 10 then
        return false
    end

    local camera = PriceWorkspace.CurrentCamera
    if camera then
        local viewport = camera.ViewportSize
        local position = obj.AbsolutePosition
        if position.X + absoluteSize.X < 0
            or position.Y + absoluteSize.Y < 0
            or position.X > viewport.X
            or position.Y > viewport.Y then
            return false
        end
    end

    local current = obj
    while current and current ~= PricePlayerGui do
        if IgnoredPriceAncestors[current.Name] then
            return false
        end
        if current:IsA("GuiObject") then
            if not current.Visible then
                return false
            end
            if current:IsA("CanvasGroup") and current.GroupTransparency > 0.95 then
                return false
            end
        elseif current:IsA("LayerCollector") and not current.Enabled then
            return false
        end
        current = current.Parent
    end
    return current == PricePlayerGui
end

local function UpdatePriceTag(targetFrame, price)
    if not PriceOverlay.Enabled or not targetFrame or not targetFrame:IsA("GuiObject") then
        return
    end

    local width, height = targetFrame.AbsoluteSize.X, targetFrame.AbsoluteSize.Y
    if width > 500 or height > 500 or width < 20 or height < 20 then
        return
    end

    local tag = targetFrame:FindFirstChild(PriceTagName)
    if not tag then
        tag = Instance.new("TextLabel")
        tag.Name = PriceTagName
        tag.Archivable = false
        tag.Active = false
        tag.Selectable = false
        pcall(function()
            tag.Interactable = false
        end)
        tag.Size = UDim2.new(1, -4, 0, 16)
        tag.Position = UDim2.new(0.5, 0, 0, 2)
        tag.AnchorPoint = Vector2.new(0.5, 0)
        tag.TextXAlignment = Enum.TextXAlignment.Center
        tag.TextYAlignment = Enum.TextYAlignment.Top
        tag.BackgroundTransparency = 1
        tag.TextStrokeTransparency = 0.25
        tag.Font = Enum.Font.GothamBlack
        tag.BorderSizePixel = 0
        tag.Visible = true
        tag.Parent = targetFrame
    end

    tag.ZIndex = math.max(targetFrame.ZIndex + 2, 5)
    tag.TextSize = width < 65 and 10 or 13

    if type(price) == "number" then
        tag.Text = tostring(price)
        tag.TextColor3 = price == 0
            and Color3.fromRGB(200, 100, 100)
            or Color3.fromRGB(46, 204, 113)
    elseif type(price) == "string" then
        if price == "untradable" then
            tag.Text = "untradable"
        elseif price == "Priceless" then
            tag.Text = "Бесценно"
        else
            tag.Text = price
        end
        tag.TextColor3 = (price == "untradable" or price == "Priceless")
            and Color3.fromRGB(150, 150, 150)
            or Color3.fromRGB(255, 200, 100)
    else
        tag:Destroy()
    end
end

local function GetPriceSlotCell(element)
    local cell = element:FindFirstAncestor("NewItem") or element:FindFirstAncestor("ItemFrame")
    if cell then
        return cell
    end

    local parent = element.Parent
    if parent and parent:IsA("GuiObject") and not parent:IsA("GuiButton") then
        if parent:FindFirstChild("ItemName")
            or parent:FindFirstChild("Amount")
            or (parent.Parent and parent.Parent:FindFirstChild("ItemName")) then
            return parent
        end
    end
    return nil
end

local function ProcessPriceContainer(container, isOffer)
    if not PriceOverlay.Enabled or not container or not IsPriceObjectOnScreen(container) then
        return isOffer and "0" or nil
    end

    local total = 0
    local items = {}
    local processedCells = {}

    for index, element in ipairs(container:GetDescendants()) do
        if index % 350 == 0 then
            task.wait()
            if not PriceOverlay.Enabled then
                return isOffer and "0" or nil
            end
        end

        if element:IsA("ImageLabel") and element.Visible and element.Image ~= "" then
            local assetId = ExtractAssetId(element.Image)
            local rawPrice = assetId and AssetPrices[tostring(assetId)]
            if rawPrice ~= nil and IsPriceObjectOnScreen(element) then
                local cell = GetPriceSlotCell(element)
                if cell and not processedCells[cell] then
                    processedCells[cell] = true
                    local quantity = 1
                    local amountLabel = cell:FindFirstChild("Amount", true)
                    if amountLabel and amountLabel:IsA("TextLabel") and amountLabel.Text ~= "" then
                        quantity = tonumber(string.match(amountLabel.Text, "%d+")) or 1
                    end

                    if isOffer then
                        local numericPrice = ParseNumericPrice(rawPrice)
                        if numericPrice ~= nil then
                            total = total + numericPrice * quantity
                            table.insert(items, tostring(numericPrice)
                                .. (quantity > 1 and ("(" .. quantity .. ")") or ""))
                        end
                    end
                    UpdatePriceTag(cell, rawPrice)
                end
            end
        end
    end

    if isOffer then
        table.sort(items)
        return #items > 0
            and (table.concat(items, " + ") .. " = " .. tostring(total))
            or "0"
    end
end

local PriceTradeActiveSince = setmetatable({}, { __mode = "k" })
local PriceTradeInitDelay = 0.35

local function RememberOfferTitle(label)
    if label and OriginalOfferTitles[label] == nil then
        OriginalOfferTitles[label] = {
            Text = label.Text,
            Size = label.Size,
            Position = label.Position,
            TextSize = label.TextSize,
            TextScaled = label.TextScaled,
            TextWrapped = label.TextWrapped,
            TextXAlignment = label.TextXAlignment,
        }
    end
    return label and OriginalOfferTitles[label] or nil
end

local function RestoreOfferTitleVisual(label, state)
    if not label or not state then return end
    label.Size = state.Size
    label.Position = state.Position
    label.TextSize = state.TextSize
    label.TextScaled = state.TextScaled
    label.TextWrapped = state.TextWrapped
    label.TextXAlignment = state.TextXAlignment
    local constraint = label:FindFirstChild("Kenderlike_SumTextConstraint")
    if constraint then
        constraint:Destroy()
    end
end

local function GetTextWidth(label, text, textSize)
    local ok, size = pcall(function()
        return TextService:GetTextSize(
            tostring(text or ""),
            textSize,
            label.Font,
            Vector2.new(10000, math.max(20, label.AbsoluteSize.Y))
        )
    end)
    return ok and size.X or 0
end

local function FitOfferSumBeforeUsername(label, offerBlock)
    local state = RememberOfferTitle(label)
    if not state then return end

    RestoreOfferTitleVisual(label, state)
    label.TextXAlignment = Enum.TextXAlignment.Left
    label.TextWrapped = false
    local fullWidth = label.AbsoluteSize.X
    if fullWidth <= 0 then return end

    local availableWidth = fullWidth
    local username = offerBlock and offerBlock:FindFirstChild("Username", true)
    local usernameIsText = username
        and (username:IsA("TextLabel") or username:IsA("TextButton") or username:IsA("TextBox"))
    if usernameIsText and username.Visible and tostring(username.Text or "") ~= "" then
        local usernameTextWidth = GetTextWidth(username, username.Text, username.TextSize)
        local usernameTextLeft = username.AbsolutePosition.X
        if username.TextXAlignment == Enum.TextXAlignment.Center then
            usernameTextLeft = username.AbsolutePosition.X
                + math.max(0, (username.AbsoluteSize.X - usernameTextWidth) / 2)
        elseif username.TextXAlignment == Enum.TextXAlignment.Right then
            usernameTextLeft = username.AbsolutePosition.X
                + math.max(0, username.AbsoluteSize.X - usernameTextWidth)
        end

        local gapWidth = usernameTextLeft - label.AbsolutePosition.X - 6
        if gapWidth < fullWidth then
            availableWidth = math.max(40, gapWidth)
        end
    end

    local naturalWidth = GetTextWidth(label, label.Text, state.TextSize)
    if naturalWidth <= availableWidth then
        return
    end

    availableWidth = math.max(40, math.floor(availableWidth))
    local widthDelta = availableWidth - fullWidth
    label.Size = UDim2.new(0, availableWidth, state.Size.Y.Scale, state.Size.Y.Offset)
    label.Position = UDim2.new(
        state.Position.X.Scale,
        state.Position.X.Offset + widthDelta * label.AnchorPoint.X,
        state.Position.Y.Scale,
        state.Position.Y.Offset
    )
    label.TextScaled = true
    label.TextWrapped = false
    label.TextXAlignment = Enum.TextXAlignment.Left

    local constraint = Instance.new("UITextSizeConstraint")
    constraint.Name = "Kenderlike_SumTextConstraint"
    constraint.MaxTextSize = math.max(8, math.floor(state.TextSize))
    constraint.MinTextSize = math.min(9, constraint.MaxTextSize)
    constraint.Parent = label
end

local function HandlePriceTradeGui(tradeGui)
    if not PriceOverlay.Enabled or not tradeGui or not tradeGui.Enabled then
        if tradeGui then
            PriceTradeActiveSince[tradeGui] = nil
        end
        return
    end

    local tradeContainer = tradeGui:FindFirstChild("Container")
    local tradeBase = tradeContainer and tradeContainer:FindFirstChild("Trade")
    if not tradeContainer
        or not tradeBase
        or not IsPriceObjectOnScreen(tradeContainer)
        or not IsPriceObjectOnScreen(tradeBase) then
        PriceTradeActiveSince[tradeGui] = nil
        return
    end

    local now = os.clock()
    if not PriceTradeActiveSince[tradeGui] then
        PriceTradeActiveSince[tradeGui] = now
        return
    elseif now - PriceTradeActiveSince[tradeGui] < PriceTradeInitDelay then
        return
    end

    ProcessPriceContainer(tradeContainer, false)

    local yourOffer = tradeBase:FindFirstChild("YourOffer")
    local theirOffer = tradeBase:FindFirstChild("TheirOffer")

    if yourOffer and IsPriceObjectOnScreen(yourOffer) then
        local title = yourOffer:FindFirstChild("Title")
        if title and title:IsA("TextLabel") then
            RememberOfferTitle(title)
            title.Text = ProcessPriceContainer(yourOffer, true) or "0"
            FitOfferSumBeforeUsername(title, yourOffer)
        end
    end

    if theirOffer and IsPriceObjectOnScreen(theirOffer) then
        local title = theirOffer:FindFirstChild("Title")
        if title and title:IsA("TextLabel") then
            local state = RememberOfferTitle(title)
            local username = theirOffer:FindFirstChild("Username", true)
            local hasSeparateUsername = username
                and (username:IsA("TextLabel") or username:IsA("TextButton") or username:IsA("TextBox"))
                and username.Visible
                and tostring(username.Text or "") ~= ""
            local suffix = hasSeparateUsername
                and ""
                or tostring(state and state.Text or title.Text):match("(%s*%([^%)]+%))$") or ""
            title.Text = (ProcessPriceContainer(theirOffer, true) or "0") .. suffix
            FitOfferSumBeforeUsername(title, theirOffer)
        end
    end
end

local function ScanPricesOnce()
    HandlePriceTradeGui(PricePlayerGui:FindFirstChild("TradeGUI"))
    HandlePriceTradeGui(PricePlayerGui:FindFirstChild("TradeGUI_Phone"))

    local mainGui = PricePlayerGui:FindFirstChild("MainGUI")
    if mainGui and mainGui.Enabled then
        for _, child in ipairs(mainGui:GetChildren()) do
            if child:IsA("GuiObject")
                and not IgnoredPriceAncestors[child.Name]
                and IsPriceObjectOnScreen(child) then
                ProcessPriceContainer(child, false)
            end
        end
    end
end

local function ClearPriceOverlay()
    for _, descendant in ipairs(PricePlayerGui:GetDescendants()) do
        if descendant.Name == PriceTagName then
            pcall(function()
                descendant:Destroy()
            end)
        end
    end

    for label, state in pairs(OriginalOfferTitles) do
        if label and label.Parent then
            pcall(function()
                label.Text = state.Text
                RestoreOfferTitleVisual(label, state)
            end)
        end
    end
    OriginalOfferTitles = setmetatable({}, { __mode = "k" })
    PriceTradeActiveSince = setmetatable({}, { __mode = "k" })
end

function PriceOverlay:SetEnabled(enabled)
    enabled = enabled == true
    if self.Enabled == enabled then
        return
    end

    self.Enabled = enabled
    self.Token = self.Token + 1
    local token = self.Token

    if not enabled then
        ClearPriceOverlay()
        return
    end

    task.spawn(function()
        while self.Enabled and self.Token == token do
            if PricesLoaded then
                pcall(ScanPricesOnce)
            end
            task.wait(0.5)
        end
    end)
end

local SetPriceOverlayToggleState
CreateSpace(controlFrame)
local _priceToggleButton, _getPriceToggleState, priceToggleSetter = CreateToggleButton(controlFrame, "Показывать валюты", function(enabled)
    PriceOverlay:SetEnabled(enabled)
    local runtimeEnvironment = (type(getgenv) == "function" and getgenv()) or _G
    local standalone = runtimeEnvironment.KenderlikeScriptValues
    if type(standalone) == "table" and type(standalone.SetEnabled) == "function" then
        pcall(function()
            standalone:SetEnabled(enabled)
        end)
    end
end)
SetPriceOverlayToggleState = priceToggleSetter
do
    local runtimeEnvironment = (type(getgenv) == "function" and getgenv()) or _G
    local standalone = runtimeEnvironment.KenderlikeScriptValues
    if type(standalone) == "table" and type(standalone.SetEnabled) == "function" then
        pcall(function()
            standalone:SetEnabled(false)
        end)
    end
end
CreateSpace(controlFrame)

PartnerUserBox = createSettingRow("Партнёр:", TradeTable.Player2.Player, controlFrame)
PartnerUserBox.FocusLost:Connect(function()
    TradeTable.Player2.Player = PartnerUserBox.Text
    PartnerUserBox.Text = TradeTable.Player2.Player
end)
CreateSpace(controlFrame)

CreateButton(controlFrame, "Начать трейд", function()
    StartTrade()
end)
CreateSpace(controlFrame)

CreateButton(controlFrame, "Переключить принятие партнёра", function()
    if type(ToggleOpponentAcceptance) == "function" then
        ToggleOpponentAcceptance()
    end
end)
CreateSpace(controlFrame)

local function resolvePlayerToBlock(nameOrPlayer)
    if typeof(nameOrPlayer) == "Instance" and nameOrPlayer:IsA("Player") then
        if nameOrPlayer.Parent == Players then return nameOrPlayer end
        return nil
    end
    if type(nameOrPlayer) ~= "string" or nameOrPlayer == "" or nameOrPlayer == "Kenderlike" then
        return nil
    end

    local wanted = string.lower(nameOrPlayer)
    for _, player in ipairs(Players:GetPlayers()) do
        if string.lower(player.Name) == wanted then return player end
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if string.lower(player.DisplayName) == wanted then return player end
    end
    return nil
end

local BlockStarterGui = game:GetService("StarterGui")
local Players = game:GetService("Players")

local function resolvePlayerToBlock(nameOrPlayer)
    if typeof(nameOrPlayer) == "Instance" and nameOrPlayer:IsA("Player") then
        if nameOrPlayer.Parent == Players then
            return nameOrPlayer
        end
        return nil
    end
    if type(nameOrPlayer) ~= "string" or nameOrPlayer == "" or nameOrPlayer == "Kenderlike" then
        return nil
    end

    local wanted = string.lower(nameOrPlayer)
    for _, player in ipairs(Players:GetPlayers()) do
        if string.lower(player.Name) == wanted then
            return player
        end
    end
    for _, player in ipairs(Players:GetPlayers()) do
        if string.lower(player.DisplayName) == wanted then
            return player
        end
    end
    return nil
end

local blockRequestBusy = false

local function SilentBlockPlayer(nameOrPlayer)
    if blockRequestBusy then
        return false
    end

    local target = resolvePlayerToBlock(nameOrPlayer)
    if not target then
        return false
    end
    if target == Players.LocalPlayer then
        return false
    end

    blockRequestBusy = true

    local opened, openError = false, nil
    for _ = 1, 6 do
        opened, openError = pcall(function()
            BlockStarterGui:SetCore("PromptBlockPlayer", target)
        end)
        if opened then break end
        task.wait(0.12)
    end

    blockRequestBusy = false
    return opened
end

CreateButton(controlFrame, "Заблокировать игрока", function()
    local name = tostring(TradeTable.Player2 and TradeTable.Player2.Player or "")
    local target = resolvePlayerToBlock(name)
    if not target then return end
    task.spawn(function()
        SilentBlockPlayer(target)
    end)
end)

local RandomOfferMinValue = 65
local RandomOfferMaxValue = 500
local FillOpponentRandomByValue
local RandomOfferMinBox
local RandomOfferMaxBox
local RandomOfferRarities = {
    Godly = true,
    Chroma = true,
    Ancient = true,
}
local RandomOfferRarityDefinitions = {
    { id = "Godly", label = "Годли" },
    { id = "Chroma", label = "Хрома" },
    { id = "Ancient", label = "Древние" },
}
local RandomOfferRarityButtons = {}

local function UpdateRandomOfferRarityButton(rarity)
    local button = RandomOfferRarityButtons[rarity]
    if not button then
        return
    end

    local label = rarity
    for _, definition in ipairs(RandomOfferRarityDefinitions) do
        if definition.id == rarity then
            label = definition.label
            break
        end
    end

    local enabled = RandomOfferRarities[rarity] == true
    button.Text = (enabled and "☑ " or "☐ ") .. label
    button.BackgroundColor3 = enabled
        and Color3.fromRGB(70, 95, 70)
        or Color3.fromRGB(58, 58, 58)
end

local function SetRandomOfferRarity(rarity, enabled)
    if RandomOfferRarities[rarity] == nil then
        return false
    end
    RandomOfferRarities[rarity] = enabled == true
    UpdateRandomOfferRarityButton(rarity)
    return true
end

local function GetRandomOfferRarities()
    return {
        Godly = RandomOfferRarities.Godly == true,
        Chroma = RandomOfferRarities.Chroma == true,
        Ancient = RandomOfferRarities.Ancient == true,
    }
end

local function SetRandomOfferRange(minimumText, maximumText)
    local minimum = ParseNumericPrice(minimumText)
    local maximum = ParseNumericPrice(maximumText)
    if minimum == nil then
        minimum = RandomOfferMinValue
    end
    if maximum == nil then
        maximum = RandomOfferMaxValue
    end

    minimum = math.max(0, math.floor(minimum))
    maximum = math.max(0, math.floor(maximum))
    if minimum > maximum then
        minimum, maximum = maximum, minimum
    end

    RandomOfferMinValue = minimum
    RandomOfferMaxValue = maximum
    if RandomOfferMinBox then
        RandomOfferMinBox.Text = tostring(minimum)
    end
    if RandomOfferMaxBox then
        RandomOfferMaxBox.Text = tostring(maximum)
    end
    return minimum, maximum
end

local function setupItemsSpawner()
local selectedWeapon = ""

local ItemToAddPartnerBox = createSettingRow("Название предмета:", "", itemsFrame)

CreateSpace(itemsFrame)

local addItemBtn = CreateButton(itemsFrame, "Добавить предмет партнёру", function()
    local itemToAdd = ItemToAddPartnerBox.Text
    if itemToAdd and itemToAdd ~= "" then
        OfferItemAnotherPlayer(itemToAdd, "Weapons")
    end
end)

CreateSpace(itemsFrame)

CreateButton(itemsFrame, "Убрать последний предмет партнёра", function()
    RemoveItemAnotherPlayer()
end)

CreateSpace(itemsFrame)

RandomOfferMinBox = createSettingRow("Цена случайного предмета — от:", tostring(RandomOfferMinValue), itemsFrame)
RandomOfferMaxBox = createSettingRow("Цена случайного предмета — до:", tostring(RandomOfferMaxValue), itemsFrame)

local function CommitRandomOfferRange()
    local minimum, maximum = SetRandomOfferRange(RandomOfferMinBox.Text, RandomOfferMaxBox.Text)
    RandomOfferMinBox.Text = tostring(minimum)
    RandomOfferMaxBox.Text = tostring(maximum)
end

RandomOfferMinBox.FocusLost:Connect(CommitRandomOfferRange)
RandomOfferMaxBox.FocusLost:Connect(CommitRandomOfferRange)

local raritySelectorLabel = Instance.new("TextLabel")
raritySelectorLabel.Size = UDim2.new(1, 0, 0, 15)
raritySelectorLabel.BackgroundTransparency = 1
raritySelectorLabel.Text = "Редкости случайного предмета:"
raritySelectorLabel.Font = Enum.Font.SourceSansSemibold
raritySelectorLabel.TextSize = 12
raritySelectorLabel.TextColor3 = Color3.fromRGB(190, 190, 190)
raritySelectorLabel.TextXAlignment = Enum.TextXAlignment.Left
raritySelectorLabel.Parent = itemsFrame

local raritySelectorFrame = Instance.new("Frame")
raritySelectorFrame.Size = UDim2.new(1, 0, 0, 30)
raritySelectorFrame.BackgroundTransparency = 1
raritySelectorFrame.Parent = itemsFrame

local raritySelectorLayout = Instance.new("UIListLayout")
raritySelectorLayout.FillDirection = Enum.FillDirection.Horizontal
raritySelectorLayout.HorizontalAlignment = Enum.HorizontalAlignment.Center
raritySelectorLayout.SortOrder = Enum.SortOrder.LayoutOrder
raritySelectorLayout.Padding = UDim.new(0, 3)
raritySelectorLayout.Parent = raritySelectorFrame

for _, definition in ipairs(RandomOfferRarityDefinitions) do
    local rarityButton = Instance.new("TextButton")
    rarityButton.Size = UDim2.new(1 / #RandomOfferRarityDefinitions, -3, 1, 0)
    rarityButton.BackgroundColor3 = Color3.fromRGB(58, 58, 58)
    rarityButton.BackgroundTransparency = 0.1
    rarityButton.BorderSizePixel = 0
    rarityButton.Font = Enum.Font.SourceSansSemibold
    rarityButton.TextSize = 12
    rarityButton.TextScaled = true
    rarityButton.TextColor3 = Color3.fromRGB(255, 255, 255)
    rarityButton.Parent = raritySelectorFrame

    local rarityTextSize = Instance.new("UITextSizeConstraint")
    rarityTextSize.MinTextSize = 8
    rarityTextSize.MaxTextSize = 12
    rarityTextSize.Parent = rarityButton

    local rarityCorner = Instance.new("UICorner")
    rarityCorner.CornerRadius = UDim.new(0, 4)
    rarityCorner.Parent = rarityButton

    RandomOfferRarityButtons[definition.id] = rarityButton
    UpdateRandomOfferRarityButton(definition.id)

    rarityButton.MouseButton1Click:Connect(function()
        SetRandomOfferRarity(definition.id, not RandomOfferRarities[definition.id])
    end)
end

local randomOfferStatus = Instance.new("TextLabel")
randomOfferStatus.Size = UDim2.new(1, 0, 0, 15)
randomOfferStatus.BackgroundTransparency = 1
randomOfferStatus.Text = "Числовые цены из ParserMM2"
randomOfferStatus.Font = Enum.Font.SourceSans
randomOfferStatus.TextSize = 11
randomOfferStatus.TextColor3 = Color3.fromRGB(170, 170, 170)
randomOfferStatus.TextXAlignment = Enum.TextXAlignment.Left
randomOfferStatus.TextTruncate = Enum.TextTruncate.AtEnd
randomOfferStatus.Parent = itemsFrame

CreateButton(itemsFrame, "Добавить случайный предмет по цене", function()
    CommitRandomOfferRange()
    if type(FillOpponentRandomByValue) ~= "function" then
        return
    end
    local success, message = FillOpponentRandomByValue()
    randomOfferStatus.Text = message or (success and "Предмет добавлен" or "Подходящих предметов нет")
    randomOfferStatus.TextColor3 = success
        and Color3.fromRGB(150, 230, 170)
        or Color3.fromRGB(255, 150, 120)
end)

local weaponListLabel = Instance.new("TextLabel")
weaponListLabel.Size = UDim2.new(1, 0, 0, 15)
weaponListLabel.BackgroundTransparency = 1
weaponListLabel.Text = "Нажмите на оружие для добавления:"
weaponListLabel.Font = Enum.Font.SourceSansSemibold
weaponListLabel.TextSize = 12
weaponListLabel.TextScaled = true
weaponListLabel.TextColor3 = Color3.fromRGB(190, 190, 190)
weaponListLabel.TextXAlignment = Enum.TextXAlignment.Left
weaponListLabel.Parent = itemsFrame

local weaponListTextSize = Instance.new("UITextSizeConstraint")
weaponListTextSize.MinTextSize = 8
weaponListTextSize.MaxTextSize = 12
weaponListTextSize.Parent = weaponListLabel

local weaponScrollFrame = Instance.new("ScrollingFrame")
weaponScrollFrame.Size = UDim2.new(1, 0, 0, 120)
weaponScrollFrame.BackgroundColor3 = Color3.fromRGB(26, 26, 26)
weaponScrollFrame.BackgroundTransparency = 0.3
weaponScrollFrame.BorderSizePixel = 0
weaponScrollFrame.ScrollBarThickness = 6
weaponScrollFrame.ScrollBarImageColor3 = Color3.fromRGB(111, 111, 111)
weaponScrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
weaponScrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
weaponScrollFrame.Parent = itemsFrame

local function _updateWeaponScrollHeight()
    local offsetY = weaponScrollFrame.AbsolutePosition.Y - itemsFrame.AbsolutePosition.Y
    local available = itemsFrame.AbsoluteSize.Y - offsetY - 4
    weaponScrollFrame.Size = UDim2.new(1, 0, 0, math.max(80, available))
end
itemsFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(_updateWeaponScrollHeight)
task.defer(_updateWeaponScrollHeight)

local weaponScrollCorner = Instance.new("UICorner")
weaponScrollCorner.CornerRadius = UDim.new(0, 5)
weaponScrollCorner.Parent = weaponScrollFrame

local weaponScrollStroke = Instance.new("UIStroke")
weaponScrollStroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
weaponScrollStroke.Color = Color3.fromRGB(83, 83, 83)
weaponScrollStroke.Thickness = 1
weaponScrollStroke.Parent = weaponScrollFrame

local weaponListLayout = Instance.new("UIListLayout")
weaponListLayout.FillDirection = Enum.FillDirection.Vertical
weaponListLayout.SortOrder = Enum.SortOrder.LayoutOrder
weaponListLayout.Padding = UDim.new(0, 2)
weaponListLayout.Parent = weaponScrollFrame

local weaponListPadding = Instance.new("UIPadding")
weaponListPadding.PaddingTop = UDim.new(0, 3)
weaponListPadding.PaddingBottom = UDim.new(0, 3)
weaponListPadding.PaddingLeft = UDim.new(0, 3)
weaponListPadding.PaddingRight = UDim.new(0, 3)
weaponListPadding.Parent = weaponScrollFrame

local _rarityRank = {
    Chroma = 10, Godly = 9, Ancient = 8, Unique = 7,
    Classic = 6, Legendary = 5, Vintage = 4,
    Rare = 3, Uncommon = 2, Common = 1,
}

local allWeaponsList = {}
for _, entry in ipairs(WeaponCatalog) do
    if entry.rarity == "Godly" or entry.rarity == "Chroma" or entry.chroma == true then
        if not IsTradeAvoided(entry.key, entry.name) then
            table.insert(allWeaponsList, entry)
        end
    end
end
table.sort(allWeaponsList, function(a, b)
    local va = GetItemValue(a.key, a.name)
    local vb = GetItemValue(b.key, b.name)
    if va ~= vb then return va > vb end
    local ra = _rarityRank[a.rarity] or 0
    local rb = _rarityRank[b.rarity] or 0
    if ra ~= rb then return ra > rb end
    return tostring(a.name) < tostring(b.name)
end)

local RarityTint = {
    Chroma    = Color3.fromRGB(50, 50, 50),
    Godly     = Color3.fromRGB(76, 76, 76),
    Ancient   = Color3.fromRGB(37, 37, 37),
    Unique    = Color3.fromRGB(72, 72, 72),
    Legendary = Color3.fromRGB(61, 61, 61),
    Classic   = Color3.fromRGB(71, 71, 71),
    Vintage   = Color3.fromRGB(73, 73, 73),
    Rare      = Color3.fromRGB(57, 57, 57),
    Uncommon  = Color3.fromRGB(61, 61, 61),
    Common    = Color3.fromRGB(51, 51, 51),
}

local RarityNamesRu = {
    Chroma = "Хрома",
    Godly = "Божественный",
    Ancient = "Древний",
    Unique = "Уникальный",
    Legendary = "Легендарный",
    Classic = "Классический",
    Vintage = "Винтажный",
    Rare = "Редкий",
    Uncommon = "Необычный",
    Common = "Обычный",
}

local ItemTypeNamesRu = {
    Knife = "Нож",
    Gun = "Пистолет",
}

local function LocalizeRarity(rarity)
    return RarityNamesRu[rarity] or tostring(rarity)
end

local function LocalizeItemType(itemType)
    return ItemTypeNamesRu[itemType] or tostring(itemType)
end

local weaponButtons = {}

for i, entry in ipairs(allWeaponsList) do
    local wKey = entry.key
    local wName = entry.name
    local baseColor = RarityTint[entry.rarity] or RarityTint.Common
    local val = GetItemValue(wKey, wName)
    local label = wName .. (entry.chroma and " [Хрома]" or "") .. "   ("
        .. LocalizeRarity(entry.rarity) .. " " .. LocalizeItemType(entry.type)
        .. (val > 0 and (", " .. FormatValue(val)) or "") .. ")"

    local weaponBtn = Instance.new("TextButton")
    weaponBtn.Size = UDim2.new(1, -6, 0, 22)
    weaponBtn.BackgroundColor3 = baseColor
    weaponBtn.BackgroundTransparency = 0.2
    weaponBtn.Text = label
    weaponBtn.Font = Enum.Font.SourceSans
    weaponBtn.TextSize = 12
    weaponBtn.TextColor3 = Color3.fromRGB(255, 255, 255)
    weaponBtn.TextXAlignment = Enum.TextXAlignment.Left
    weaponBtn.TextTruncate = Enum.TextTruncate.AtEnd
    weaponBtn.Parent = weaponScrollFrame

    local btnPadding = Instance.new("UIPadding")
    btnPadding.PaddingLeft = UDim.new(0, 6)
    btnPadding.PaddingRight = UDim.new(0, 6)
    btnPadding.Parent = weaponBtn

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 4)
    btnCorner.Parent = weaponBtn

    weaponBtn.MouseEnter:Connect(function()
        TweenService:Create(weaponBtn, TweenInfo.new(0.15), {BackgroundColor3 = baseColor:Lerp(Color3.fromRGB(255, 255, 255), 0.25)}):Play()
    end)

    weaponBtn.MouseLeave:Connect(function()
        TweenService:Create(weaponBtn, TweenInfo.new(0.15), {BackgroundColor3 = baseColor}):Play()
    end)

    weaponBtn.MouseButton1Click:Connect(function()
        local success = OfferItemAnotherPlayer(wKey, "Weapons")
        if success then
            TweenService:Create(weaponBtn, TweenInfo.new(0.1), {BackgroundColor3 = Color3.fromRGB(114, 114, 114)}):Play()
        else
            TweenService:Create(weaponBtn, TweenInfo.new(0.1), {BackgroundColor3 = Color3.fromRGB(71, 71, 71)}):Play()
        end
        task.delay(0.2, function()
            TweenService:Create(weaponBtn, TweenInfo.new(0.15), {BackgroundColor3 = baseColor}):Play()
        end)
    end)

    weaponButtons[#weaponButtons + 1] = {button = weaponBtn, entry = entry}
end

ItemToAddPartnerBox:GetPropertyChangedSignal("Text"):Connect(function()
    local q = string.lower(ItemToAddPartnerBox.Text or "")
    for _, info in ipairs(weaponButtons) do
        if q == "" then
            info.button.Visible = true
        else
            local e = info.entry
            local hay = string.lower(e.name .. " " .. e.key .. " " .. e.rarity .. " " .. e.type)
            info.button.Visible = string.find(hay, q, 1, true) ~= nil
        end
    end
end)

local SpawnerRandomRanges = {
    Chroma    = {1, 2},
    Godly     = {1, 5},
    Ancient   = {2, 6},
    Unique    = {2, 8},
    Classic   = {3, 10},
    Legendary = {4, 12},
    Vintage   = {5, 15},
    Rare      = {8, 25},
    Uncommon  = {10, 40},
    Common    = {15, 60},
}

local SpawnerHighTierSet = {
    Chroma = true, Godly = true, Ancient = true,
    Unique = true, Classic = true, Legendary = true, Vintage = true,
}

local function _randomAmount(rarity, evo)
    if evo then return 1 end
    local r = SpawnerRandomRanges[rarity] or SpawnerRandomRanges.Common
    return math.random(r[1], r[2])
end

local SpawnerAmountBox = createSettingRow("Количество за клик (0 = случайно):", "0", spawnerFrame)
CreateSpace(spawnerFrame)

local SpawnerSearchBox = createSettingRow("Поиск оружия:", "", spawnerFrame)
CreateSpace(spawnerFrame)

local spawnerStatusLabel = Instance.new("TextLabel")
spawnerStatusLabel.Size = UDim2.new(1, 0, 0, 15)
spawnerStatusLabel.BackgroundTransparency = 1
spawnerStatusLabel.Text = "Нажмите на оружие для создания:"
spawnerStatusLabel.Font = Enum.Font.SourceSansSemibold
spawnerStatusLabel.TextSize = 12
spawnerStatusLabel.TextScaled = true
spawnerStatusLabel.TextColor3 = Color3.fromRGB(190, 190, 190)
spawnerStatusLabel.TextXAlignment = Enum.TextXAlignment.Left
spawnerStatusLabel.Parent = spawnerFrame

local spawnerStatusTextSize = Instance.new("UITextSizeConstraint")
spawnerStatusTextSize.MinTextSize = 7
spawnerStatusTextSize.MaxTextSize = 12
spawnerStatusTextSize.Parent = spawnerStatusLabel

local spawnHighTierBtn = CreateButton(spawnerFrame, "Создать ценные обмениваемые предметы", function()
    local count, total, skipped = 0, 0, 0
    local meshCount = 0
    for _ in pairs(MESHES) do
        meshCount = meshCount + 1
    end
    if meshCount == 0 then
        spawnerStatusLabel.Text = "Меши не загружены (проверьте MESHES_URL)"
        spawnerStatusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
        return
    end

    for _, entry in ipairs(WeaponCatalog) do
        if SpawnerHighTierSet[entry.rarity] then
            local val = GetItemValue(entry.key, entry.name)
            if not HasMesh(entry.key) or val < 65 or IsTradeAvoided(entry.key, entry.name) then
                skipped = skipped + 1
                continue
            end
            local amt = _randomAmount(entry.rarity, false)
            SpawnItem(entry.key, amt, "Weapons")
            count = count + 1
            total = total + amt
        end
    end

    spawnerStatusLabel.Text = ("Создано типов: %d, предметов: %d | пропущено: %d (нет меша или цена < 65)"):format(count, total, skipped)
    spawnerStatusLabel.TextColor3 = Color3.fromRGB(219, 219, 219)
end)
CreateSpace(spawnerFrame)

CreateButton(spawnerFrame, "Удалить необмениваемые из инвентаря", function()
    local removed = PurgeBlockedFromInventory()
    spawnerStatusLabel.Text = ("Удалено необмениваемого оружия: %d"):format(removed)
    spawnerStatusLabel.TextColor3 = (removed > 0)
        and Color3.fromRGB(219, 219, 219)
        or Color3.fromRGB(206, 206, 206)
end)

CreateSpace(spawnerFrame)

local spawnerScrollFrame = Instance.new("ScrollingFrame")
spawnerScrollFrame.Size = UDim2.new(1, 0, 0, 120)
spawnerScrollFrame.BackgroundColor3 = Color3.fromRGB(26, 26, 26)
spawnerScrollFrame.BackgroundTransparency = 0.3
spawnerScrollFrame.BorderSizePixel = 0
spawnerScrollFrame.ScrollBarThickness = 6
spawnerScrollFrame.ScrollBarImageColor3 = Color3.fromRGB(111, 111, 111)
spawnerScrollFrame.CanvasSize = UDim2.new(0, 0, 0, 0)
spawnerScrollFrame.AutomaticCanvasSize = Enum.AutomaticSize.Y
spawnerScrollFrame.Parent = spawnerFrame

local function _updateSpawnerScrollHeight()
    local offsetY = spawnerScrollFrame.AbsolutePosition.Y - spawnerFrame.AbsolutePosition.Y
    local available = spawnerFrame.AbsoluteSize.Y - offsetY - 4
    spawnerScrollFrame.Size = UDim2.new(1, 0, 0, math.max(80, available))
end
spawnerFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(_updateSpawnerScrollHeight)
task.defer(_updateSpawnerScrollHeight)

do
    local c = Instance.new("UICorner") c.CornerRadius = UDim.new(0, 5) c.Parent = spawnerScrollFrame
    local s = Instance.new("UIStroke") s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    s.Color = Color3.fromRGB(83, 83, 83) s.Thickness = 1 s.Parent = spawnerScrollFrame
    local lay = Instance.new("UIListLayout") lay.FillDirection = Enum.FillDirection.Vertical
    lay.SortOrder = Enum.SortOrder.LayoutOrder lay.Padding = UDim.new(0, 2) lay.Parent = spawnerScrollFrame
    local pad = Instance.new("UIPadding")
    pad.PaddingTop = UDim.new(0, 3) pad.PaddingBottom = UDim.new(0, 3)
    pad.PaddingLeft = UDim.new(0, 3) pad.PaddingRight = UDim.new(0, 3)
    pad.Parent = spawnerScrollFrame
end

local spawnerList = {}
for _, entry in ipairs(WeaponCatalog) do
    local itemVal = GetItemValue(entry.key, entry.name)
    if itemVal >= 65 and not IsTradeAvoided(entry.key, entry.name) then
        table.insert(spawnerList, entry)
    end
end
table.sort(spawnerList, function(a, b)
    local va = GetItemValue(a.key, a.name)
    local vb = GetItemValue(b.key, b.name)
    if va ~= vb then return va > vb end
    return tostring(a.name) < tostring(b.name)
end)

local spawnerButtons = {}
for _, entry in ipairs(spawnerList) do
    local wKey = entry.key
    local itemVal = GetItemValue(wKey, entry.name)
    local baseColor = RarityTint[entry.rarity] or RarityTint.Common
    local label = entry.name .. (entry.chroma and " [Хрома]" or "")
        .. "   (" .. LocalizeRarity(entry.rarity) .. " " .. LocalizeItemType(entry.type)
        .. ", " .. FormatValue(itemVal) .. ")"

    local btn = Instance.new("TextButton")
    btn.Size = UDim2.new(1, -6, 0, 22)
    btn.BackgroundColor3 = baseColor
    btn.BackgroundTransparency = 0.2
    btn.Text = label
    btn.Font = Enum.Font.SourceSans
    btn.TextSize = 12
    btn.TextColor3 = Color3.fromRGB(255, 255, 255)
    btn.TextXAlignment = Enum.TextXAlignment.Left
    btn.TextTruncate = Enum.TextTruncate.AtEnd
    btn.Parent = spawnerScrollFrame

    local btnPad = Instance.new("UIPadding")
    btnPad.PaddingLeft = UDim.new(0, 6)
    btnPad.PaddingRight = UDim.new(0, 6)
    btnPad.Parent = btn

    local btnCorner = Instance.new("UICorner")
    btnCorner.CornerRadius = UDim.new(0, 4)
    btnCorner.Parent = btn

    btn.MouseEnter:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = baseColor:Lerp(Color3.fromRGB(255, 255, 255), 0.25)}):Play()
    end)
    btn.MouseLeave:Connect(function()
        TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = baseColor}):Play()
    end)

    btn.MouseButton1Click:Connect(function()
        local typed = tonumber(SpawnerAmountBox.Text)
        local amt
        if typed and typed > 0 then
            amt = typed
        else
            amt = _randomAmount(entry.rarity, false)
        end
        SpawnItem(wKey, amt, "Weapons")
        spawnerStatusLabel.Text = ("Создано: %s x%d"):format(entry.name, amt)
        spawnerStatusLabel.TextColor3 = Color3.fromRGB(219, 219, 219)
        TweenService:Create(btn, TweenInfo.new(0.1), {BackgroundColor3 = Color3.fromRGB(114, 114, 114)}):Play()
        task.delay(0.2, function()
            TweenService:Create(btn, TweenInfo.new(0.15), {BackgroundColor3 = baseColor}):Play()
        end)
    end)

    spawnerButtons[#spawnerButtons + 1] = {button = btn, entry = entry}
end

SpawnerSearchBox:GetPropertyChangedSignal("Text"):Connect(function()
    local q = string.lower(SpawnerSearchBox.Text or "")
    for _, info in ipairs(spawnerButtons) do
        if q == "" then
            info.button.Visible = true
        else
            local e = info.entry
            local hay = string.lower(e.name .. " " .. e.key .. " " .. e.rarity .. " " .. e.type)
            info.button.Visible = string.find(hay, q, 1, true) ~= nil
        end
    end
end)


end
setupItemsSpawner()

local function setupVisualSystem()
local CollectionService = game:GetService("CollectionService")
local InsertService = game:GetService("InsertService")
local RunService = game:GetService("RunService")

local visuals_config = {
    InjectParticles = true,
    HideOriginal = true,
    PollRate = 0.1,
}

local EquipService
pcall(function()
    EquipService = require(game.ReplicatedStorage.ClientServices.EquipService)
end)

local function trimAsset(v)
    if type(v) == "string" then return (v:gsub("^%s+", ""):gsub("%s+$", "")) end
    return v
end

local function applyProps(inst, props, skip)
    for k, v in pairs(props) do
        if not (skip and skip[k]) then
            if k == "MeshId" or k == "TextureId" or k == "TextureID" or k == "Texture" then v = trimAsset(v) end
            pcall(function() inst[k] = v end)
        end
    end
end

local function createMeshPart(props)
    local meshId = trimAsset(props.MeshId or "")
    local size = props.Size or Vector3.new(1, 1, 1)
    local part
    pcall(function()
        part = game:GetService("InsertService"):CreateMeshPartAsync(meshId, Enum.CollisionFidelity.Box, Enum.RenderFidelity.Precise)
    end)
    if part then pcall(function() part.Size = size end); return part end
    local p = Instance.new("Part"); p.Size = size
    local sm = Instance.new("SpecialMesh"); sm.MeshType = Enum.MeshType.FileMesh
    pcall(function() sm.MeshId = meshId end); pcall(function() sm.TextureId = trimAsset(props.TextureID or "") end)
    sm.Parent = p
    return p
end

local CHROMA = {
    Color3.fromRGB(255,0,0), Color3.fromRGB(255,255,0), Color3.fromRGB(0,255,0),
    Color3.fromRGB(0,255,255), Color3.fromRGB(0,0,255), Color3.fromRGB(255,0,255),
}
local function chromaColor(t)
    local n = #CHROMA; local phase = t % n; local i = math.floor(phase)
    return CHROMA[i + 1]:Lerp(CHROMA[((i + 1) % n) + 1], phase - i)
end
local function isChroma(name, data)
    if type(data) == "table" then
        if data.Meta and data.Meta.Chroma == true then
            return true
        end
        if data.Chroma == true then
            return true
        end
    end
    if type(name) == "string" and name:sub(-6) == "Chroma" then
        return true
    end
    return false
end

local chroma_rate = 1.8

local structural = {
    WeldConstraint = true,
    Weld = true,
    Motor6D = true,
    RigidConstraint = true,
    Bone = true,
    Snap = true,
    ManualWeld = true,
    Rotate = true,
    RotateP = true,
    RotateV = true,
}

local function chromaTag(inst, node)
    if not inst then
        return
    end

    local tags = (node and node.Tags) or {}
    local nodeName = tostring((node and node.Name) or inst.Name or "")
    local nameLow = string.lower(nodeName)

    if nameLow == "knifedisplay" or nameLow == "gundisplay" or nameLow == "(root)" then
        return
    end

    local wantDecal, wantPart, wantFire = false, false, false

    for _, t in ipairs(tags) do
        if t == "ChromaDecal" then
            wantDecal = true
        elseif t == "ChromaPart" then
            wantPart = true
        elseif t == "ChromaFire" then
            wantFire = true
        end
    end

    if nameLow == "chroma" or nameLow:find("chroma", 1, true) then
        if inst:IsA("Decal") or inst:IsA("Texture") then
            wantDecal = true
        elseif inst:IsA("Fire") then
            wantFire = true
        elseif inst:IsA("BasePart") then
            wantPart = true
        end
    end

    pcall(function()
        if wantDecal and (inst:IsA("Decal") or inst:IsA("Texture")) then
            CollectionService:AddTag(inst, "ChromaDecal")
        end
        if wantFire and inst:IsA("Fire") then
            CollectionService:AddTag(inst, "ChromaFire")
        end
        if wantPart and inst:IsA("BasePart") then
            CollectionService:AddTag(inst, "ChromaPart")
        end
    end)
end

local function startChroma(overlay)
    if not overlay then
        return nil
    end

    local flashParts, smoothDecals, smoothFire = {}, {}, {}

    local function consider(d)

        local n = string.lower(d.Name or "")
        if n == "knifedisplay" or n == "gundisplay" then
            return
        end
        if CollectionService:HasTag(d, "ChromaPart") and d:IsA("BasePart") then
            flashParts[#flashParts + 1] = d
        elseif CollectionService:HasTag(d, "ChromaDecal") and (d:IsA("Decal") or d:IsA("Texture")) then
            smoothDecals[#smoothDecals + 1] = d
        elseif CollectionService:HasTag(d, "ChromaFire") and d:IsA("Fire") then
            smoothFire[#smoothFire + 1] = d
        end
    end

    consider(overlay)
    for _, d in ipairs(overlay:GetDescendants()) do
        consider(d)
    end

    if #flashParts == 0 and #smoothDecals == 0 and #smoothFire == 0 then
        for _, d in ipairs(overlay:GetDescendants()) do
            if (d:IsA("Decal") or d:IsA("Texture")) and string.lower(d.Name or "") == "chroma" then
                CollectionService:AddTag(d, "ChromaDecal")
                smoothDecals[#smoothDecals + 1] = d
            end
        end
    end

    if #flashParts == 0 and #smoothDecals == 0 and #smoothFire == 0 then
        return nil
    end

    return RunService.Heartbeat:Connect(function()
        local now = os.clock()
        local col = chromaColor(now)
        for _, s in ipairs(smoothDecals) do
            pcall(function()
                s.Color3 = col
            end)
        end
        for _, s in ipairs(smoothFire) do
            pcall(function()
                s.Color = col
            end)
        end
        local step = math.floor(now * chroma_rate)
        for i, b in ipairs(flashParts) do
            pcall(function()
                b.Color = CHROMA[((step + i - 1) % #CHROMA) + 1]
            end)
        end
    end)
end

local function instantiateNode(node)
    local cls = node.Class
    if structural[cls] then return nil end

    if cls == "Script" or cls == "LocalScript" or cls == "ModuleScript" then
        return nil
    end
    local inst
    if cls == "MeshPart" then
        inst = createMeshPart(node.Props)
        applyProps(inst, node.Props, { MeshId = true, Size = true, RelCF = true, CanCollide = true })
    else
        local ok, res = pcall(Instance.new, cls)
        if not ok or not res then return nil end
        inst = res
        applyProps(inst, node.Props, { RelCF = true })
    end
    if node.Name then
        pcall(function()
            inst.Name = node.Name
        end)
    end
    chromaTag(inst, node)
    return inst
end

local function rebuildTree(node, parentInst, root, idToInst, parts, deferred)
    for _, child in ipairs(node.Children or {}) do
        local inst = instantiateNode(child)
        if inst then
            idToInst[child.Id] = inst
            if inst:IsA("BasePart") then
                inst.Anchored, inst.CanCollide, inst.CanQuery, inst.CanTouch, inst.Massless = false, false, false, false, true
                parts[#parts + 1] = { inst = inst, relcf = child.Props.RelCF }
                inst.Parent = root
                rebuildTree(child, inst, root, idToInst, parts, deferred)
            elseif inst:IsA("Attachment") then
                if child.Props.RelCF then pcall(function() inst.CFrame = child.Props.RelCF end) end
                inst.Parent = root
                rebuildTree(child, inst, root, idToInst, parts, deferred)
            elseif inst:IsA("Beam") or inst:IsA("Trail") then
                inst.Parent = parentInst
                deferred[#deferred + 1] = { inst = inst, a0 = child.Att0, a1 = child.Att1 }
                rebuildTree(child, inst, root, idToInst, parts, deferred)
            else
                inst.Parent = parentInst
                rebuildTree(child, inst, root, idToInst, parts, deferred)
               end
        else
            rebuildTree(child, parentInst, root, idToInst, parts, deferred)
        end
    end
end

local function buildFullOverlay(data)
    local rn = data.Model
    if not rn then return nil end
    local root
    if rn.Class == "MeshPart" then
        root = createMeshPart(rn.Props)
        applyProps(root, rn.Props, { MeshId = true, Size = true, RelCF = true, CanCollide = true })
    else
        root = Instance.new("Part")
        applyProps(root, rn.Props, { RelCF = true, CanCollide = true })
    end
    chromaTag(root, rn)
    root.Anchored, root.CanCollide, root.CanQuery, root.CanTouch, root.Massless = false, false, false, false, true
    local idToInst = { [rn.Id] = root }
    local parts, deferred = {}, {}
    rebuildTree(rn, root, root, idToInst, parts, deferred)
    for _, d in ipairs(deferred) do
        if d.a0 and idToInst[d.a0] then pcall(function() d.inst.Attachment0 = idToInst[d.a0] end) end
        if d.a1 and idToInst[d.a1] then pcall(function() d.inst.Attachment1 = idToInst[d.a1] end) end
    end
    return { root = root, parts = parts }
end

local function finalizeOverlay(built, targetCF)
    local root = built.root
    pcall(function() root.CFrame = targetCF end)
    for _, p in ipairs(built.parts) do
        if p.relcf then pcall(function() p.inst.CFrame = targetCF * p.relcf end) end
        local w = Instance.new("WeldConstraint"); w.Part0 = p.inst; w.Part1 = root; w.Parent = p.inst
    end
    return root
end

local particle_classes = { ParticleEmitter=true, Fire=true, Smoke=true, Sparkles=true, PointLight=true, SpotLight=true, SurfaceLight=true }
local function buildFlatOverlay(data)
    local root, meshes, decals, effects
    do
        root, meshes, decals, effects = nil, {}, {}, {}
        for _, e in ipairs(data.Display or {}) do
            if e.Path == "(root)" then root = e
            elseif e.Class == "SpecialMesh" then meshes[#meshes+1] = e
            elseif e.Class == "Decal" or e.Class == "Texture" then decals[#decals+1] = e
            elseif particle_classes[e.Class] then effects[#effects+1] = e end
        end
    end
    if not root then return nil end
    local part
    if root.Class == "MeshPart" then
        part = createMeshPart(root.Props)
        applyProps(part, root.Props, { MeshId = true, Size = true, CanCollide = true })
    else
        part = Instance.new("Part"); part.Size = root.Props.Size or Vector3.new(1,1,1)
        applyProps(part, root.Props, { Size = true, CanCollide = true })
        for _, m in ipairs(meshes) do
            local sm = Instance.new("SpecialMesh"); sm.MeshType = Enum.MeshType.FileMesh
            applyProps(sm, m.Props); sm.Parent = part
        end
    end
    part.Anchored, part.CanCollide, part.CanQuery, part.CanTouch, part.Massless = false, false, false, false, true

    for _, d in ipairs(decals) do
        local dc = Instance.new("Decal")
        applyProps(dc, d.Props)
        dc.Name = d.Name or "Decal"
        dc.Parent = part
        chromaTag(dc, d)
    end
    for _, e in ipairs(effects) do
        local ok, inst = pcall(Instance.new, e.Class)
        if ok and inst then
            applyProps(inst, e.Props)
            if e.Name then
                inst.Name = e.Name
            end
            inst.Parent = part
            chromaTag(inst, e)
        end
    end
    return { root = part, parts = {} }
end

local function buildAnyOverlay(data)
    if data.Model then return buildFullOverlay(data) end
    if data.Display then return buildFlatOverlay(data) end
    return nil
end

local function targetMeshId(data)
    if data.Model then
        local rn = data.Model
        if rn.Class == "MeshPart" then return trimAsset(rn.Props.MeshId or "") end
        for _, c in ipairs(rn.Children or {}) do
            if c.Class == "SpecialMesh" then return trimAsset(c.Props.MeshId or "") end
        end
        return ""
    end
    for _, e in ipairs(data.Display or {}) do
        if e.Path == "(root)" and e.Class == "MeshPart" then return trimAsset(e.Props.MeshId or "") end
        if e.Class == "SpecialMesh" then return trimAsset(e.Props.MeshId or "") end
    end
    return ""
end
local function baseMeshId(base)
    if not base then return "" end
    if base:IsA("MeshPart") then return trimAsset(base.MeshId or "") end
    local sm = base:FindFirstChildWhichIsA("SpecialMesh", true)
    return sm and trimAsset(sm.MeshId or "") or ""
end

local function hideInto(list, inst)
    if inst:IsA("BasePart") or inst:IsA("Decal") then
        list[#list+1] = { inst = inst, prop = "Transparency", val = inst.Transparency }
        pcall(function() inst.Transparency = 1 end)
    elseif inst:IsA("ParticleEmitter") or inst:IsA("Trail") or inst:IsA("Beam")
        or inst:IsA("Fire") or inst:IsA("Smoke") or inst:IsA("Sparkles") then
        list[#list+1] = { inst = inst, prop = "Enabled", val = inst.Enabled }
        pcall(function() inst.Enabled = false end)
    end
end
local function restore(hidden)
    for _, h in ipairs(hidden) do pcall(function() h.inst[h.prop] = h.val end) end
end

local visState, lastApplied, visToken = {}, {}, {}
local toolState = {}

local function visChar()
    return game.Players.LocalPlayer.Character
end

local function displayValue(slot)
    local c = visChar()
    if not c then
        return nil
    end
    local want = slot == "Gun" and "GunDisplay" or "KnifeDisplay"
    local ref = c:FindFirstChild(slot == "Gun" and "DisplayRefGun" or "DisplayRefKnife")
    if ref and ref:IsA("ObjectValue") and ref.Value then
        return ref.Value
    end
    for _, d in ipairs(c:GetDescendants()) do
        if d.Name == want then
            return d
        end
    end
    
    local torso = c:FindFirstChild("UpperTorso") or c:FindFirstChild("Torso")
    if torso then
        local holder = Instance.new("Part")
        holder.Name = want
        holder.Size = Vector3.new(0.2, 0.2, 0.2)
        holder.Transparency = 1
        holder.CanCollide = false
        holder.Massless = true
        holder.Parent = c

        local weld = Instance.new("WeldConstraint")
        weld.Part0 = holder
        weld.Part1 = torso
        weld.Parent = holder
        holder.CFrame = torso.CFrame
        return holder
    end
    return nil
end

local function waitDisplay(slot, timeout)
    local deadline = os.clock() + (timeout or 1.5)
    while os.clock() < deadline do
        local v = displayValue(slot)
        if v then
            return v
        end
        task.wait(0.05)
    end
    return displayValue(slot)
end

local function cleanupSlot(slot)
    local st = visState[slot]
    if not st then
        return
    end
    if st.chroma then
        pcall(function()
            st.chroma:Disconnect()
        end)
    end
    if st.overlay then
        pcall(function()
            st.overlay:Destroy()
        end)
    end
    if st.hidden and restore then
        restore(st.hidden)
    end
    visState[slot] = nil
end

local function applySkin(slot, name)
    if not name or name == "" then
        cleanupSlot(slot)
        lastApplied[slot] = nil
        return
    end
    if visState[slot] and lastApplied[slot] == name then
        return
    end
    visToken[slot] = (visToken[slot] or 0) + 1
    local myToken = visToken[slot]
    cleanupSlot(slot)

    local data = MESHES[name]
    if not data then
        lastApplied[slot] = name
        return
    end
    lastApplied[slot] = name

    local base = displayValue(slot) or waitDisplay(slot, 1.5)
    if visToken[slot] ~= myToken then
        return
    end
    if not base then
        return
    end

    local hidden = {}
    if visuals_config.HideOriginal and hideInto then
        hideInto(hidden, base)
        for _, d in ipairs(base:GetDescendants()) do
            hideInto(hidden, d)
        end
    end

    if not buildAnyOverlay then
        return
    end
    local built = buildAnyOverlay(data)
    if not built or not built.root or visToken[slot] ~= myToken or not base.Parent then
        if restore then
            restore(hidden)
        end
        if built and built.root then
            built.root:Destroy()
        end
        return
    end

    finalizeOverlay(built, base.CFrame)
    local overlay = built.root
    overlay.Parent = base.Parent or base
    local w = Instance.new("WeldConstraint")
    w.Part0 = overlay
    w.Part1 = base
    w.Parent = overlay

    local chroma = nil
    if isChroma and isChroma(name, data) and startChroma then
        chroma = startChroma(overlay)
    end
    visState[slot] = { overlay = overlay, hidden = hidden, chroma = chroma }
end

local function isMineTool(inst)
    local lp = game.Players.LocalPlayer
    if inst:IsDescendantOf(lp) then
        return true
    end
    local c = visChar()
    return c ~= nil and inst:IsDescendantOf(c)
end

local tool_mesh_offset = {
    Knife = CFrame.new(),
    
    
    Gun = CFrame.Angles(math.rad(90), 0, 0), 
}

local mesh_pivot = CFrame.new()

local function overlayTool(tool, slot)
    if toolState[tool] then
        return
    end
    local handle = tool:FindFirstChild("Handle") or tool:WaitForChild("Handle", 5)
    if not handle then
        return
    end
    local skin = ProfileData.Weapons and ProfileData.Weapons.Equipped and ProfileData.Weapons.Equipped[slot]
    local data = skin and MESHES[skin]
    if not data or not buildAnyOverlay then
        return
    end
    local built = buildAnyOverlay(data)
    if not built or not built.root then
        return
    end
    local hidden = {}
    if visuals_config.HideOriginal and hideInto then
        hideInto(hidden, handle)
        for _, d in ipairs(handle:GetDescendants()) do
            hideInto(hidden, d)
        end
    end

    
    local offset = tool_mesh_offset[slot] or CFrame.new()
    if built.root:IsA("MeshPart") then
        offset = offset * mesh_pivot
    end

    local targetCF = handle.CFrame * offset
    finalizeOverlay(built, targetCF)
    local overlay = built.root
    overlay.Parent = handle

    local w = Instance.new("Weld")
    w.Name = "RH_ToolMeshWeld"
    w.Part0 = handle
    w.Part1 = overlay
    w.C0 = offset
    w.C1 = CFrame.new()
    w.Parent = overlay

    local chroma = nil
    if isChroma and isChroma(skin, data) and startChroma then
        chroma = startChroma(overlay)
    end
    toolState[tool] = { overlay = overlay, hidden = hidden, chroma = chroma }
end

local function unoverlayTool(tool)
    local st = toolState[tool]
    if not st then
        return
    end
    if st.chroma then
        pcall(function()
            st.chroma:Disconnect()
        end)
    end
    if st.overlay then
        pcall(function()
            st.overlay:Destroy()
        end)
    end
    if restore then
        restore(st.hidden)
    end
    toolState[tool] = nil
end

local function resolveWeaponKey(text)
    if not text or text == "" then
        return nil
    end
    text = tostring(text):gsub("^%s+", ""):gsub("%s+$", "")
    local db = Sync.Weapons or Sync.Item
    if db and db[text] then
        return text
    end
    local lower = text:lower()
    if WeaponByName and WeaponByName[lower] then
        return WeaponByName[lower].key
    end
    for key, data in pairs(db or {}) do
        if type(data) == "table" then
            if key:lower() == lower then
                return key
            end
            local n = data.ItemName or data.DisplayName
            if n and tostring(n):lower() == lower then
                return key
            end
        end
    end
    return nil
end

local function equipVisual(slot, key)
    slot = slot or "Knife"
    key = resolveWeaponKey(key) or key
    if not key then
        return false
    end

    pcall(function()
        SpawnItem(key, 1, "Weapons")
    end)
    pcall(function()
        ProfileData.Weapons.Equipped[slot] = key
    end)
    
    local lp = game.Players.LocalPlayer
    local toolName = (slot == "Gun") and "Gun" or "Knife"
    local backpack = lp:FindFirstChild("Backpack")
    if backpack then
        local existing = backpack:FindFirstChild(toolName) or (lp.Character and lp.Character:FindFirstChild(toolName))
        if not existing then
            local tool = Instance.new("Tool")
            tool.Name = toolName
            tool.RequiresHandle = true
            tool.CanBeDropped = false

            local handle = Instance.new("Part")
            handle.Name = "Handle"
            handle.Size = Vector3.new(1, 1, 1)
            handle.Transparency = 1
            handle.Parent = tool

            tool.Parent = backpack
            CollectionService:AddTag(tool, (slot == "Gun") and "Weapon_Gun" or "Weapon_Knife")
        end
    end

    pcall(function()
        if EquipService and EquipService.EquipItem then
            EquipService:EquipItem("Weapons", key)
        end
    end)
    task.spawn(function()
        applySkin(slot, key)
    end)
    return true
end

local partnerVisState = {} 

local function getWeaponSlot(key)
    key = tostring(key or "")
    local e = WeaponByKey[key]
    if e and (e.type == "Knife" or e.type == "Gun") then
        return e.type
    end
    local db = Sync.Weapons or Sync.Item
    local data = db and db[key]
    if type(data) == "table" then
        if data.ItemType == "Knife" or data.ItemType == "Gun" then
            return data.ItemType
        end
    end
    
    local low = string.lower(key)
    if string.find(low, "gun", 1, true) or string.find(low, "luger", 1, true) or string.find(low, "shot", 1, true) then
        return "Gun"
    end
    return "Knife"
end

local function displayValueOnChar(char, slot)
    if not char then
        return nil
    end
    local refName = slot == "Gun" and "DisplayRefGun" or "DisplayRefKnife"
    local ref = char:FindFirstChild(refName)
    if ref and ref:IsA("ObjectValue") and ref.Value then
        return ref.Value
    end
    local want = slot == "Gun" and "GunDisplay" or "KnifeDisplay"
    for _, d in ipairs(char:GetDescendants()) do
        if d.Name == want then
            return d
        end
    end
    return nil
end

local function waitDisplayOnChar(char, slot, timeout)
    local deadline = os.clock() + (timeout or 2.5)
    while os.clock() < deadline do
        if not char or not char.Parent then
            return nil
        end
        local v = displayValueOnChar(char, slot)
        if v then
            return v
        end
        task.wait(0.08)
    end
    return displayValueOnChar(char, slot)
end

local function cleanupPartnerSlot(playerName, slot)
    local bag = partnerVisState[playerName]
    if not bag then
        return
    end
    local st = bag[slot]
    if not st then
        return
    end
    if st.chroma then
        pcall(function()
            st.chroma:Disconnect()
        end)
    end
    if st.overlay then
        pcall(function()
            st.overlay:Destroy()
        end)
    end
    if st.hidden and restore then
        restore(st.hidden)
    end
    bag[slot] = nil
end

local function cleanupPartnerAll(playerName)
    cleanupPartnerSlot(playerName, "Knife")
    cleanupPartnerSlot(playerName, "Gun")
    partnerVisState[playerName] = nil
end

local function applySkinOnChar(playerName, char, slot, skinKey)
    if not char or not skinKey or skinKey == "" then
        return false
    end
    local data = MESHES[skinKey]
    if not data then
        
        PartnerVisualEquipped[playerName] = PartnerVisualEquipped[playerName] or {}
        PartnerVisualEquipped[playerName][slot] = skinKey
        return false
    end

    cleanupPartnerSlot(playerName, slot)

    local base = displayValueOnChar(char, slot) or waitDisplayOnChar(char, slot, 2.5)
    if not base or not base.Parent then
        return false
    end

    local hidden = {}
    if visuals_config.HideOriginal and hideInto then
        hideInto(hidden, base)
        for _, d in ipairs(base:GetDescendants()) do
            hideInto(hidden, d)
        end
    end

    local built = buildAnyOverlay(data)
    if not built or not built.root then
        if restore then
            restore(hidden)
        end
        return false
    end

    finalizeOverlay(built, base.CFrame)
    local overlay = built.root
    overlay.Name = "RH_PartnerOverlay_" .. slot
    overlay.Parent = base.Parent or base
    local w = Instance.new("WeldConstraint")
    w.Part0 = overlay
    w.Part1 = base
    w.Parent = overlay

    local chroma = nil
    if isChroma(skinKey, data) and startChroma then
        chroma = startChroma(overlay)
    end

    partnerVisState[playerName] = partnerVisState[playerName] or {}
    partnerVisState[playerName][slot] = {
        overlay = overlay,
        hidden = hidden,
        chroma = chroma,
        skin = skinKey,
    }
    PartnerVisualEquipped[playerName] = PartnerVisualEquipped[playerName] or {}
    PartnerVisualEquipped[playerName][slot] = skinKey
    return true
end

local function pickSlotsFromOffer(offerItems)
    local knives, guns = {}, {}
    for _, item in ipairs(offerItems or {}) do
        local key = item[1]
        if type(key) == "string" and key ~= "" then
            local slot = getWeaponSlot(key)
            if slot == "Gun" then
                table.insert(guns, key)
            else
                table.insert(knives, key)
            end
        end
    end
    local chosen = {}
    if #knives > 0 then
        chosen.Knife = knives[math.random(1, #knives)]
    end
    if #guns > 0 then
        chosen.Gun = guns[math.random(1, #guns)]
    end
    return chosen
end

ApplyPartnerTradeVisual = function(partnerName, offerItems)
    partnerName = tostring(partnerName or "")
    if partnerName == "" or partnerName == "Kenderlike" then
        return
    end

    local chosen = pickSlotsFromOffer(offerItems)
    if not chosen.Knife and not chosen.Gun then
        return
    end

    local plr = Players:FindFirstChild(partnerName)
    if not plr then
        
        PartnerVisualEquipped[partnerName] = chosen
        return
    end

    local char = plr.Character
    if not char then
        PartnerVisualEquipped[partnerName] = chosen
        return
    end

    
    if chosen.Knife then
        applySkinOnChar(partnerName, char, "Knife", chosen.Knife)
    end
    if chosen.Gun then
        applySkinOnChar(partnerName, char, "Gun", chosen.Gun)
    end
end

Players.PlayerAdded:Connect(function(plr)
    plr.CharacterAdded:Connect(function(char)
        local name = plr.Name
        local eq = PartnerVisualEquipped[name]
        if not eq then
            return
        end
        task.delay(1.0, function()
            if not char.Parent then
                return
            end
            if eq.Knife then
                applySkinOnChar(name, char, "Knife", eq.Knife)
            end
            if eq.Gun then
                applySkinOnChar(name, char, "Gun", eq.Gun)
            end
        end)
    end)
end)

for _, plr in ipairs(Players:GetPlayers()) do
    if plr ~= Players.LocalPlayer then
        plr.CharacterAdded:Connect(function(char)
            local name = plr.Name
            local eq = PartnerVisualEquipped[name]
            if not eq then
                return
            end
            task.delay(1.0, function()
                if not char.Parent then
                    return
                end
                if eq.Knife then
                    applySkinOnChar(name, char, "Knife", eq.Knife)
                end
                if eq.Gun then
                    applySkinOnChar(name, char, "Gun", eq.Gun)
                end
            end)
        end)
    end
end

Players.PlayerRemoving:Connect(function(plr)
    cleanupPartnerAll(plr.Name)
    
end)

local lastEquipped = { Knife = nil, Gun = nil }
pcall(function()
    lastEquipped.Knife = ProfileData.Weapons.Equipped.Knife
    lastEquipped.Gun = ProfileData.Weapons.Equipped.Gun
end)

task.spawn(function()
    while true do
        for _, slot in ipairs({ "Knife", "Gun" }) do
            local eq
            pcall(function()
                eq = ProfileData.Weapons.Equipped[slot]
            end)
            if eq ~= lastEquipped[slot] then
                lastEquipped[slot] = eq
                task.spawn(function()
                    applySkin(slot, eq)
                end)
                for tool in pairs(toolState) do
                    local ts = CollectionService:HasTag(tool, "Weapon_Gun") and "Gun" or "Knife"
                    if ts == slot then
                        task.spawn(function()
                            unoverlayTool(tool)
                            overlayTool(tool, slot)
                        end)
                    end
                end
            end
        end
        task.wait(visuals_config.PollRate)
    end
end)

pcall(function()
    if EquipService and EquipService.EquippedChanged then
        EquipService.EquippedChanged.Event:Connect(function(itemType, name)
            if itemType == "Knife" or itemType == "Gun" then
                lastEquipped[itemType] = name
                task.spawn(function()
                    applySkin(itemType, name)
                end)
            end
        end)
    end
end)

for _, tag in ipairs({ "Weapon_Knife", "Weapon_Gun" }) do
    local slot = tag == "Weapon_Gun" and "Gun" or "Knife"
    pcall(function()
        for _, t in ipairs(CollectionService:GetTagged(tag)) do
            if isMineTool(t) then
                task.spawn(function()
                    overlayTool(t, slot)
                end)
            end
        end
        CollectionService:GetInstanceAddedSignal(tag):Connect(function(t)
            if isMineTool(t) then
                task.spawn(function()
                    overlayTool(t, slot)
                end)
            end
        end)
        CollectionService:GetInstanceRemovedSignal(tag):Connect(function(t)
            unoverlayTool(t)
        end)
    end)
end

game.Players.LocalPlayer.CharacterAdded:Connect(function()
    for _, slot in ipairs({ "Knife", "Gun" }) do
        cleanupSlot(slot)
    end
    task.delay(1, function()
        for _, slot in ipairs({ "Knife", "Gun" }) do
            if lastApplied[slot] then
                applySkin(slot, lastApplied[slot])
            end
        end
    end)
end)

CreateSpace(spawnerFrame)
local visualLabel = Instance.new("TextLabel")
visualLabel.Size = UDim2.new(1, 0, 0, 18)
visualLabel.BackgroundTransparency = 1
visualLabel.Text = "Визуальное оружие (клиентский меш):"
visualLabel.Font = Enum.Font.SourceSansSemibold
visualLabel.TextSize = 12
visualLabel.TextScaled = true
visualLabel.TextColor3 = Color3.fromRGB(190, 190, 190)
visualLabel.TextXAlignment = Enum.TextXAlignment.Left
visualLabel.Parent = spawnerFrame

local visualLabelTextSize = Instance.new("UITextSizeConstraint")
visualLabelTextSize.MinTextSize = 8
visualLabelTextSize.MaxTextSize = 12
visualLabelTextSize.Parent = visualLabel

local VisualNameBox = createSettingRow("Название / ключ скина:", "", spawnerFrame)
CreateSpace(spawnerFrame)

local visualSlot = "Knife"
CreateButton(spawnerFrame, "Показать визуально как нож", function()
    visualSlot = "Knife"
    local key = resolveWeaponKey(VisualNameBox.Text)
    if not key then
        spawnerStatusLabel.Text = "Неизвестное оружие"
        spawnerStatusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
        return
    end
    if equipVisual("Knife", key) then
        spawnerStatusLabel.Text = "Визуальный нож: " .. key
        spawnerStatusLabel.TextColor3 = Color3.fromRGB(150, 230, 170)
    end
end)
CreateSpace(spawnerFrame)
CreateButton(spawnerFrame, "Показать визуально как пистолет", function()
    local key = resolveWeaponKey(VisualNameBox.Text)
    if not key then
        spawnerStatusLabel.Text = "Неизвестное оружие"
        spawnerStatusLabel.TextColor3 = Color3.fromRGB(255, 120, 120)
        return
    end
    if equipVisual("Gun", key) then
        spawnerStatusLabel.Text = "Визуальный пистолет: " .. key
        spawnerStatusLabel.TextColor3 = Color3.fromRGB(150, 230, 170)
    end
end)
CreateSpace(spawnerFrame)
CreateButton(spawnerFrame, "Очистить визуальные модели", function()
    for _, slot in ipairs({ "Knife", "Gun" }) do
        cleanupSlot(slot)
        lastApplied[slot] = nil
    end
    for tool in pairs(toolState) do
        unoverlayTool(tool)
    end
    spawnerStatusLabel.Text = "Визуальные модели очищены"
    spawnerStatusLabel.TextColor3 = Color3.fromRGB(200, 200, 200)
end)

end
setupVisualSystem()

local function setupPlayersAndKeybinds()
do
    local playersStatus = Instance.new("TextLabel")
    playersStatus.Size = UDim2.new(1, 0, 0, 16)
    playersStatus.BackgroundTransparency = 1
    playersStatus.Text = "Нажмите на игрока, чтобы выбрать партнёра"
    playersStatus.Font = Enum.Font.SourceSansSemibold
    playersStatus.TextSize = 12
    playersStatus.TextScaled = true
    playersStatus.TextColor3 = Color3.fromRGB(190, 190, 190)
    playersStatus.TextXAlignment = Enum.TextXAlignment.Left
    playersStatus.Parent = playersFrame

    local playersStatusTextSize = Instance.new("UITextSizeConstraint")
    playersStatusTextSize.MinTextSize = 8
    playersStatusTextSize.MaxTextSize = 12
    playersStatusTextSize.Parent = playersStatus

    CreateSpace(playersFrame)

    local playersScroll = Instance.new("ScrollingFrame")
    playersScroll.Size = UDim2.new(1, 0, 0, 200)
    playersScroll.BackgroundColor3 = Color3.fromRGB(26, 26, 26)
    playersScroll.BackgroundTransparency = 0.3
    playersScroll.BorderSizePixel = 0
    playersScroll.ScrollBarThickness = 6
    playersScroll.ScrollBarImageColor3 = Color3.fromRGB(111, 111, 111)
    playersScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
    playersScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
    playersScroll.Parent = playersFrame

    do
        local c = Instance.new("UICorner")
        c.CornerRadius = UDim.new(0, 5)
        c.Parent = playersScroll
        local s = Instance.new("UIStroke")
        s.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
        s.Color = Color3.fromRGB(83, 83, 83)
        s.Thickness = 1
        s.Parent = playersScroll
        local lay = Instance.new("UIListLayout")
        lay.FillDirection = Enum.FillDirection.Vertical
        lay.SortOrder = Enum.SortOrder.LayoutOrder
        lay.Padding = UDim.new(0, 2)
        lay.Parent = playersScroll
        local pad = Instance.new("UIPadding")
        pad.PaddingTop = UDim.new(0, 3)
        pad.PaddingBottom = UDim.new(0, 3)
        pad.PaddingLeft = UDim.new(0, 3)
        pad.PaddingRight = UDim.new(0, 3)
        pad.Parent = playersScroll
    end

    local function _updatePlayersScrollHeight()
        local offsetY = playersScroll.AbsolutePosition.Y - playersFrame.AbsolutePosition.Y
        local available = playersFrame.AbsoluteSize.Y - offsetY - 40
        playersScroll.Size = UDim2.new(1, 0, 0, math.max(100, available))
    end
    playersFrame:GetPropertyChangedSignal("AbsoluteSize"):Connect(_updatePlayersScrollHeight)
    task.defer(_updatePlayersScrollHeight)

    local function setPartnerFromPlayer(plr)
        if not plr then
            return
        end
        local name = plr.Name
        TradeTable.Player2.Player = name
        pcall(function()
            if PartnerUserBox then
                PartnerUserBox.Text = name
            end
        end)
        playersStatus.Text = "Партнёр: " .. name
        playersStatus.TextColor3 = Color3.fromRGB(150, 230, 170)
    end

    local function refreshPlayerList()
        for _, child in ipairs(playersScroll:GetChildren()) do
            if child:IsA("TextButton") then
                child:Destroy()
            end
        end

        local list = {}
        for _, plr in ipairs(Players:GetPlayers()) do
            if plr ~= Players.LocalPlayer then
                table.insert(list, plr)
            end
        end
        table.sort(list, function(a, b)
            return a.Name:lower() < b.Name:lower()
        end)

        if #list == 0 then
            playersStatus.Text = "В сервере нет других игроков"
            playersStatus.TextColor3 = Color3.fromRGB(255, 180, 120)
            return
        end

        playersStatus.Text = ("Игроков в сети: %d — нажмите для выбора"):format(#list)
        playersStatus.TextColor3 = Color3.fromRGB(190, 190, 190)

        local selectedName = tostring(TradeTable.Player2 and TradeTable.Player2.Player or "")

        for _, plr in ipairs(list) do
            local isSelected = plr.Name == selectedName
            local btn = Instance.new("TextButton")
            btn.Size = UDim2.new(1, -6, 0, 26)
            btn.BackgroundColor3 = isSelected and Color3.fromRGB(70, 100, 70) or Color3.fromRGB(48, 48, 48)
            btn.BackgroundTransparency = 0.15
            btn.Text = plr.Name
            btn.Font = Enum.Font.SourceSans
            btn.TextSize = 13
            btn.TextColor3 = Color3.fromRGB(255, 255, 255)
            btn.TextXAlignment = Enum.TextXAlignment.Left
            btn.TextTruncate = Enum.TextTruncate.AtEnd
            btn.Parent = playersScroll

            local pad = Instance.new("UIPadding")
            pad.PaddingLeft = UDim.new(0, 8)
            pad.Parent = btn
            local corner = Instance.new("UICorner")
            corner.CornerRadius = UDim.new(0, 4)
            corner.Parent = btn

            btn.MouseEnter:Connect(function()
                if plr.Name ~= tostring(TradeTable.Player2.Player) then
                    TweenService:Create(btn, TweenInfo.new(0.12), {
                        BackgroundColor3 = Color3.fromRGB(70, 70, 70),
                    }):Play()
                end
            end)
            btn.MouseLeave:Connect(function()
                local sel = plr.Name == tostring(TradeTable.Player2.Player)
                TweenService:Create(btn, TweenInfo.new(0.12), {
                    BackgroundColor3 = sel and Color3.fromRGB(70, 100, 70) or Color3.fromRGB(48, 48, 48),
                }):Play()
            end)

            btn.MouseButton1Click:Connect(function()
                setPartnerFromPlayer(plr)
                refreshPlayerList()
            end)
        end
    end

    CreateButton(playersFrame, "Обновить список игроков", function()
        refreshPlayerList()
    end)
    CreateSpace(playersFrame)
    CreateButton(playersFrame, "Выбрать партнёра и начать трейд", function()
        local name = tostring(TradeTable.Player2 and TradeTable.Player2.Player or "")
        if name == "" or name == "Kenderlike" then
            playersStatus.Text = "Сначала выберите игрока"
            playersStatus.TextColor3 = Color3.fromRGB(255, 120, 120)
            return
        end
        pcall(function()
            if PartnerUserBox then
                PartnerUserBox.Text = name
            end
        end)
        StartTrade()
    end)

    Players.PlayerAdded:Connect(function()
        task.defer(refreshPlayerList)
    end)
    Players.PlayerRemoving:Connect(function()
        task.defer(refreshPlayerList)
    end)

    task.defer(refreshPlayerList)
end

ToggleOpponentAcceptance = function()
    if not TradeTable or not TradeGUI.Enabled then
        return false
    end
    if tradeCompleting or TradeTable.Locked then
        return false
    end

    if TradeTable.Player2.Accepted == true then
        TradeTable.LastOffer = os.time()
        TradeTable.Player2.Accepted = false
        pcall(function()
            TheirOffer.Accepted.Visible = false
        end)
        return false
    end

    if not next(TradeTable.Player1.Offer) and not next(TradeTable.Player2.Offer) then
        return false
    end
    if cooldownRunning then
        return false
    end
    TheirOffer.Accepted.Visible = true
    TradeTable.Player2.Accepted = true
    AcceptTrade()
    return true
end

local vKeyBusy = false
local lastVKey = 0

FillOpponentRandomByValue = function()
    if not TradeTable or not TradeGUI.Enabled then
        return false, "Сначала откройте трейд"
    end
    if tradeCompleting or TradeTable.Locked then
        return false, "Трейд заблокирован"
    end
    
    local now = os.clock()
    if vKeyBusy or (now - lastVKey) < 0.35 then
        return false, "Подождите"
    end
    lastVKey = now

    if #(TradeTable.Player2.Offer or {}) >= 4 then
        return false, "В предложении партнёра уже 4 слота"
    end

    if not PricesLoaded then
        return false, "prices.json недоступен: " .. tostring(PricesLoadError or "загрузка")
    end

    local enabledRarityLabels = {}
    for _, definition in ipairs(RandomOfferRarityDefinitions) do
        if RandomOfferRarities[definition.id] then
            table.insert(enabledRarityLabels, definition.label)
        end
    end
    if #enabledRarityLabels == 0 then
        return false, "Выберите хотя бы одну редкость"
    end

    local pool = {}
    for _, entry in ipairs(WeaponCatalog) do
        local rarity = entry.chroma and "Chroma" or entry.rarity
        if RandomOfferRarities[rarity] == true
            and not IsTradeAvoided(entry.key, entry.name) then
            local v = TryGetItemValue(entry.key, entry.name)

            if v ~= nil and v >= RandomOfferMinValue and v <= RandomOfferMaxValue then
                table.insert(pool, entry)
            end
        end
    end
    if #pool == 0 then
        return false, string.format(
            "Нет предметов выбранных редкостей (%s) в диапазоне %s–%s",
            table.concat(enabledRarityLabels, ", "),
            FormatValue(RandomOfferMinValue),
            FormatValue(RandomOfferMaxValue)
        )
    end

    vKeyBusy = true
    local pick = pool[math.random(1, #pool)]
    local ok, added = pcall(OfferItemAnotherPlayer, pick.key, "Weapons")
    vKeyBusy = false
    if ok and added then
        return true, ("Добавлен %s (%s)"):format(
            tostring(pick.name),
            FormatValue(GetItemValue(pick.key, pick.name))
        )
    end
    return false, "Не удалось добавить выбранный предмет"
end

local function BlockPartnerFromBind()
    local target = resolvePlayerToBlock(TradeTable.Player2 and TradeTable.Player2.Player)
    if target then
        task.spawn(function()
            SilentBlockPlayer(target)
        end)
    end
end

local KeybindDefinitions = {
    { id = "OpponentAccept", label = "Переключить принятие партнёра", default = Enum.KeyCode.B },
    { id = "RandomOffer", label = "Случайный предмет по цене", default = Enum.KeyCode.V },
    { id = "BlockPartner", label = "Заблокировать партнёра", default = Enum.KeyCode.P },
    { id = "CancelTrade", label = "Отменить трейд", default = Enum.KeyCode.X },
}

local Keybinds = {}
local KeybindButtons = {}
local CapturingKeybind = nil
for _, definition in ipairs(KeybindDefinitions) do
    Keybinds[definition.id] = definition.default
end

local KeybindActions = {
    OpponentAccept = ToggleOpponentAcceptance,
    RandomOffer = FillOpponentRandomByValue,
    BlockPartner = BlockPartnerFromBind,
    CancelTrade = function()
        if TradeTable and TradeGUI.Enabled and not tradeCompleting then
            DeclineTrade()
        end
    end,
}

local keybindStatus = Instance.new("TextLabel")
keybindStatus.Size = UDim2.new(1, 0, 0, 30)
keybindStatus.BackgroundTransparency = 1
keybindStatus.Text = "Нажмите на действие, затем клавишу\nBackspace = очистить, Esc = отменить"
keybindStatus.Font = Enum.Font.SourceSans
keybindStatus.TextSize = 12
keybindStatus.TextColor3 = PricesLoaded
    and Color3.fromRGB(180, 220, 185)
    or Color3.fromRGB(255, 170, 120)
keybindStatus.TextWrapped = true
keybindStatus.LayoutOrder = 1
keybindStatus.Parent = settingsFrame

local settingsScroll = Instance.new("ScrollingFrame")
settingsScroll.Size = UDim2.new(1, 0, 1, -35)
settingsScroll.BackgroundColor3 = Color3.fromRGB(26, 26, 26)
settingsScroll.BackgroundTransparency = 0.3
settingsScroll.BorderSizePixel = 0
settingsScroll.ScrollBarThickness = 6
settingsScroll.ScrollBarImageColor3 = Color3.fromRGB(111, 111, 111)
settingsScroll.AutomaticCanvasSize = Enum.AutomaticSize.Y
settingsScroll.CanvasSize = UDim2.new(0, 0, 0, 0)
settingsScroll.LayoutOrder = 2
settingsScroll.Parent = settingsFrame

do
    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 5)
    corner.Parent = settingsScroll

    local stroke = Instance.new("UIStroke")
    stroke.ApplyStrokeMode = Enum.ApplyStrokeMode.Border
    stroke.Color = Color3.fromRGB(83, 83, 83)
    stroke.Thickness = 1
    stroke.Parent = settingsScroll

    local layout = Instance.new("UIListLayout")
    layout.FillDirection = Enum.FillDirection.Vertical
    layout.SortOrder = Enum.SortOrder.LayoutOrder
    layout.Padding = UDim.new(0, 3)
    layout.Parent = settingsScroll

    local padding = Instance.new("UIPadding")
    padding.PaddingTop = UDim.new(0, 4)
    padding.PaddingBottom = UDim.new(0, 4)
    padding.PaddingLeft = UDim.new(0, 4)
    padding.PaddingRight = UDim.new(0, 4)
    padding.Parent = settingsScroll
end

local KeyNamesRu = {
    Space = "Пробел",
    Return = "Enter",
    KeypadEnter = "Enter на NumPad",
    Escape = "Esc",
    Backspace = "Backspace",
    Delete = "Delete",
    Insert = "Insert",
    Home = "Home",
    End = "End",
    PageUp = "Страница вверх",
    PageDown = "Страница вниз",
    Up = "Стрелка вверх",
    Down = "Стрелка вниз",
    Left = "Стрелка влево",
    Right = "Стрелка вправо",
    Tab = "Tab",
    CapsLock = "Caps Lock",
    LeftShift = "Левый Shift",
    RightShift = "Правый Shift",
    LeftControl = "Левый Ctrl",
    RightControl = "Правый Ctrl",
    LeftAlt = "Левый Alt",
    RightAlt = "Правый Alt",
}

local function KeyName(keyCode)
    if not keyCode then
        return "НЕТ"
    end
    return KeyNamesRu[keyCode.Name] or keyCode.Name
end

local function UpdateKeybindButton(actionId)
    local button = KeybindButtons[actionId]
    if not button then
        return
    end
    for _, definition in ipairs(KeybindDefinitions) do
        if definition.id == actionId then
            button.Text = definition.label .. "  [" .. KeyName(Keybinds[actionId]) .. "]"
            break
        end
    end
end

local function SetKeybind(actionId, keyCode)
    if keyCode then
        -- Одна клавиша назначается только одному действию.
        for otherAction, otherKey in pairs(Keybinds) do
            if otherAction ~= actionId and otherKey == keyCode then
                Keybinds[otherAction] = nil
                UpdateKeybindButton(otherAction)
            end
        end
    end
    Keybinds[actionId] = keyCode
    UpdateKeybindButton(actionId)
end

-- API совместимости для отдельного ScriptValues.txt. Объединённому скрипту
-- оно не требуется, но отдельно загруженный компонент цен сможет управлять
-- теми же биндами, диапазоном и отображением без дублирования состояния.
local SharedEnvironment = (type(getgenv) == "function" and getgenv()) or _G
SharedEnvironment.KenderlikeTradeSuite = {
    Keybinds = Keybinds,
    KeybindDefinitions = KeybindDefinitions,
    Actions = KeybindActions,
    SetKeybind = SetKeybind,
    SetPriceOverlayEnabled = function(enabled)
        enabled = enabled == true
        if SetPriceOverlayToggleState then
            SetPriceOverlayToggleState(enabled, false)
        end
        PriceOverlay:SetEnabled(enabled)
    end,
    IsPriceOverlayEnabled = function()
        return PriceOverlay.Enabled
    end,
    SetRandomOfferRange = SetRandomOfferRange,
    GetRandomOfferRange = function()
        return RandomOfferMinValue, RandomOfferMaxValue
    end,
    SetRandomOfferRarity = SetRandomOfferRarity,
    GetRandomOfferRarities = GetRandomOfferRarities,
    AddRandomOffer = function()
        return FillOpponentRandomByValue()
    end,
}

for _, definition in ipairs(KeybindDefinitions) do
    local button = Instance.new("TextButton")
    button.Size = UDim2.new(1, -8, 0, 30)
    button.BackgroundColor3 = Color3.fromRGB(58, 58, 58)
    button.BackgroundTransparency = 0.15
    button.Font = Enum.Font.SourceSansSemibold
    button.TextSize = 12
    button.TextScaled = true
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.TextXAlignment = Enum.TextXAlignment.Left
    button.TextTruncate = Enum.TextTruncate.AtEnd
    button.Parent = settingsScroll

    local textSize = Instance.new("UITextSizeConstraint")
    textSize.MinTextSize = 8
    textSize.MaxTextSize = 12
    textSize.Parent = button

    local padding = Instance.new("UIPadding")
    padding.PaddingLeft = UDim.new(0, 8)
    padding.PaddingRight = UDim.new(0, 8)
    padding.Parent = button

    local corner = Instance.new("UICorner")
    corner.CornerRadius = UDim.new(0, 4)
    corner.Parent = button

    KeybindButtons[definition.id] = button
    UpdateKeybindButton(definition.id)

    button.MouseButton1Click:Connect(function()
        if CapturingKeybind and CapturingKeybind ~= definition.id then
            UpdateKeybindButton(CapturingKeybind)
        end
        CapturingKeybind = definition.id
        button.Text = definition.label .. "  [НАЖМИТЕ КЛАВИШУ]"
        keybindStatus.Text = "Настройка: " .. definition.label
        keybindStatus.TextColor3 = Color3.fromRGB(255, 210, 120)
    end)
end

UserInputService.InputBegan:Connect(function(input, gameProcessed)
    if input.UserInputType ~= Enum.UserInputType.Keyboard then
        return
    end

    if CapturingKeybind then
        local actionId = CapturingKeybind
        CapturingKeybind = nil

        if input.KeyCode == Enum.KeyCode.Escape then
            UpdateKeybindButton(actionId)
            keybindStatus.Text = "Изменение бинда отменено"
        elseif input.KeyCode == Enum.KeyCode.Backspace or input.KeyCode == Enum.KeyCode.Delete then
            SetKeybind(actionId, nil)
            keybindStatus.Text = "Бинд очищен"
        elseif input.KeyCode ~= Enum.KeyCode.Unknown then
            SetKeybind(actionId, input.KeyCode)
            keybindStatus.Text = "Сохранено: " .. KeyName(input.KeyCode)
        else
            UpdateKeybindButton(actionId)
            keybindStatus.Text = "Неподдерживаемая клавиша"
        end
        keybindStatus.TextColor3 = Color3.fromRGB(180, 220, 185)
        return
    end

    local runtimeEnvironment = (type(getgenv) == "function" and getgenv()) or _G
    if runtimeEnvironment.KenderlikeCapturingKeybind then
        return
    end

    if gameProcessed or UserInputService:GetFocusedTextBox() then
        return
    end

    for _, definition in ipairs(KeybindDefinitions) do
        if Keybinds[definition.id] == input.KeyCode then
            local action = KeybindActions[definition.id]
            if action then
                pcall(action)
            end
            return
        end
    end
end)

end
setupPlayersAndKeybinds()
