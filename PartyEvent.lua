local ADDON_NAME, mppe = ...
local LKS = LibStub("LibKeystone")
local LOR = LibStub("LibOpenRaid-1.0")
local pe = mppe.PartyEvent

local partyCheckTimer = nil

-- 判断名字是否是自己（过滤 LOR 公会频道里自己上报的数据，避免自反馈刷新链）
local function _isSelf(name)
    if type(name) ~= "string" or name == "" then return false end
    -- 手动剥离 -Realm 后缀（跨服全名用 Ambiguate("none") 会保留服务器后缀，与 IsInParty 保持一致）
    local _pure = (name:gsub("^([^-]+)%-?.*", "%1"))
    return _pure == mppe.Mine.Name
end

-- =================================================================
-- 事件注册与派发（采集结果统一交给 PartySyncService 处理）
pe:RegisterEvent("ADDON_LOADED")
pe:RegisterEvent("GROUP_JOINED")
pe:RegisterEvent("GROUP_LEFT")
pe:RegisterEvent("GROUP_ROSTER_UPDATE")
pe:RegisterEvent("INSPECT_READY")
pe:RegisterEvent("CHAT_MSG_ADDON")

pe:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local _addonName = ...
        -- 仅本插件加载完成才初始化（ADDON_LOADED 对所有插件触发，不判断会导致本插件文件未加载时提前执行 Init，MPPE 前缀注册失败）
        if _addonName == ADDON_NAME then
            -- 初始化：注册 MPPE 通信前缀 + Lib 回调 + 启动定时检查
            mppe.MPPE_Channel:Init()
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
        mppe.LFG_Info = {titleName = "", typeName = "", modeName = "", activityID = 0, groupFinderActivityGroupID = 0, mapID = 0}
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
        -- 仅处理队伍频道（PARTY/INSTANCE）：优先过滤，忽略公会/世界等其它频道的 addon 消息，防公会插件浪涌
        if _channel ~= "PARTY" and _channel ~= "INSTANCE" then return end
        -- 未组队时无队伍频道消息，防御性快速返回
        if not IsInGroup() then return end
        if _prefix == "AngryKeystones" then
            pe:AKS_Callback(_message, _sender)
        elseif _prefix == mppe.MPPE_Channel:GetPrefix() then
            mppe.MPPE_Channel:OnMessage(_message, _sender)
        -- elseif _prefix == "TinyInspect" then
        --     pe:TinyInsp_Callback(_message, _sender)
        end
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
    LKS.Register(self, function(keyLevel, keyChallengeMapID, playerRating, sender, channel)
        if (channel == "PARTY") and keyLevel > 0 then
            mppe.PartyUpsert_Keystone(sender, {
                ksId = keyChallengeMapID, ksLv = keyLevel, rating = playerRating,
            }, "LKS")
            mppe.PartySync:NotifyData("LKS")
        end
    end)
    LOR.RegisterCallback(self, "UnitInfoUpdate", "LOR_UnitCallback")
    LOR.RegisterCallback(self, "GearUpdate", "LOR_GearCallback")
    LOR.RegisterCallback(self, "KeystoneUpdate", "LOR_KeystoneCallback")
    C_Timer.After(0.5, function() mppe.PartySync:RequestAll() end)
end

-- LOR 玩家信息回调（职业、专精ID；未组队直接跳过，排除自己 + 仅处理当前队伍成员）
function pe:LOR_UnitCallback(unitId, unitInfo)
    -- 未组队时 LOR 上报的均为公会数据，MPPE 不需要，直接跳过
    if not IsInGroup() then return end
    if _isSelf(unitId.name) or not mppe.IsInParty(unitId.name) then return end
    mppe.PartyUpsert_Member(unitId.name, {
        class = unitId.class, specId = unitId.specId,
    }, "LOR")
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
    local _resolved = UnitName(_name)
    if _resolved then
        if _resolved == UnitName("player") then return end
        _name = _resolved
    end
    -- 排除自己 + 仅处理当前队伍成员，忽略公会/陌生人数据
    if _isSelf(_name) or not mppe.IsInParty(_name) then return end
    mppe.PartyUpsert_Member(_name, { iLv = _iLv }, "LOR")
    mppe.PartySync:NotifyData("LOR_Gear")
end

-- LOR 钥石信息回调（未组队直接跳过；排除自己 + 仅处理当前队伍成员，防公会频道浪涌）
function pe:LOR_KeystoneCallback(unitName, keystoneInfo, allKeystones)
    -- 未组队时 LOR 上报的均为公会钥石，MPPE 不需要，直接跳过
    if not IsInGroup() then return end
    if type(keystoneInfo) ~= "table" then return end
    local _bWrote = false
    for _name, _info in pairs(keystoneInfo) do
        -- 排除自己 + 仅处理队伍成员数据，忽略公会/陌生人，避免非队伍数据驱动的空转刷新
        if type(_info) == "table" and not _isSelf(_name) and mppe.IsInParty(_name) then
            mppe.PartyUpsert_Keystone(_name, {
                ksId = rawget(_info, "challengeMapID"),
                ksLv = rawget(_info, "level"),
                rating = rawget(_info, "rating"),
            }, "LOR")
            _bWrote = true
        end
    end
    -- 仅在实际写入队友数据后才通知刷新
    if _bWrote then
        mppe.PartySync:NotifyData("LOR_KS")
    end
end

-- AKS 回调：解析 AKS 钥石协议（AKS 消息格式为 "模块名|内容"，如 "Schedule|request" / "Schedule|ksId:ksLv"）
function pe:AKS_Callback(message, fullName)
    --print("AKS_CB", message, fullName)
    -- 剥离 AKS 模块前缀（Schedule|），取出真实内容；无前缀时原样使用
    local _payload = message:match("^[^|]+|(.*)$") or message
    -- 收到请求：回传自己的钥石（需带 Schedule 模块前缀，AKS 才能识别）
    if _payload == "request" and fullName ~= mppe.Mine.Name then
        local _ksId = C_MythicPlus.GetOwnedKeystoneChallengeMapID()
        local _ksLv = C_MythicPlus.GetOwnedKeystoneLevel()
        if _ksId and _ksLv then
            local _channel = IsInInstance() and "INSTANCE" or "PARTY"
            C_ChatInfo.SendAddonMessage("AngryKeystones", string.format("Schedule|%d:%d", _ksId, _ksLv), _channel)
        end
    end
    -- 解析收到的钥石（"ksId:ksLv"）并写入 PartyDB
    local _ksId, _ksLv = string.match(_payload, "^(%d+):(%d+)$")
    if _ksId then
        mppe.PartyUpsert_Keystone(fullName, { ksId = tonumber(_ksId), ksLv = tonumber(_ksLv) }, "AKS")
        mppe.PartySync:NotifyData("AKS")
    end
end

-- function pe:TinyInsp_Callback(message, fullName)
--     print("TinyInsp_CB", message, fullName)
    
-- end

-- 请求全队信息（AKS/LKS/LOR 三方库）
function mppe:RequestPartyInfo()
    if IsInGroup() and not IsInRaid() then
        if not IsInInstance() then
            -- AKS 请求协议：模块名(Schedule)|request
            C_ChatInfo.SendAddonMessage("AngryKeystones", "Schedule|request", "PARTY")
            LKS.Request("PARTY")
        else
            C_ChatInfo.SendAddonMessage("AngryKeystones", "Schedule|request", "INSTANCE")
        end
        LOR.RequestAllData()
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
        mppe.LFG_Info = {titleName = "", typeName = "", modeName = "", activityID = 0, groupFinderActivityGroupID = 0, mapID = 0}
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
