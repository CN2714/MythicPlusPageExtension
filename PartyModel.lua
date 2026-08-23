-- =================================================================
-- PartyModel.lua
-- 单表数据模型：将原 PartyMember / PartyKeystone / PartyBest 三表
-- 合并为一张扁平单表 mppe.PartyDB，并引入字段级来源与时间戳，
-- 通过 MergeEngine（来源优先级 + 时间戳）统一合并写入。
-- =================================================================
local ADDON_NAME, mppe = ...

-- 单表：["Name-Realm"] = 扁平记录
mppe.PartyDB = mppe.PartyDB or {}

-- 字段分组元数据（供 MergeEngine 统一处理来源与时间戳）
mppe.FieldMeta = {
    class  = { srcKey = "classSrc",  tsKey = "classUpdated"  },
    specId = { srcKey = "specSrc",   tsKey = "specUpdated"   },
    iLv    = { srcKey = "iLvSrc",    tsKey = "iLvUpdated"    },
    ks     = { srcKey = "ksSrc",     tsKey = "ksUpdated",  fields = { "ksId", "ksLv", "rating" } },
    best   = { srcKey = "bestSrc",   tsKey = "bestUpdated", fields = { "runs", "score" } },
}

-- 来源优先级（高→低）：MPPE 自报最高，INSP 观察次之，LOR/LKS/AKS 兜底
mppe.SourcePriority = {
    class  = { MPPE = 3, INSP = 2, LOR = 1 },
    specId = { MPPE = 3, INSP = 2, LOR = 1 },
    iLv    = { MPPE = 3, INSP = 2, LOR = 1 },
    ks     = { MPPE = 3, LKS = 2, AKS = 2 , LOR = 1 },
    best   = { MPPE = 3, INSP = 2 },
}

-- 从队伍解析纯名对应的真实全名（跨服队友用其真实服务器，同服回退当前服；解析不到返回 nil）
function mppe.ResolvePartyFullName(personName)
    if type(personName) ~= "string" or personName == "" then return nil end
    local _pure = Ambiguate and Ambiguate(personName, "none") or (personName:gsub("^([^-]+)%-?.*", "%1"))
    -- 自己：直接使用当前服务器
    if _pure == UnitName("player") then
        return string.format("%s-%s", _pure, GetRealmName())
    end
    -- 队伍成员：用 UnitFullName 的真实服务器拼接（同服 realm 为空时回退当前服）
    for _i = 1, GetNumSubgroupMembers() do
        local _name, _realm = UnitFullName("party".._i)
        if _name then
            local _pname = Ambiguate and Ambiguate(_name, "none") or _name
            if _pname == _pure then
                return string.format("%s-%s", _pure, (_realm and _realm ~= "") and _realm or GetRealmName())
            end
        end
    end
    return nil
end

-- 规范化全名：统一为 Name-Realm 作为单表 key
function mppe.NormalizeFullName(personFullName)
    if type(personFullName) ~= "string" or personFullName == "" then return nil end
    -- 已带 -Realm 后缀：原样返回（可能为真实服务器）
    if string.match(personFullName, "([^%-]+)%-(.*)") then
        return personFullName
    end
    -- 纯名：优先从队伍解析真实服务器（跨服队友不能拼当前服，否则写入的 key 与读取不一致导致数据丢失）
    local _full = mppe.ResolvePartyFullName(personFullName)
    if _full then return _full end
    return string.format("%s-%s", personFullName, mppe.Mine.Realm)
end

-- 判断名字是否当前队伍成员（含自己；PartyUpsert 写入前统一过滤非队伍成员，避免公会等外部数据污染 PartyDB）
function mppe.IsInParty(fullName)
    if type(fullName) ~= "string" or fullName == "" then return false end
    -- 提取纯名：手动剥离 -Realm 后缀（不能用 Ambiguate("none")——跨服队友的全名会保留服务器后缀，导致匹配失败）
    local _pureName = (fullName:gsub("^([^-]+)%-?.*", "%1"))
    if _pureName == UnitName("player") then return true end
    for _i = 1, GetNumSubgroupMembers() do
        local _pn = UnitName("party".._i)
        if _pn and _pn == _pureName then return true end
    end
    return false
end

-- 获取或创建记录（扁平，含标识字段）
function mppe.PartyGetOrCreate(fullName)
    local _key = mppe.NormalizeFullName(fullName)
    if not _key then return nil end
    local _rec = mppe.PartyDB[_key]
    if not _rec then
        _rec = { NameRealm = _key }
        local _name, _realm = string.match(_key, "([^%-]+)%-(.*)")
        _rec.name = _name
        _rec.realm = _realm
        _rec.fullName = (_realm == mppe.Mine.Realm) and _name or _key
        mppe.PartyDB[_key] = _rec
    end
    return _rec
end

-- MergeEngine 单字段组写入：按来源优先级 + 时间戳合并
function mppe.PartySetField(rec, group, value, source, bForce)
    local _meta = mppe.FieldMeta[group]
    if not _meta or not rec then return end
    local _oldSrc = rec[_meta.srcKey]
    local _now = time()

    -- 优先级判定：旧来源存在且新来源优先级更低时不覆盖（除非强制）
    local _bWrite = true
    if not bForce and _oldSrc and _oldSrc ~= source then
        local _newPrio = (mppe.SourcePriority[group] or {})[source] or 0
        local _oldPrio = (mppe.SourcePriority[group] or {})[_oldSrc] or 0
        if _newPrio < _oldPrio then _bWrite = false end
    end
    if not _bWrite then return end

    -- 应用写入（整组字段或标量）
    if type(value) == "table" then
        for _i, _f in ipairs(_meta.fields or {}) do
            if value[_f] ~= nil then rec[_f] = value[_f] end
        end
    else
        rec[group] = value
    end
    rec[_meta.srcKey] = source
    rec[_meta.tsKey] = _now
    rec.updated = _now
