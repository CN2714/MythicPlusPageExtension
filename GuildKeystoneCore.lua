local ADDON_NAME, mppe = ...

-- ==================================================================
-- 【公会钥石】公共数据中枢 + 名字 / 副本名 / 钥石文本工具
-- 由 GuildAndPartyKS.lua（公会钥石窗口）与 GuildMemberKeystone.lua（公会名单评分页）共用：
--   · 全插件只注册一套 LibKeystone / LibOpenRaid 接收器，只有一份缓存（GuildKS.cache）
--   · 缓存变化时递增“数据纪元”并通知订阅者（GuildKS.Subscribe），订阅者自己决定怎么刷新 UI
--   · 名字归一 / 副本短名 / 副本全名 / 钥石显示文本 也都在这里，避免两边各写一套
-- 职责边界：本模块只管“公会”钥石；队伍钥石属于 Party* 系列（PartyDB / PartySyncService 等）
-- ==================================================================
mppe.GuildKeystoneCore = mppe.GuildKeystoneCore or {}
local GuildKS = mppe.GuildKeystoneCore     -- 本模块自身的短别名（Guild = 公会，避免与 Party* 混淆）

local Translate = mppe.Translate

-- 库引用（用闭包 + pcall 取，库不存在也不报错）
local function tryGetLib(libName)
    local _ok, _lib = pcall(function() return LibStub(libName) end)
    return _ok and _lib or nil
end

local libKeystone = tryGetLib("LibKeystone")
local libOpenRaid = tryGetLib("LibOpenRaid-1.0")

-- 公会钥石缓存：[纯名] = { mapID, level, rating }（全插件唯一的公会钥石数据源）
GuildKS.cache = {}

local DEFAULT_REQUEST_THROTTLE = 30   -- 公会钥石请求默认最小间隔（秒）
local KEYSTONE_TEXT_COLOR = "a335ee"  -- 钥石文本颜色（6 位 RGB，与 GuildAndPartyKS 原格式一致）

-- 钥石文本的三种样式（同一个副本会缓存多份，按需生成）
local TEXT_SHORT = 1        -- 短名、层数与名字之间无空格：「10回响」（名单页钥石列用，列宽有限）
local TEXT_SHORT_SPACE = 2  -- 短名、带空格：「10 回响」
local TEXT_FULL_SPACE = 3   -- 全名、带空格：「10 艾拉-卡拉，回响之城」

local _epoch = 0                -- 数据纪元：任何缓存变化 +1，供订阅者判断“是否需要刷新”
local _subscribers = {}         -- 数据变化订阅者（顺序回调，参数为发生变化的纯名，清空缓存时为 nil）
local _lastRequestTime = 0
local _pureNameCache = {}       -- [全名] = 纯名（记忆化，避免排序 / 刷行时反复 gsub）
local _textCache = {}           -- [mapID * 1000 + level] = { [样式] = 文本 }
local _classFileById = {}       -- [classID] = 职业英文标识（静态信息，按需映射一次）

-- 取纯名（去掉 -Realm 后缀），与 LibKeystone / LibOpenRaid 回调里的名字对齐
-- Ambiguate("short") 对跨服名更准（角色名本身含 "-" 时不会截错），取不到时回退 gsub；结果记忆化
function GuildKS.PureName(fullName)
    if type(fullName) ~= "string" or fullName == "" then return nil end

    local _cached = _pureNameCache[fullName]
    if _cached then return _cached end

    local _pureName = (Ambiguate and Ambiguate(fullName, "short")) or (fullName:gsub("^([^-]+)%-?.*", "%1"))
    _pureNameCache[fullName] = _pureName
    return _pureName
end

-- 取职业英文标识（classFile）：名单行只给 classID，这里做一次映射（静态信息，缓存起来）
function GuildKS.ClassFileByID(classID)
    if type(classID) ~= "number" then return nil end

    local _cached = _classFileById[classID]
    if _cached then return _cached end

    local _info = C_CreatureInfo and C_CreatureInfo.GetClassInfo(classID)
    local _classFile = _info and _info.classFile
    _classFileById[classID] = _classFile
    return _classFile
end

