local ADDON_NAME, mppe = ...
local LKS = LibStub("LibKeystone")
local LOR = LibStub("LibOpenRaid-1.0")
local pe = mppe.PartyEvent

local partyCheckTimer = nil
local AKS_PREFIX = "AngryKeystones"   -- AKS 通信前缀：请求、自报与收报都用它

-- 判断名字是否是自己（过滤 LOR 公会频道里自己上报的数据，避免自反馈刷新链）
local function _isSelf(name)
    if type(name) ~= "string" or name == "" then return false end
    -- 手动剥离 -Realm 后缀（跨服全名用 Ambiguate("none") 会保留服务器后缀，与 IsInParty 保持一致）
    local _pure = (name:gsub("^([^-]+)%-?.*", "%1"))
    return _pure == mppe.Mine.Name
end

-- 重置预创建队伍信息（离队 / 副本完成时调用）
local function _resetLFGInfo()
    mppe.LFG_Info = { titleName = "", typeName = "", modeName = "", activityID = 0, groupFinderActivityGroupID = 0, mapID = 0 }
end

-- =================================================================
-- 事件注册与派发（采集结果统一交给 PartySyncService 处理）
pe:RegisterEvent("ADDON_LOADED")
pe:RegisterEvent("GROUP_JOINED")
pe:RegisterEvent("GROUP_LEFT")
pe:RegisterEvent("GROUP_ROSTER_UPDATE")
pe:RegisterEvent("INSPECT_READY")
pe:RegisterEvent("CHAT_MSG_ADDON")
pe:RegisterEvent("CHALLENGE_MODE_COMPLETED")   -- AKS 自报：打完 M+ 后开始监听本钥石变化

pe:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local _addonName = ...
        -- 仅本插件加载完成才初始化（ADDON_LOADED 对所有插件触发，不判断会导致本插件文件未加载时提前执行 Init，MPPE 前缀注册失败）
        if _addonName == ADDON_NAME then
            -- 初始化：注册 MPPE 通信前缀 + Lib 回调 + 启动定时检查
            mppe.MPPE_Channel:Init()
            -- 注册 AKS 通信前缀：客户端只会把「已注册前缀」的包派发到 CHAT_MSG_ADDON，不注册就永远收不到 AKS 消息
            -- 前缀表是客户端级共享的（与是否装了 AngryKeystones 插件无关），重复注册返回 DuplicatePrefix，无副作用
            C_ChatInfo.RegisterAddonMessagePrefix(AKS_PREFIX)
            C_Timer.After(0.5, function() pe:Lib_Register() end)
            C_Timer.After(1, function() pe:PartyCheckTimer(true) end)
            -- reload 时若已在队伍中，恢复 inParty 标记
            C_Timer.After(1.5, function() mppe.PartyCleanup() end)
            self:UnregisterEvent("ADDON_LOADED")
        end
    elseif event == "GROUP_JOINED" then
        -- 进队：停止旧观察并全渠道同步，延迟维护 inParty（等队伍信息就绪）
        mppe.PartySync:StopInspector()
        C_Timer.After(0.5, function() mppe.PartySync:RequestAll() end)
        C_Timer.After(1, function() pe:PartyCheckTimer(true) end)
        C_Timer.After(1.5, function() mppe.PartyCleanup() end)
    elseif event == "GROUP_LEFT" then
        -- 离队：重置 LFG 信息并停止观察，延迟清理数据
        _resetLFGInfo()
        mppe.PartySync:StopInspector()
        pe:PartyCheckTimer(false)
        mppe.RefreshPartyInfo()
        C_Timer.After(5, function() mppe.PartyCleanup() end)
    elseif event == "GROUP_ROSTER_UPDATE" then
        -- 队伍变化：延迟全渠道同步并维护 inParty
        C_Timer.After(1, function()
            mppe.PartySync:RequestAll()
            mppe.PartyCleanup()
        end)
    elseif event == "INSPECT_READY" then
        local _guid = ...
        mppe.PartySync:HandleInspectReady(_guid)
    elseif event == "CHAT_MSG_ADDON" then
        local _prefix, _message, _channel, _sender = ...
        -- 仅处理队伍频道（PARTY / INSTANCE_CHAT）：优先过滤，忽略公会/世界等其它频道的 addon 消息，防公会插件浪涌
        -- 注意：副本内的频道名是 "INSTANCE_CHAT"，不是 "INSTANCE"
        if _channel ~= "PARTY" and _channel ~= "INSTANCE_CHAT" then return end
        -- 未组队时无队伍频道消息，防御性快速返回
        if not IsInGroup() then return end
        if _prefix == AKS_PREFIX then
            pe:AKS_Callback(_message, _sender)
        elseif _prefix == mppe.MPPE_Channel:GetPrefix() then
            mppe.MPPE_Channel:OnMessage(_message, _sender)
        -- elseif _prefix == "TinyInspect" then
        --     pe:TinyInsp_Callback(_message, _sender)
        end
    elseif event == "CHALLENGE_MODE_COMPLETED" then
        -- 打完 M+：开始监听物品变化，拿到新钥石后主动广播给 AKS 频道
        pe:AKS_StartItemWatch()
    elseif event == "PLAYER_LEAVING_WORLD" then
        -- 离开副本：停止监听（只在“刚打完本”这段窗口内需要）
        pe:AKS_StopItemWatch()
    elseif event == "ITEM_CHANGED" or event == "ITEM_PUSH" then
        -- 物品变化：交给 AKS 模块延迟比对（直接读 API 会读到旧钥石）
        pe:AKS_OnItemChanged()
    end
