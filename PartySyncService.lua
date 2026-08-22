-- =================================================================
-- PartySyncService.lua
-- 统一同步服务（合并自原 Channel/MPPE_Channel.lua 与
-- Acquisition/PartySyncService.lua）：
--   第一部分 通信渠道：自建 addon 消息通信（协议 v1|TYPE|payload）
--   第二部分 采集编排：多源采集（MPPE/INSP/LOR/LKS/AKS）+ INSP 观察调度
-- 所有来源结果经 MergeEngine 写入单表 mppe.PartyDB，完成后统一刷新 UI
-- =================================================================
---@diagnostic disable: deprecated
local ADDON_NAME, mppe = ...

-- =================================================================
-- 第一部分：MPPE 自建通信渠道（对外 mppe.MPPE_Channel）
-- 队友自报钥石/成员信息/最佳记录；仅对已注册前缀的 CHAT_MSG_ADDON 生效
-- =================================================================
local MPPE_Channel = {}
mppe.MPPE_Channel = MPPE_Channel

local _prefix = nil          -- 注册后的前缀
local _registered = false
local _lastSent = {}         -- 类型 → 时间戳（发送限流）
local RATE_LIMIT = 3         -- 限流间隔（秒）

-- 初始化：注册 addon 消息前缀（登录后可调用）
function MPPE_Channel:Init()
    if _registered then return end
    _prefix = C_ChatInfo.RegisterAddonMessagePrefix("MPPE")
    _registered = true
end

-- 渠道是否可用
function MPPE_Channel:IsAvailable()
    return _registered and _prefix ~= nil
end

-- 获取注册后的前缀（用于 CHAT_MSG_ADDON 分发判断）
function MPPE_Channel:GetPrefix()
    return _prefix
end

-- 发送消息（带限流，防刷屏）
function MPPE_Channel:Send(msgType, payload)
    if not self:IsAvailable() then return end
    if not _prefix then return end
    local _now = time()
    if _lastSent[msgType] and (_now - _lastSent[msgType]) < RATE_LIMIT then return end
    _lastSent[msgType] = _now
    local _channel = IsInInstance() and "INSTANCE" or "PARTY"
    local _msg = string.format("v1|%s|%s", msgType, payload or "")
    C_ChatInfo.SendAddonMessage(_prefix, _msg, _channel)
end

-- 广播自己的全部自报数据（钥石/成员信息/最佳记录）
function MPPE_Channel:BroadcastAll()
    -- 钥石
    local _ksId = C_MythicPlus.GetOwnedKeystoneChallengeMapID() or 0
    local _ksLv = C_MythicPlus.GetOwnedKeystoneLevel() or 0
    self:Send("KS", string.format("%d|%d|0|%d", _ksId, _ksLv, time()))
    -- 成员信息（职业/专精/装等）
    local _class = select(2, UnitClass("player")) or "UNKNOWN"
    local _specId = C_SpecializationInfo.GetSpecializationInfo(C_SpecializationInfo.GetSpecialization()) or 0
    local _iLv = select(2, GetAverageItemLevel()) or 0
    self:Send("PI", string.format("%s|%d|%d|%d", _class, _specId, _iLv, time()))
    -- 最佳记录（紧凑编码：d:lv:score:s:dur，逗号分隔多副本）
    local _summary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary("player")
    local _score = _summary and _summary.currentSeasonScore or 0
    local _parts = {}
    if _summary and _summary.runs then
        for _i, _r in ipairs(_summary.runs) do
            table.insert(_parts, string.format("%d:%d:%d:%s:%d",
                _r.challengeModeID, _r.bestRunLevel or 0, _r.mapScore or 0,
                _r.finishedSuccess and "1" or "0", _r.bestRunDurationMS or 0))
        end
    end
    self:Send("BR", string.format("%d|%d|%s", _score, time(), table.concat(_parts, ",")))
end

-- 请求全队同步
function MPPE_Channel:RequestAll()
    if not self:IsAvailable() then return end
    self:Send("REQ", "ks,pi,br")
end