end

-- 写入成员信息（职业/专精/装等；仅当前队伍成员）
function mppe.PartyUpsert_Member(fullName, data, source)
    if not mppe.IsInParty(fullName) then return end
    local _rec = mppe.PartyGetOrCreate(fullName)
    if not _rec or type(data) ~= "table" then return end
    if data.class  ~= nil then mppe.PartySetField(_rec, "class",  data.class,  source) end
    if data.specId ~= nil then mppe.PartySetField(_rec, "specId", data.specId, source) end
    if data.iLv    ~= nil then mppe.PartySetField(_rec, "iLv",    data.iLv,    source) end
end

-- 写入钥石信息（ksId/ksLv/rating；仅当前队伍成员）
function mppe.PartyUpsert_Keystone(fullName, data, source)
    if not mppe.IsInParty(fullName) then return end
    local _rec = mppe.PartyGetOrCreate(fullName)
    if not _rec or type(data) ~= "table" then return end
    mppe.PartySetField(_rec, "ks", data, source)
end

-- 写入最佳记录（runs/score；仅当前队伍成员）
function mppe.PartyUpsert_Best(fullName, data, source)
    if not mppe.IsInParty(fullName) then return end
    local _rec = mppe.PartyGetOrCreate(fullName)
    if not _rec or type(data) ~= "table" then return end
    mppe.PartySetField(_rec, "best", data, source)
end

-- 清理过期队友数据：不再队且超 1 小时无更新则删除（单表原子清理）
function mppe.PartyCleanup()
    local _current = {}
    local _pName = UnitName("player")
    local _pRealm = GetRealmName()
    _current[string.format("%s-%s", _pName, _pRealm)] = true
    if IsInGroup() and not IsInRaid() then
        for _i = 1, GetNumSubgroupMembers() do
            local _name, _realm = UnitName("party".._i)
            if _name then
                local _full = string.format("%s-%s", _name, (_realm and _realm ~= "") and _realm or _pRealm)
                _current[_full] = true
            end
        end
    end

    -- 标记在队成员
    for _fullName in pairs(_current) do
        local _rec = mppe.PartyGetOrCreate(_fullName)
        if _rec then _rec.inParty = true end
    end

    -- 清理过期或异常记录
    local _now = time()
    for _fullName, _rec in pairs(mppe.PartyDB) do
        if not _current[_fullName] then
            local _lastTs = _rec.updated or 0
            if (_now - _lastTs) > 3600 or _lastTs == 0 then
                mppe.PartyDB[_fullName] = nil
            else
                _rec.inParty = false
            end
        end
    end
end

-- 聚合读取：返回展示用 player 对象（结构兼容旧版，UI 层零改动）
function mppe.GetPlayer(name, realm)
    local _player = {
        name = name, realm = realm, fullName = "", NameRealm = "",
        bYou = false, bSameRealm = false, bLeader = false,
        class = "", spec = 0, hexColor = "", role = "", roleId = 9,
        score = 0, runs = {}, ksLv = 0, ksId = 0, iLv = 0,
    }
    if name == mppe.Mine.Name and realm == mppe.Mine.Realm then
        -- 自己：直接实时 API（不进缓存）
        _player.realm = mppe.Mine.Realm
        _player.fullName = mppe.Mine.Name
        _player.bYou = true
        _player.bSameRealm = true
        _player.NameRealm = string.format("%s-%s", name, mppe.Mine.Realm)
        _player.class = select(2, UnitClass(_player.fullName))
        _player.spec = C_SpecializationInfo.GetSpecializationInfo(C_SpecializationInfo.GetSpecialization()) or 0
        _player.ksId = C_MythicPlus.GetOwnedKeystoneChallengeMapID() or 0
        _player.ksLv = C_MythicPlus.GetOwnedKeystoneLevel() or 0
        _player.iLv = select(2, GetAverageItemLevel()) or 0
        local _summary = C_PlayerInfo.GetPlayerMythicPlusRatingSummary(_player.fullName)
        _player.runs = _summary and _summary.runs or {}
        _player.score = _summary and _summary.currentSeasonScore or 0
    else
        -- 队友：从单表读取（多源合并结果）
        if realm == nil or realm == "" or realm == mppe.Mine.Realm then
            _player.realm = mppe.Mine.Realm
            _player.fullName = name
            _player.bSameRealm = true
        else
            _player.fullName = string.format("%s-%s", name, realm)
            _player.bSameRealm = false
        end
        _player.NameRealm = string.format("%s-%s", name, _player.realm)
        local _rec = mppe.PartyDB[_player.NameRealm]
        if _rec then
            _player.class = _rec.class or ""
            _player.spec = _rec.specId or 0
            _player.iLv = _rec.iLv or 0
            _player.ksId = _rec.ksId or 0
            _player.ksLv = _rec.ksLv or 0
            _player.score = _rec.score or _rec.rating or 0
            _player.runs = _rec.runs or {}
        end
        -- 兜底：缓存缺失时尝试从单位对象获取职业
        if _player.class == "" then _player.class = select(2, UnitClass(_player.fullName)) end
    end
    return _player
end