end)

-- 定时检查器：周期 181 秒触发全渠道同步（有 MPPE 自报数据的成员会被字段级过滤跳过）
function pe:PartyCheckTimer(enable)
    local _currentState = (partyCheckTimer ~= nil)
    if enable == _currentState then return end
    if partyCheckTimer then
        partyCheckTimer:Cancel()
        partyCheckTimer = nil
    end
    if enable then
        local function _doPartyCheck()
            if IsInGroup() and not IsInRaid() and not UnitAffectingCombat("player") then
                mppe.PartySync:RequestAll()
            end
        end
        _doPartyCheck()
        partyCheckTimer = C_Timer.NewTicker(181, _doPartyCheck)
    end
end

-- =================================================================
-- Lib 库相关：LKS / LOR 注册与回调
function pe:Lib_Register()
    -- 注：LKS.Request 时库会用「自己的名字」本地回调一次，这里一并过滤自己，避免把自己的钥石以 LKS 来源写进单表
    LKS.Register(self, function(keyLevel, keyChallengeMapID, playerRating, sender, channel)
        if (channel == "PARTY") and keyLevel > 0 and not _isSelf(sender) then
            mppe.PartyUpsert_Keystone(sender, {
                ksId = keyChallengeMapID, ksLv = keyLevel, rating = playerRating,
            }, "LKS")
            mppe.PartySync:NotifyData("LKS")
        end
    end)
    LOR.RegisterCallback(self, "UnitInfoUpdate", "LOR_UnitCallback")
    LOR.RegisterCallback(self, "GearUpdate", "LOR_GearCallback")
    LOR.RegisterCallback(self, "KeystoneUpdate", "LOR_KeystoneCallback")
    -- 副本记录（本季总分 + 各副本最佳）：LOR 的 "F" 全量应答里没有它，必须单独注册 "M" 数据回调
    LOR.RegisterCallback(self, "RatingUpdate", "LOR_RatingCallback")
    C_Timer.After(0.5, function() mppe.PartySync:RequestAll() end)
end