-- 处理收到的消息（由 PartyEvent 在 CHAT_MSG_ADDON 中转发）
function MPPE_Channel:OnMessage(message, sender)
    -- 忽略自己的消息
    local _myName = UnitName("player")
    local _myFull = string.format("%s-%s", _myName, GetRealmName())
    if sender == _myName or sender == _myFull then return true end

    local _version, _type, _payload = string.match(message, "^v(%d+)|([^|]+)|(.*)$")
    if not _version or not _type or tonumber(_version) ~= 1 then return false end

    if _type == "REQ" then
        -- 收到请求：响应自报数据
        self:BroadcastAll()
        return true
    elseif _type == "KS" then
        local _ksId, _ksLv, _rating = string.match(_payload, "^(%d+)|(%d+)|(%d+)")
        if _ksId then
            mppe.PartyUpsert_Keystone(sender, {
                ksId = tonumber(_ksId), ksLv = tonumber(_ksLv), rating = tonumber(_rating or 0),
            }, "MPPE")
        end
        return true
    elseif _type == "PI" then
        local _class, _specId, _iLv = string.match(_payload, "^([^|]+)|(%d+)|(%d+)")
        if _class then
            mppe.PartyUpsert_Member(sender, {
                class = _class, specId = tonumber(_specId), iLv = tonumber(_iLv),
            }, "MPPE")
        end
        return true
    elseif _type == "BR" then
        local _score, _runsStr = string.match(_payload, "^(%d+)|%d+|(.*)$")
        if _score then
            local _runs = {}
            for _token in string.gmatch(_runsStr or "", "([^,]+)") do
                local _d, _lv, _sc, _s, _dur = string.match(_token, "^(%d+):(%d+):(%d+):([01]):(%d+)$")
                if _d then
                    table.insert(_runs, {
                        challengeModeID = tonumber(_d), bestRunLevel = tonumber(_lv),
                        mapScore = tonumber(_sc), finishedSuccess = _s == "1",
                        bestRunDurationMS = tonumber(_dur),
                    })
                end
            end
            mppe.PartyUpsert_Best(sender, { runs = _runs, score = tonumber(_score) }, "MPPE")
        end
        return true
    end
    return false
end

-- =================================================================
-- 第二部分：统一采集编排（对外 mppe.PartySync）
-- 多源采集（MPPE/INSP/LOR/LKS/AKS）+ INSP 观察调度
-- =================================================================
local PartySyncService = {}
mppe.PartySync = PartySyncService

-- 观察调度器（重构自原 PartyInspector：队列基于 fullName+GUID，字段级判断）
local Inspector = { queue = {}, isBusy = false, currentGUID = nil, currentUnit = nil }

-- 字段是否过期（超过 maxAge 秒视为需要重新观察）
local function _fieldExpired(rec, tsKey, maxAge)
    local _ts = rec and rec[tsKey]
    if not _ts then return true end
    return (time() - _ts) >= (maxAge or 180)
end

-- 判断某成员是否需要观察（字段级：有 MPPE 自报则免观察）
function Inspector:ShouldObserve(fullName)
    local _rec = mppe.PartyDB[mppe.NormalizeFullName(fullName)]
    if not _rec then return true end
    -- MPPE 自报过职业/专精/装等则无需观察
    if _rec.iLvSrc == "MPPE" and _rec.classSrc == "MPPE" and _rec.specSrc == "MPPE" then
        return false
    end
    if _fieldExpired(_rec, "iLvUpdated") then return true end
    if _fieldExpired(_rec, "classUpdated") then return true end
    if _fieldExpired(_rec, "specUpdated") then return true end
    return false
end

-- 构建观察队列（增量，字段级过滤）
function Inspector:BuildQueue(forceRefresh)
    local _newQueue = {}
    for _i = 1, GetNumSubgroupMembers() do
        local _unit = "party".._i
        local _name, _realm = UnitFullName(_unit)
        if _name then
            local _key = string.format("%s-%s", _name, (_realm or GetRealmName()))
            if forceRefresh or self:ShouldObserve(_key) then
                table.insert(_newQueue, { unit = _unit, fullName = _key, guid = UnitGUID(_unit) })
            end
        end
    end
    self.queue = _newQueue
    return #_newQueue
end

-- 启动观察批次（forceRefresh：忽略新鲜度强制全队观察）
function Inspector:Start(forceRefresh)
    if self.isBusy or not IsInGroup() or IsInRaid() then return end
    if self:BuildQueue(forceRefresh) == 0 then
        self.isBusy = false
        PartySyncService:NotifyData()
        return
    end
    self.isBusy = true
    self:InspectNext()
end

-- 停止观察
function Inspector:Stop()
    self.isBusy = false
    self.currentGUID = nil
    self.currentUnit = nil
    self.queue = {}
    ClearInspectPlayer()
end

-- 观察下一个成员
function Inspector:InspectNext()
    if #self.queue == 0 then
        self.isBusy = false
        PartySyncService:NotifyData()
        return
    end
    local _item = table.remove(self.queue, 1)
    self.currentGUID = _item.guid
    self.currentUnit = _item.unit
    if not self.currentGUID then
        -- 玩家可能离线，跳过
        C_Timer.After(0.2, function() self:InspectNext() end)
        return
    end
    NotifyInspect(_item.unit)
    -- 超时保护 2.5 秒
    C_Timer.After(2.5, function()
        if self.currentGUID then
            self.currentGUID = nil
            self.currentUnit = nil
            self:InspectNext()
        end
    end)
end

