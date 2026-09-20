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
local _lastSentAt = {}       -- 闸门键 → 上次发送时间（GetTime，秒，浮点）
local RATE_LIMIT = 3         -- 主动发送的最小间隔（秒）
local REPLY_DEBOUNCE = 1.5   -- 应答请求的合并窗口（秒）：多人同时发 REQ 时只响应一次
local PROTO_VERSION = 2      -- 当前协议版本：BR 的时长自 v2 起为 0.1 秒单位（v1 为毫秒）
local RETRY_DELAY = 3        -- 发送被节流拒绝后的补发延迟（秒），与 LibKeystone 的 throttleTime 保持一致

-- 初始化：注册 addon 消息前缀（登录后可调用）
function MPPE_Channel:Init()
    if _registered then return end
    -- RegisterAddonMessagePrefix 返回结果码（0=成功），前缀统一用常量 "MPPE"
    C_ChatInfo.RegisterAddonMessagePrefix("MPPE")
    _prefix = "MPPE"
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

-- 队伍频道名：副本队伍用 "INSTANCE_CHAT"，其余用 "PARTY"
-- 注意：不能写成 "INSTANCE" —— 它不是合法 chatType，发送会返回 4（InvalidChatType）被静默丢弃
function mppe.GetPartyChannel()
    if LE_PARTY_CATEGORY_INSTANCE and IsInGroup(LE_PARTY_CATEGORY_INSTANCE) then return "INSTANCE_CHAT" end
    return "PARTY"
end

-- 限流闸门：距上次同一 key 的发送不足 minInterval 秒则返回 true 并刷新时间戳
-- 用 GetTime 而非 time：time() 只有 1 秒精度，3 秒限流实际会变成 3~4 秒
local function _isThrottled(key, minInterval)
    local _now = GetTime()
    if _lastSentAt[key] and (_now - _lastSentAt[key]) < minInterval then return true end
    _lastSentAt[key] = _now
    return false
end

-- 发送消息（纯发送，不做限流：由调用方选择闸门，便于「主动广播」与「应答请求」用不同窗口）
-- version 省略时为 1；某类消息的载荷编码升级时传新版本号（老客户端会因版本门禁忽略该消息，不会误解析）
-- isRetry 为真表示这是补发（只补一次，避免服务端持续拒绝时无限循环）
function MPPE_Channel:Send(msgType, payload, version, isRetry)
    if not self:IsAvailable() then return end
    if not _prefix then return end
    local _msg = string.format("v%d|%s|%s", version or 1, msgType, payload or "")
    local _result = C_ChatInfo.SendAddonMessage(_prefix, _msg, mppe.GetPartyChannel())
    -- 3/8/9 = AddonMessageThrottle / ChannelThrottle / GeneralError（判定与 LibKeystone 一致），均为「服务端暂时拒收」
    -- 这类失败是静默丢包，而调用方的限流闸门已经计时 → 不补发的话这一轮广播就永久丢了（要等 181 秒 ticker）
    if not isRetry and (_result == 3 or _result == 8 or _result == 9) then
        C_Timer.After(RETRY_DELAY, function() self:Send(msgType, payload, version, true) end)
    end
end