-- LOR 玩家信息回调（职业、专精ID；未组队直接跳过，排除自己 + 仅处理当前队伍成员）
-- 库签名是 (unitId, unitInfo, allUnitsInfo)：unitId 只是单位令牌/名字字符串，玩家数据在 unitInfo 里
function pe:LOR_UnitCallback(unitId, unitInfo, allUnitsInfo)
    -- 未组队时 LOR 上报的均为公会数据，MPPE 不需要，直接跳过
    if not IsInGroup() then return end
    if type(unitInfo) ~= "table" then return end
    -- 玩家名优先取带服务器的全名（跨服队友只用纯名会与 PartyDB 的 key 不一致，写入后读不到）
    local _name = unitInfo.nameFull
    if type(_name) ~= "string" or _name == "" then _name = unitInfo.name end
    -- 兜底 1：unitId 可能是单位令牌，也可能只是名字（跨服全名 "Name-Realm" 不是合法令牌）
    -- → UnitName 对非法令牌会直接报错（Usage: local unitName, unitServer = UnitName(unit)），故用 pcall 保护
    if type(_name) ~= "string" or _name == "" then
        if type(unitId) == "string" and unitId ~= "" then
            local _ok, _unitName = pcall(UnitName, unitId)
            if _ok and type(_unitName) == "string" then _name = _unitName end
        end
    end
    -- 兜底 2：库的 UnitData 就是以 unitName 为 key，按「同一个表」反查 key 即可拿到名字
    -- （实测遇到过 name/nameFull 均为空串的包，此处不能再变成报错）
    if (type(_name) ~= "string" or _name == "") and type(allUnitsInfo) == "table" then
        for _key, _value in pairs(allUnitsInfo) do
            if _value == unitInfo and type(_key) == "string" and _key ~= "" then
                _name = _key
                break
            end
        end
    end
    if type(_name) ~= "string" or _name == "" then return end
    -- 排除自己 + 仅处理当前队伍成员，忽略公会/陌生人数据
    if _isSelf(_name) or not mppe.IsInParty(_name) then return end
    -- 只写入有效字段：职业为空串、专精为 0（未就绪）时不写，避免以 LOR 来源写入空值
    local _data = {}
    if type(unitInfo.class) == "string" and unitInfo.class ~= "" then _data.class = unitInfo.class end
    if (tonumber(unitInfo.specId) or 0) > 0 then _data.specId = tonumber(unitInfo.specId) end
    if next(_data) == nil then return end
    mppe.PartyUpsert_Member(_name, _data, "LOR")
    mppe.PartySync:NotifyData("LOR_Unit")
end

-- LOR 装备信息回调（装等：gearInfo.ilevel 为玩家平均装等；未组队直接跳过）
function pe:LOR_GearCallback(unitId, gearInfo, allGear)
    -- 未组队时 LOR 上报的均为公会数据，MPPE 不需要，直接跳过
    if not IsInGroup() then return end
    if type(gearInfo) ~= "table" then return end
    local _iLv = tonumber(gearInfo.ilevel) or 0
    if _iLv <= 0 then return end
    -- unitId 可能是 {name=..} 对象、单位令牌（party1）或角色名；单位令牌转角色名，自己跳过
    local _name = type(unitId) == "table" and unitId.name or unitId
    if type(_name) ~= "string" or _name == "" then return end
    -- unitId 是单位令牌或名字；跨服全名 "Name-Realm" 不是合法令牌，UnitName 会报错，故用 pcall 保护
    local _ok, _resolved = pcall(UnitName, _name)
    if _ok and _resolved then
        if _resolved == UnitName("player") then return end
        _name = _resolved
    end
    -- 排除自己 + 仅处理当前队伍成员，忽略公会/陌生人数据
    if _isSelf(_name) or not mppe.IsInParty(_name) then return end
    mppe.PartyUpsert_Member(_name, { iLv = _iLv }, "LOR")
    mppe.PartySync:NotifyData("LOR_Gear")
end