-- 观察结果处理（INSPECT_READY）
function Inspector:HandleReady(guid)
    if not self.currentGUID or guid ~= self.currentGUID then return end
    local _unit = self.currentUnit
    if not _unit or UnitGUID(_unit) ~= guid then
        -- unit 失效：尝试通过 GUID 重新定位
        for _i = 1, GetNumSubgroupMembers() do
            local _pu = "party".._i
            if UnitGUID(_pu) == guid then
                _unit = _pu
                self.currentUnit = _unit
                break
            end
        end
    end
    if not _unit then
        ClearInspectPlayer()
        self.currentGUID = nil
        self.currentUnit = nil
        C_Timer.After(0.4, function() self:InspectNext() end)
        return
    end

    local _name, _realm = UnitFullName(_unit)
    local _key = string.format("%s-%s", _name or "", (_realm or GetRealmName()))
    local _specId = GetInspectSpecialization(_unit)
    local _class = select(2, UnitClass(_unit))
    -- 写入观察到的职业/专精
    mppe.PartyUpsert_Member(_key, { class = _class, specId = _specId }, "INSP")

    -- 尝试获取装等（未缓存时返回 0 会重试，最多 5 次等待物品信息缓存完整）
    local function _tryGetILevel(retryCount)
        local _iLv = PartySyncService:GetInspectItemLevel(_unit)
        if _iLv == 0 and retryCount < 5 then
            C_Timer.After(0.1, function() _tryGetILevel(retryCount + 1) end)
            return
        end
        if _iLv > 0 then mppe.PartyUpsert_Member(_key, { iLv = _iLv }, "INSP") end

        -- 尝试获取最佳记录（C_PlayerInfo 需先观察完成）
        local _summary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary(_unit)
        if _summary then
            mppe.PartyUpsert_Best(_key, {
                runs = _summary.runs or {}, score = _summary.currentSeasonScore or 0,
            }, "INSP")
        end

        ClearInspectPlayer()
        self.currentGUID = nil
        self.currentUnit = nil
        C_Timer.After(0.4, function() self:InspectNext() end)
    end
    _tryGetILevel(0)
end

-- 获取观察目标的平均装等（有已装备部位信息未缓存时返回 0，触发上层重试，避免写入偏低平均值）
function PartySyncService:GetInspectItemLevel(unit)
    if not unit or not UnitExists(unit) then return 0 end
    local _total = 0
    local _count = 15
    local _twoHanded = true
    local _bUncached = false
    for _slot = 1, 17 do
        if _slot ~= 4 then
            local _link = GetInventoryItemLink(unit, _slot)
            if _link then
                -- 物品信息未缓存（有链接但取不到装等）：标记本次计算不完整，整体返回 0 等重试
                local _iLv = select(4, GetItemInfo(_link))
                if not _iLv then _bUncached = true end
                -- 单手/双手武器判断
                local _classID = select(12, GetItemInfo(_link))
                local _subClassID = select(13, GetItemInfo(_link))
                if _classID == 2 then
                    local _oneHanded = { [0] = true, [4] = true, [7] = true, [13] = true, [15] = true, [19] = true }
                    if _oneHanded[_subClassID] then _twoHanded = false end
                end
                _total = _total + (_iLv or 0)
            elseif _slot == 17 and _twoHanded == false then
                -- 单手武器副手空槽补一个装等位
                _count = _count + 1
            end
        end
    end
    -- 存在未缓存部位：返回 0 让上层重试（避免部分部位计 0 导致平均装等失真，如 297 被算成 217）
    if _bUncached then return 0 end
    if _count > 0 then return mppe.MathRound(_total / _count, 0) end
    return 0
end

-- 数据到达通知：防抖刷新 UI（合并短时间内的多次通知）
local _refreshTimer = nil
function PartySyncService:NotifyData()
    if _refreshTimer then _refreshTimer:Cancel() end
    _refreshTimer = C_Timer.After(0.3, function()
        _refreshTimer = nil
        mppe.RefreshPartyInfo()
    end)
end

-- 统一请求入口：进队/ROSTER_UPDATE/手动刷新时调用
function PartySyncService:RequestAll(forceRefresh)
    if not (IsInGroup() and not IsInRaid()) then return end
    -- 1. MPPE 自建渠道：请求 + 广播自己的数据
    if mppe.MPPE_Channel then
        mppe.MPPE_Channel:RequestAll()
        mppe.MPPE_Channel:BroadcastAll()
    end
    -- 2. 第三方库：AKS/LKS/LOR
    mppe:RequestPartyInfo()
    -- 3. INSP 观察（对无 MPPE 自报数据的成员）
    C_Timer.After(0.5, function()
        Inspector:Start(forceRefresh)
    end)
end

-- 手动刷新按钮：强制全队观察 + 全渠道请求
function PartySyncService:ForceRefresh()
    if not (IsInGroup() and not IsInRaid()) then return end
    if mppe.MPPE_Channel then
        mppe.MPPE_Channel:RequestAll()
        mppe.MPPE_Channel:BroadcastAll()
    end
    mppe:RequestPartyInfo()
    C_Timer.After(0.5, function() Inspector:Start(true) end)
end

-- 供事件层调用的包装方法
function PartySyncService:HandleInspectReady(guid)
    Inspector:HandleReady(guid)
end

function PartySyncService:StopInspector()
    Inspector:Stop()
end

function PartySyncService:StartInspector(forceRefresh)
    Inspector:Start(forceRefresh)
end