-- 广播自己的全部自报数据（钥石/成员信息/最佳记录）
-- isReply 为真表示这是对别人 REQ 的应答：用独立的去抖窗口（REPLY_DEBOUNCE）
-- 目的：避免「刚主动广播过 → 应答被自己的限流吞掉 → 对方要等到 181 秒 ticker 才拿到数据」
-- 另：限流以「整批广播」为单位，保证 PI/BR 要么都发、要么都不发，不会只发出一半
function MPPE_Channel:BroadcastAll(isReply)
    local _gateKey = isReply and "BROADCAST_REPLY" or "BROADCAST"
    local _gateInterval = isReply and REPLY_DEBOUNCE or RATE_LIMIT
    if _isThrottled(_gateKey, _gateInterval) then return end
    -- 赛季评分：钥石消息与最佳记录共用，避免重复调用 API
    local _summary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary("player")
    local _score = math.floor(_summary and _summary.currentSeasonScore or 0)
    -- 【暂时停用】钥石自报：MPPE 通道不再发送 KS，队友钥石改由 LKS / AKS / LOR 通道提供
    -- 停用前的协议：ksId|ksLv|rating|时间戳（rating 曾写死 0，会以最高优先级覆盖 LKS/LOR 的评分）
    -- local _ksId = C_MythicPlus.GetOwnedKeystoneChallengeMapID() or 0
    -- local _ksLv = C_MythicPlus.GetOwnedKeystoneLevel() or 0
    -- if _ksId > 0 and _ksLv > 0 then
    --     self:Send("KS", string.format("%d|%d|%d|%d", _ksId, _ksLv, _score, time()))
    -- end
    -- 成员信息（职业/专精/装等）
    local _class = select(2, UnitClass("player")) or "UNKNOWN"
    local _specId = C_SpecializationInfo.GetSpecializationInfo(C_SpecializationInfo.GetSpecialization()) or 0
    local _iLv = select(2, GetAverageItemLevel()) or 0
    self:Send("PI", string.format("%s|%d|%d|%d", _class, _specId, _iLv, time()))
    -- 最佳记录（紧凑编码：d:lv:score:s:dur，逗号分隔多副本）
    local _parts = {}
    if _summary and _summary.runs then
        for _i, _r in ipairs(_summary.runs) do
            -- challengeModeID 缺失（异常数据）时跳过该条：直接 format("%d", nil) 会抛错，导致整条 BR 广播失败
            local _dunID = tonumber(_r.challengeModeID) or 0
            if _dunID > 0 then
                -- 时长按 0.1 秒为单位编码（毫秒 → 5 位数字，token 省 2 个字符；显示精度本身只到 0.1 秒）
                table.insert(_parts, string.format("%d:%d:%d:%s:%d",
                    _dunID, _r.bestRunLevel or 0, _r.mapScore or 0,
                    _r.finishedSuccess and "1" or "0", math.floor((_r.bestRunDurationMS or 0) / 100)))
            end
        end
    end
    -- BR 用 v2：时长单位为 0.1 秒（老客户端会因版本门禁忽略该消息，而不是把 5 位数字当毫秒显示错乱）
    self:Send("BR", string.format("%d|%d|%s", _score, time(), table.concat(_parts, ",")), 2)
end

-- 请求全队同步（REQ 自身也过闸门，避免短时间内多次队伍变化把请求刷爆）
function MPPE_Channel:RequestAll()
    if not self:IsAvailable() then return end
    if _isThrottled("REQ", RATE_LIMIT) then return end
    self:Send("REQ", "ks,pi,br")
end