-- LOR 钥石信息回调（未组队直接跳过；排除自己 + 仅处理当前队伍成员，防公会频道浪涌）
-- 库签名是 (unitName, keystoneInfo, allKeystoneInfo)：keystoneInfo 是「该玩家单人」的信息表
-- （字段 level / mapID / challengeMapID / classID / rating / specID），不是「名字→信息」的字典
function pe:LOR_KeystoneCallback(unitName, keystoneInfo, allKeystones)
    -- 未组队时 LOR 上报的均为公会钥石，MPPE 不需要，直接跳过
    if not IsInGroup() then return end
    if type(unitName) ~= "string" or unitName == "" then return end
    if type(keystoneInfo) ~= "table" then return end
    -- 排除自己 + 仅处理当前队伍成员，忽略公会/陌生人，避免非队伍数据驱动的空转刷新
    if _isSelf(unitName) or not mppe.IsInParty(unitName) then return end
    -- challengeMapID 才是 PartyDB.ksId 需要的副本ID（与 GetOwnedKeystoneChallengeMapID 同源）；无钥石时为 0，直接跳过
    local _ksLv = tonumber(keystoneInfo.level) or 0
    if _ksLv <= 0 then return end
    local _data = {
        ksId = tonumber(keystoneInfo.challengeMapID) or 0,
        ksLv = _ksLv,
    }
    local _rating = tonumber(keystoneInfo.rating) or 0
    if _rating > 0 then _data.rating = _rating end
    mppe.PartyUpsert_Keystone(unitName, _data, "LOR")
    mppe.PartySync:NotifyData("LOR_KS")
end

-- LOR 副本记录回调（本季总分 + 各副本最佳记录；未组队直接跳过，排除自己 + 仅处理当前队伍成员）
-- 库签名是 (unitName, ratingInfo, allRatingInfo)：ratingInfo = { classID, currentSeasonScore, runs[] }，
-- runs 元素字段与暴雪 summary.runs 完全同名（challengeModeID / bestRunDurationMS(毫秒) / finishedSuccess(bool) / mapScore / bestRunLevel），
-- 与 PartyDB 的 best 组、UI 的 MythicRunsDunFiller 天然兼容，无需任何字段换算
function pe:LOR_RatingCallback(unitName, ratingInfo, allRatingInfo)
    -- 未组队时 LOR 上报的均为公会记录（"M" 数据前缀同时用于公会频道），MPPE 不需要，直接跳过
    if not IsInGroup() then return end
    if type(unitName) ~= "string" or unitName == "" then return end
    if type(ratingInfo) ~= "table" then return end
    -- 排除自己（库在登录 / 打完本时会用自己的数据触发一次）+ 仅处理当前队伍成员，忽略公会/陌生人数据
    if _isSelf(unitName) or not mppe.IsInParty(unitName) then return end
    local _runs = ratingInfo.runs
    -- 无记录（对方本季空白 / 数据未就绪）时不写入：LOR 优先级高于 INSP，写空会盖掉已有的观察结果
    if type(_runs) ~= "table" or #_runs == 0 then return end
    -- 只重建 UI 需要的字段，避免把库的原始表（含 otherRuns 等无关字段）整表塞进 PartyDB
    local _data = {}
    for _i, _r in ipairs(_runs) do
        local _dunID = (type(_r) == "table") and (tonumber(_r.challengeModeID) or 0) or 0
        if _dunID > 0 then
            table.insert(_data, {
                challengeModeID   = _dunID,
                bestRunLevel      = tonumber(_r.bestRunLevel) or 0,
                mapScore          = tonumber(_r.mapScore) or 0,
                finishedSuccess   = (_r.finishedSuccess == true),
                bestRunDurationMS = tonumber(_r.bestRunDurationMS) or 0,
            })
        end
    end
    if #_data == 0 then return end
    mppe.PartyUpsert_Best(unitName, { runs = _data, score = tonumber(ratingInfo.currentSeasonScore) or 0 }, "LOR")
    mppe.PartySync:NotifyData("LOR_Rating")
end