-- 取某人的钥石数据（无数据返回 nil）
function GuildKS.Get(pureName)
    if not pureName then return nil end
    return GuildKS.cache[pureName]
end

-- 取某人的钥石等级（0 = 无数据，排序时排最后）
function GuildKS.GetLevel(pureName)
    local _data = GuildKS.Get(pureName)
    return (_data and _data.level) or 0
end

-- 数据纪元（订阅者可用它判断数据是否变过）
function GuildKS.Epoch()
    return _epoch
end

-- 订阅数据变化：callback(pureName)；同一函数只注册一次
function GuildKS.Subscribe(callback)
    if type(callback) ~= "function" then return end

    for _index = 1, #_subscribers do
        if _subscribers[_index] == callback then return end
    end

    _subscribers[#_subscribers + 1] = callback
end

-- 写入缓存（仅数据实际变化才更新）：递增纪元并通知订阅者
function GuildKS.Ingest(pureName, mapID, level, rating)
    if not pureName or pureName == "" then return end
    if not (mapID and mapID > 0 and level and level > 0) then return end

    local _rating = rating or 0
    local _old = GuildKS.cache[pureName]
    if _old and _old.mapID == mapID and _old.level == level and _old.rating == _rating then return end

    GuildKS.cache[pureName] = { mapID = mapID, level = level, rating = _rating }
    _epoch = _epoch + 1

    for _index = 1, #_subscribers do
        _subscribers[_index](pureName)
    end
end

-- 取副本短名（优先本地化短名，未命中 / 缺翻译回退完整名）
function GuildKS.DungeonShortName(mapID)
    -- 防御：mapID 必须是有效正整数，否则 C_ChallengeMode.GetMapUIInfo 会直接报参数错误
    if type(mapID) ~= "number" or mapID <= 0 then return Translate["UNKNOWN"] or "Unknown" end

    local _entry = mppe.Dungeons and mppe.Dungeons[mapID]
    local _shortName = _entry and mppe.Translate and mppe.Translate[_entry.Name]
    if _shortName then return _shortName end

    return C_ChallengeMode.GetMapUIInfo(mapID) or "Unknown"
end

-- 取副本完整名称（筛选器选项 / tooltip 用）
function GuildKS.DungeonFullName(mapID)
    -- 防御：mapID 必须是有效正整数，否则 C_ChallengeMode.GetMapUIInfo 会直接报参数错误
    if type(mapID) ~= "number" or mapID <= 0 then return Translate["UNKNOWN"] or "Unknown" end

    return C_ChallengeMode.GetMapUIInfo(mapID) or GuildKS.DungeonShortName(mapID)
end

-- 生成指定样式的钥石显示文本（文本只取决于 mapID/level/样式，永远不会失效，可长期缓存）
local function buildKeystoneText(mapID, level, textStyle)
    local _cacheKey = mapID * 1000 + level
    local _entry = _textCache[_cacheKey]
    if not _entry then
        _entry = {}
        _textCache[_cacheKey] = _entry
    end

    local _text = _entry[textStyle]
    if _text then return _text end

    local _name = (textStyle == TEXT_FULL_SPACE) and GuildKS.DungeonFullName(mapID) or GuildKS.DungeonShortName(mapID)
    local _separator = (textStyle == TEXT_SHORT) and "" or " "
    _text = string.format("|cff%s%d%s%s|r", KEYSTONE_TEXT_COLOR, level, _separator, _name)
    _entry[textStyle] = _text
    return _text
end

-- 钥石显示文本：「10 回响」（useShortName = true）/「10 艾拉-卡拉，回响之城」（false）
function GuildKS.KeystoneText(mapID, level, useShortName)
    if not (mapID and mapID > 0 and level and level > 0) then return nil end

    return buildKeystoneText(mapID, level, useShortName and TEXT_SHORT_SPACE or TEXT_FULL_SPACE)
end

-- 钥石紧凑文本：「10回响」（短名且层数与名字之间无空格，供列宽有限的表格列使用）
function GuildKS.KeystoneTextCompact(mapID, level)
    if not (mapID and mapID > 0 and level and level > 0) then return nil end

    return buildKeystoneText(mapID, level, TEXT_SHORT)
end

-- 请求一次公会钥石数据（节流，避免反复开页刷请求；库本身也自带节流）
function GuildKS.RequestGuild(throttle)
    if not IsInGuild() then return end

    local _now = GetTime()
    if _now - _lastRequestTime < (throttle or DEFAULT_REQUEST_THROTTLE) then return end

    _lastRequestTime = _now

    if libKeystone then libKeystone.Request("GUILD") end
    if libOpenRaid then libOpenRaid:RequestKeystoneDataFromGuild() end
end

-- 强制刷新：清空缓存（含请求节流状态）并立即重新请求（窗口的「刷新」按钮用）
function GuildKS.ForceGuildRefresh()
    table.wipe(GuildKS.cache)
    _epoch = _epoch + 1
    _lastRequestTime = 0

    -- 通知订阅者：缓存被清空（参数为 nil）
    for _index = 1, #_subscribers do
        _subscribers[_index](nil)
    end

    GuildKS.RequestGuild()
end

-- ==================================================================
-- 接收器：全插件只注册这一套（LibKeystone 的 GUILD 频道 + LibOpenRaid 的 KeystoneUpdate）
-- 说明：不再“仅窗口显示时接收” —— 名单页与窗口两个消费方都可能需要数据，
--       缓存本身很小，统一始终接收，由订阅者自己决定何时刷新 UI
-- ==================================================================
local _receiverFrame = CreateFrame("Frame")

if libKeystone then
    libKeystone.Register(_receiverFrame, function(keyLevel, keyChallengeMapID, playerRating, shortName, channel)
        if channel ~= "GUILD" then return end
        GuildKS.Ingest(GuildKS.PureName(shortName), keyChallengeMapID, keyLevel, playerRating)
    end)
end

if libOpenRaid then
    -- LOR 的 KeystoneUpdate 同时承载「队伍」与「公会」两个来源的数据（库内都以玩家名回调，不带频道信息），
    -- 而 LKS 那条路径能直接看 channel。这里必须自己分辨：队友若不同公会，其钥石不该进公会缓存
    -- （缓存以纯名为 key，跨服同名会串数据）。非队伍成员时只可能是公会数据，直接收下。

    -- 该单位是否与自己同公会（拿不到公会名视为不同）
    local function _isSameGuildUnit(unit)
        if not unit or not UnitExists(unit) then return false end
        local _myGuild = GetGuildInfo("player")
        if not _myGuild or _myGuild == "" then return false end
        return GetGuildInfo(unit) == _myGuild
    end

    -- 该纯名是否可以写入公会缓存
    local function _acceptGuildKeystone(pureName)
        if not pureName then return false end
        -- 自己：同公会（自己必然与自己在同一公会）才收
        if pureName == UnitName("player") then return _isSameGuildUnit("player") end
        -- 队友：同公会才收（不同公会的队友属于队伍数据，由 PartyDB 那条路径负责）
        for _i = 1, GetNumSubgroupMembers() do
            local _unit = "party".._i
            if UnitName(_unit) == pureName then return _isSameGuildUnit(_unit) end
        end
        -- 既不是自己也不是队友：只可能是公会频道来的数据
        return true
    end

    local _openRaidCallback = {}
    function _openRaidCallback.OnKeystoneUpdate(unitName, keystoneInfo)
        if type(keystoneInfo) ~= "table" then return end
        if not _acceptGuildKeystone(GuildKS.PureName(unitName)) then return end

        -- mythicPlusMapID 供 C_ChallengeMode.GetMapUIInfo 取副本名；challengeMapID 兜底
        local _level = rawget(keystoneInfo, "level") or 0
        local _mapID = rawget(keystoneInfo, "mythicPlusMapID") or rawget(keystoneInfo, "challengeMapID") or 0
        local _rating = rawget(keystoneInfo, "rating") or 0
        GuildKS.Ingest(GuildKS.PureName(unitName), _mapID, _level, _rating)
    end
    libOpenRaid.RegisterCallback(_openRaidCallback, "KeystoneUpdate", "OnKeystoneUpdate")
end