-- 处理收到的消息（由 PartyEvent 在 CHAT_MSG_ADDON 中转发）
function MPPE_Channel:OnMessage(message, sender)
    -- 忽略自己的消息
    local _myName = UnitName("player")
    local _myFull = string.format("%s-%s", _myName, GetRealmName())
    if sender == _myName or sender == _myFull then return true end

    local _versionStr, _type, _payload = string.match(message, "^v(%d+)|([^|]+)|(.*)$")
    if not _versionStr or not _type then return false end
    -- 版本门禁：只处理自己认识的版本（v1 = 旧编码，v2 = BR 时长改为 0.1 秒）
    local _version = tonumber(_versionStr)
    if not _version or _version < 1 or _version > PROTO_VERSION then return false end

    if _type == "REQ" then
        -- 收到请求：响应自报数据（isReply=true：独立去抖窗口，不受自己主动广播的限流影响）
        self:BroadcastAll(true)
        return true
    -- 【暂时停用】KS 接收：MPPE 通道不再处理钥石自报（代码保留备查，恢复时去掉各行行首的 -- 即可）
    -- elseif _type == "KS" then
    --     local _ksId, _ksLv, _rating = string.match(_payload, "^(%d+)|(%d+)|(%d+)")
    --     -- 仅写入有效钥石（ksId>0）：队友无钥石时广播的 0 不写入，避免以最高优先级 MPPE 压制后续 AKS/LKS 来源的真实钥石
    --     if _ksId and tonumber(_ksId) > 0 then
    --         local _data = { ksId = tonumber(_ksId), ksLv = tonumber(_ksLv) }
    --         -- 评分为 0（发送端读不到赛季分）时不写 rating，否则会以最高优先级把 LKS/LOR 的真实评分覆盖成 0
    --         if (tonumber(_rating) or 0) > 0 then _data.rating = tonumber(_rating) end
    --         mppe.PartyUpsert_Keystone(sender, _data, "MPPE")
    --     end
    --     return true
    elseif _type == "PI" then
        local _class, _specId, _iLv = string.match(_payload, "^([^|]+)|(%d+)|(%d+)")
        if _class then
            local _data = {}
            -- 异常取值不写入：职业 UNKNOWN / 专精 0 / 装等 0 都是「读不到」，写进去只会以最高优先级压制 LOR/INSP 的真实值
            if _class ~= "UNKNOWN" then _data.class = _class end
            if (tonumber(_specId) or 0) > 0 then _data.specId = tonumber(_specId) end
            if (tonumber(_iLv) or 0) > 0 then _data.iLv = tonumber(_iLv) end
            -- 三个字段全无效时不再写入（避免只创建一条空记录）
            if next(_data) ~= nil then mppe.PartyUpsert_Member(sender, _data, "MPPE") end
        end
        return true
    elseif _type == "BR" then
        local _score, _runsStr = string.match(_payload, "^(%d+)|%d+|(.*)$")
        if _score then
            local _runs = {}
            -- v1 的时长是毫秒，v2 起是 0.1 秒 → 统一还原成毫秒（与 UI 的 FormatKSTime 口径一致）
            local _durScale = (_version >= 2) and 100 or 1
            for _token in string.gmatch(_runsStr or "", "([^,]+)") do
                local _d, _lv, _sc, _s, _dur = string.match(_token, "^(%d+):(%d+):(%d+):([01]):(%d+)$")
                if _d then
                    table.insert(_runs, {
                        challengeModeID = tonumber(_d), bestRunLevel = tonumber(_lv),
                        mapScore = tonumber(_sc), finishedSuccess = _s == "1",
                        bestRunDurationMS = (tonumber(_dur) or 0) * _durScale,
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

-- 推送来源：由队友插件主动发来（MPPE 自建渠道 / LOR 库），优先级均高于 INSP
-- 它们写过的字段，我们 inspect 到的值会被 MergeEngine 按优先级拒绝（PartySetField：_newPrio < _oldPrio 则不写），
-- 即观察结果永远进不了 PartyDB、UI 数值也不会变（显示的一直是推送来源的值）→ 这类观察是纯浪费
local PUSH_SOURCES = { MPPE = true, LOR = true }

-- 该字段是否已由推送来源提供（PartySetField 写入时来源标记与时间戳必然成对写入，判来源标记即可）
local function _isPushCovered(rec, srcKey)
    if not rec then return false end
    local _src = rec[srcKey]
    return _src ~= nil and PUSH_SOURCES[_src] == true
end

-- 判断某成员是否需要观察（字段级：职业/专精/装等只要被推送来源覆盖，观察也写不进去）
function Inspector:ShouldObserve(fullName)
    local _rec = mppe.PartyDB[mppe.NormalizeFullName(fullName)]
    if not _rec then return true end
    -- MPPE/LOR 已覆盖职业/专精/装等 → 免观察（旧逻辑只认 MPPE，装了 LOR 的队友每 181 秒被白观察一次）
    if _isPushCovered(_rec, "iLvSrc") and _isPushCovered(_rec, "classSrc") and _isPushCovered(_rec, "specSrc") then
        return false
    end
    -- 未被推送来源覆盖的字段，仍按 180 秒新鲜度决定是否观察
    if _fieldExpired(_rec, "iLvUpdated") then return true end
    if _fieldExpired(_rec, "classUpdated") then return true end
    if _fieldExpired(_rec, "specUpdated") then return true end
    return false
end

-- 构建观察队列（增量，字段级过滤；返回新队列，由 Start 决定合并策略）
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
    return _newQueue
end

-- 启动观察批次（forceRefresh：忽略新鲜度强制全队观察；观察进行中时新队列按 GUID 去重合并进队尾，避免新队员进入被漏掉）
function Inspector:Start(forceRefresh)
    if not IsInGroup() or IsInRaid() then return end
    local _newQueue = self:BuildQueue(forceRefresh)
    if #_newQueue == 0 then
        -- 无成员需要观察（均被渠道自报覆盖或数据新鲜）
        if not self.isBusy then PartySyncService:NotifyData("Inspector_Start") end
        return
    end
    if self.isBusy then
        -- 观察中：合并进现有队列（GUID 去重，新成员追加到队尾，确保稍后被观察到）
        local _seen = {}
        for _, _item in ipairs(self.queue) do _seen[_item.guid] = true end
        for _, _item in ipairs(_newQueue) do
            if not _seen[_item.guid] then table.insert(self.queue, _item) end
        end
        return
    end
    self.queue = _newQueue
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
        PartySyncService:NotifyData("Inspector_Next")
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
    -- 写入观察到的职业/专精：无效值（class 为空/nil、specId<=0）不写，与 MPPE/LOR 路径保持一致
    -- 观察优先级最低（INSP=2），写入无效值只会把来源标记占成 INSP，白占一个字段
    local _memberData = {}
    if type(_class) == "string" and _class ~= "" then _memberData.class = _class end
    if (tonumber(_specId) or 0) > 0 then _memberData.specId = tonumber(_specId) end
    if next(_memberData) ~= nil then mppe.PartyUpsert_Member(_key, _memberData, "INSP") end

    -- 尝试获取装等（未缓存时返回 0 会重试，最多 5 次等待物品信息缓存完整）
    local function _tryGetILevel(retryCount)
        local _iLv = PartySyncService:GetInspectItemLevel(_unit)
        if _iLv == 0 and retryCount < 5 then
            C_Timer.After(0.1, function() _tryGetILevel(retryCount + 1) end)
            return
        end
        if _iLv > 0 then mppe.PartyUpsert_Member(_key, { iLv = _iLv }, "INSP") end

        -- 尝试获取最佳记录（C_PlayerInfo 需先观察完成）
        -- 但 best 已由推送来源（MPPE/LOR，优先级均高于 INSP）提供时直接跳过：写了也会被 MergeEngine 拒绝
        if not _isPushCovered(mppe.PartyDB[mppe.NormalizeFullName(_key)], "bestSrc") then
            local _summary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary(_unit)
            if _summary then
                mppe.PartyUpsert_Best(_key, {
                    runs = _summary.runs or {}, score = _summary.currentSeasonScore or 0,
                }, "INSP")
            end
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
    local _bUncached = false
    for _slot = 1, 17 do
        if _slot ~= 4 then
            local _link = GetInventoryItemLink(unit, _slot)
            if _link then
                -- 物品信息未缓存（有链接但取不到装等）：标记本次计算不完整，整体返回 0 等重试
                -- GetItemInfo 调用同时取装等(itemLevel)/物品类ID(itemClassID)/子类ID(itemSubClassID)
                local _, _, _, _iLv, _, _, _, _, _, _, _classID, _subClassID = GetItemInfo(_link)
                -- 装等为 0 也视为未就绪（Lua 中 0 为真值，原 if not _iLv 拦不住 0，会导致 _total 静默少算而平均失真）
                if not _iLv or _iLv == 0 then _bUncached = true end
                --[0] = 'Axe1H', [4] = 'Mace1H', [7] = 'Sword1H', [9] = 'Warglaive', [13] = 'Unarmed', [15] = 'Dagger', [19] = 'Wand'
                --[0] = '单手斧', [4] = '单手锤', [7] = '单手剑', [9] = '战刃',[13] = '徒手/拳套', [15] = '匕首', [19] = '魔杖'
                -- 分母=配装应有部位数：主手单手（本应有副手）或副手槽有物品（双持/泰坦之握/单手+盾）→16；双手武器+副手空 →15
                if (_classID == 2 and (_subClassID == 0 or _subClassID == 4 or _subClassID == 7 or _subClassID == 9 or _subClassID == 13 or _subClassID == 15 or _subClassID == 19)) or _slot == 17 then _count = 16 end
                _total = _total + (_iLv or 0)
            end
        end
    end
    -- 存在未缓存部位：返回 0 让上层重试（避免部分部位计 0 导致平均装等失真，如 297 被算成 217）
    if _bUncached then return 0 end
    --print(_total, _count)
    if _count > 0 then return mppe.MathRound(_total / _count, 0) end
    return 0
end

-- 数据到达通知：防抖刷新 UI（合并短时间内的多次通知）
-- source 参数标识调用来源（排查用：统计各来源调用次数，定位谁在大量重复调用）
local _refreshTimer = nil
local _notifyCount = 0
local _notifySources = {}
function PartySyncService:NotifyData(source)
    -- 内存排查：按来源累计调用次数，每 100 次打印一次汇总
    _notifyCount = _notifyCount + 1
    if source then
        _notifySources[source] = (_notifySources[source] or 0) + 1
    end
    if _notifyCount % 100 == 0 then
        local _srcParts = {}
        for _src, _cnt in pairs(_notifySources) do
            table.insert(_srcParts, string.format("%s=%d", _src, _cnt))
        end
        --print(string.format("[MPPE-MEM] NotifyData x%d sources: %s", _notifyCount, table.concat(_srcParts, " ")))
    end
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