-- =================================================================
-- AKS 自报：自己钥石变化后主动广播到 AKS 频道
-- · 仿 LibKeystone：打完 M+ 后才开始监听物品变化，离开副本即停止（不常驻监听）
-- · 本地装有 AngryKeystones 插件时不发送 —— 由它自己发送，我们只接收，避免同一份数据发两遍
-- =================================================================
local AKS_CHECK_DELAY = 1     -- 物品变化后延迟多久再读钥石（钥石到手时 API 有延迟）
local AKS_SEND_THROTTLE = 3   -- 两次广播之间的最短间隔（秒）
local AKS_RECHECK_DELAY = 3   -- 打完本后的复查延迟（秒）：兜底「完成时基线已是新钥石」导致的漏发
local AKS_REPLY_THROTTLE = 1  -- 应答请求的最小间隔（秒）：多人同时请求只回一次，防被循环请求放大

local _aksKeyId, _aksKeyLv = nil, nil   -- 上次广播时的钥石（用于判断是否真的变了）
local _aksLastSendAt = 0                -- 上次广播的时间（节流用）
local _aksLastReplyAt = 0               -- 上次应答请求的时间（节流用）

-- 当前是否装有并运行着 AngryKeystones 插件（运行中则由它负责发送，我们不再发送）
-- 用 rawget 取旧全局：新版客户端只剩 C_AddOns，且这样写不会被静态检查器误报为未定义全局
local function _isAKSAddonRunning()
    local _isLoaded = (C_AddOns and C_AddOns.IsAddOnLoaded) or rawget(_G, "IsAddOnLoaded")
    if type(_isLoaded) ~= "function" then return false end
    return _isLoaded(AKS_PREFIX) == true
end

-- 取自己的钥石；allowZero 为真时允许 0（回传 request 要如实回答“没有钥石”），否则无效钥石返回 nil
local function _getOwnKeystone(allowZero)
    local _ksId = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
    local _ksLv = C_MythicPlus.GetOwnedKeystoneLevel()
    if not _ksId or not _ksLv then return nil end
    if not allowZero and (_ksId <= 0 or _ksLv <= 0) then return nil end
    return _ksId, _ksLv
end

-- 向 AKS 频道发一条消息（频道名统一走 mppe.GetPartyChannel）
local function _sendAKSMessage(payload)
    C_ChatInfo.SendAddonMessage(AKS_PREFIX, payload, mppe.GetPartyChannel())
end

-- 发送自己的钥石（AKS 协议：模块名|ksId:ksLv）
local function _sendAKSKeystone(ksId, ksLv)
    _sendAKSMessage(string.format("Schedule|%d:%d", ksId, ksLv))
end

-- 广播自己的钥石（有 AKS 插件 / 无钥石 / 未组队 / 间隔不足时静默跳过）
function pe:AKS_SendKeystone()
    if _isAKSAddonRunning() then return end
    if not IsInGroup() then return end

    local _ksId, _ksLv = _getOwnKeystone()
    if not _ksId then return end

    local _now = GetTime()
    if _now - _aksLastSendAt < AKS_SEND_THROTTLE then return end
    _aksLastSendAt = _now

    _sendAKSKeystone(_ksId, _ksLv)
end

-- 开始监听物品变化：先把当前钥石记为基线（打完本时通常是“没有钥石”），之后变化了才广播
function pe:AKS_StartItemWatch()
    _aksKeyId, _aksKeyLv = _getOwnKeystone()
    self:RegisterEvent("ITEM_CHANGED")
    self:RegisterEvent("ITEM_PUSH")
    self:RegisterEvent("PLAYER_LEAVING_WORLD")
    -- 复查兜底：CHALLENGE_MODE_COMPLETED 当刻若 API 已含新钥石，基线就等于新钥石 → 之后的物品变化比对不出差异会漏发；
    -- 故延迟再读一次并直接广播（无钥石 / 在节流窗口内 / 本机装了 AKS 时，AKS_SendKeystone 内部会自动跳过）
    C_Timer.After(AKS_RECHECK_DELAY, function()
        _aksKeyId, _aksKeyLv = _getOwnKeystone()
        pe:AKS_SendKeystone()
    end)
end

-- 停止监听物品变化（离开副本后不再需要，避免常驻监听背包变化）
function pe:AKS_StopItemWatch()
    self:UnregisterEvent("ITEM_CHANGED")
    self:UnregisterEvent("ITEM_PUSH")
    self:UnregisterEvent("PLAYER_LEAVING_WORLD")
end

-- 物品变化：延后一瞬再读钥石（从箱子 / 引导员到手时 API 更新有延迟），确实变了才广播
function pe:AKS_OnItemChanged()
    C_Timer.After(AKS_CHECK_DELAY, function()
        local _ksId, _ksLv = _getOwnKeystone()
        if not _ksId then return end                                   -- 还没拿到钥石：只是普通物品变化
        if _ksId == _aksKeyId and _ksLv == _aksKeyLv then return end   -- 钥石没变

        _aksKeyId, _aksKeyLv = _ksId, _ksLv
        pe:AKS_SendKeystone()
    end)
end

-- AKS 回调：解析 AKS 钥石协议（AKS 消息格式为 "模块名|内容"，如 "Schedule|request" / "Schedule|ksId:ksLv"）
function pe:AKS_Callback(message, fullName)
    --print("AKS_CB", message, fullName)
    -- 剥离 AKS 模块前缀（Schedule|），取出真实内容；无前缀时原样使用
    local _payload = message:match("^[^|]+|(.*)$") or message
    -- 收到请求：回传自己的钥石（需带 Schedule 模块前缀，AKS 才能识别）
    -- 装有 AngryKeystones 插件时由它回传，我们不发（只接收）；自己的请求也不回
    if _payload == "request" and not _isSelf(fullName) and not _isAKSAddonRunning() then
        -- 应答节流：多人同时请求（或异常插件循环请求）时 1 秒内只回一次，避免 1:1 放大频道流量
        local _now = GetTime()
        if _now - _aksLastReplyAt >= AKS_REPLY_THROTTLE then
            _aksLastReplyAt = _now
            local _ksId, _ksLv = _getOwnKeystone(true)
            -- 无钥石时按原插件协议回 "Schedule|0"（不能回 "0:0"：AKS 会存成 {0,0}，而它 UI 判的是 == 0，会把该成员整条隐藏）
            if _ksId and _ksId > 0 then _sendAKSKeystone(_ksId, _ksLv) else _sendAKSMessage("Schedule|0") end
        end
    end
    -- 解析收到的钥石（"ksId:ksLv"）并写入 PartyDB
    -- 仅写入有效钥石（ksId>0）："0:0" 之类的空钥石报文不能写，否则会以 AKS 优先级把已有真实钥石清成 0
    local _ksId, _ksLv = string.match(_payload, "^(%d+):(%d+)$")
    if _ksId and tonumber(_ksId) > 0 then
        mppe.PartyUpsert_Keystone(fullName, { ksId = tonumber(_ksId), ksLv = tonumber(_ksLv) }, "AKS")
        mppe.PartySync:NotifyData("AKS")
    end
end

-- function pe:TinyInsp_Callback(message, fullName)
--     print("TinyInsp_CB", message, fullName)
    
-- end

-- LOR "J"/"O" 请求的最小间隔（秒）：库对 "F" 自带 30 秒冷却，这两个没有；
-- 连续队伍事件（多人陆续进队）会连发请求，每个 LOR 队友都会回一波，故在此加一道门
local LOR_REQ_THROTTLE = 10
local _lorLastReqAt = 0

-- 请求全队信息（AKS/LKS/LOR 三方库）
function mppe:RequestPartyInfo()
    if IsInGroup() and not IsInRaid() then
        -- AKS 请求协议：模块名(Schedule)|request（频道名由 mppe.GetPartyChannel 统一决定）
        _sendAKSMessage("Schedule|request")
        -- LKS 只认 PARTY/GUILD 频道，副本队伍频道（INSTANCE_CHAT）下不请求它
        if mppe.GetPartyChannel() == "PARTY" then LKS.Request("PARTY") end
        -- LOR 全量数据（"F"）只含 单位信息+装备+冷却，不含钥石与副本记录；后两项要单独发请求才会回传
        LOR.RequestAllData()
        local _now = GetTime()
        if _now - _lorLastReqAt >= LOR_REQ_THROTTLE then
            _lorLastReqAt = _now
            LOR.RequestKeystoneDataFromParty()   -- "J"：钥石
            LOR.RequestRatingDataFromParty()     -- "O"：本季总分 + 各副本最佳记录
        end
    end
end

-- 兼容旧接口：强制刷新全队观察（原 RefreshPartyInspector）
function mppe.RefreshPartyInspector()
    mppe.PartySync:ForceRefresh()
end

-- =================================================================
-- 预创建队伍事件
local PartyEvent_LFG = CreateFrame("Frame")
PartyEvent_LFG:RegisterEvent("LFG_LIST_ACTIVE_ENTRY_UPDATE")
PartyEvent_LFG:RegisterEvent("LFG_LIST_APPLICATION_STATUS_UPDATED")
PartyEvent_LFG:RegisterEvent("LFG_LIST_JOINED_GROUP")
PartyEvent_LFG:RegisterEvent("CHALLENGE_MODE_COMPLETED")
PartyEvent_LFG:SetScript("OnEvent", function(self, event, ...)
    if event == "CHALLENGE_MODE_COMPLETED" then
        -- 副本完成：清空预创建队伍信息（离队 GROUP_LEFT 也会清；活动关闭不清，保留上次信息）
        _resetLFGInfo()
        mppe.RefreshPartyInfo("LFG_Complete")
        return
    end
    if event == "LFG_LIST_ACTIVE_ENTRY_UPDATE" or event == "LFG_LIST_APPLICATION_STATUS_UPDATED" or event == "LFG_LIST_JOINED_GROUP" then
        C_Timer.After(0.5, function() PartyEvent_LFG:Update() end)
    end
end)

-- 更新预创建队伍信息（标题/类型/副本）
function PartyEvent_LFG:Update()
    if IsInGroup() and not IsInRaid() then
        local _activeEntry = C_LFGList.GetActiveEntryInfo()
        if _activeEntry then
            -- 遍历所有活动：优先取"大秘境活动且 mapID>0"的一项，兜底取第一项；GetActivityInfoTable 可能返回 nil
            local _bestAID, _bestInfo
            for _, _aid in ipairs(_activeEntry.activityIDs or {}) do
                local _info = C_LFGList.GetActivityInfoTable(_aid)
                if _info then
                    if not _bestInfo then _bestAID, _bestInfo = _aid, _info end
                    if _info.isMythicPlusActivity and (_info.mapID or 0) > 0 then
                        _bestAID, _bestInfo = _aid, _info
                        break
                    end
                end
            end
            -- 仅成功解析到活动才整体覆盖；活动关闭（GetActiveEntryInfo 为 nil 或解析失败）时保留上次信息，不清空
            if _bestInfo then
                mppe.LFG_Info.titleName = tostring(_activeEntry.name) or ""
                mppe.LFG_Info.activityID = _bestAID
                mppe.LFG_Info.typeName = _bestInfo.fullName or ""
                mppe.LFG_Info.modeName = _bestInfo.shortName or ""
                mppe.LFG_Info.groupFinderActivityGroupID = _bestInfo.groupFinderActivityGroupID or 0
                mppe.LFG_Info.mapID = _bestInfo.mapID or 0
                --print(string.format("MPPE LFG: aid=%d fullName=%s mapID=%d isM+=%s ownKS=%s", _bestAID, tostring(_bestInfo.fullName), mppe.LFG_Info.mapID, tostring(_bestInfo.isMythicPlusActivity), tostring(C_MythicPlus.GetOwnedKeystoneChallengeMapID())))
            end
        end
    end
    -- LFG 信息变化后刷新小队信息，钥石颜色提示随活动副本及时更新
    mppe.RefreshPartyInfo("LFG")
end
