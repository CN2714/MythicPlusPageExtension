---@diagnostic disable: inject-field, cast-local-type, param-type-mismatch, missing-parameter, deprecated
local ADDON_NAME, mppe = ...
local pe = mppe.PartyEvent

-- 清空框架内容：子框架/区域全部隐藏并剥离到 UIParent，避免下一次重建时重叠
local function ClearFrameContents(frame)
    if not frame then return end
    
    -- 检查对象类型，确保是真正的Frame
    local objType = type(frame) == "table" and frame.GetObjectType and frame:GetObjectType()
    if not objType or (objType ~= "Frame" and objType ~= "Button" and objType ~= "ScrollFrame") then
        return
    end
    
    -- 安全移除并销毁所有子框架
    local children = {frame:GetChildren()}
    for _, child in ipairs(children) do
        
        -- 检查子对象是否支持脚本操作
        if child.GetObjectType then
            local childType = child:GetObjectType()
            if childType == "Frame" or childType == "Button" then
                child:SetScript("OnUpdate", nil)
                child:SetScript("OnEvent", nil)
                child:SetScript("OnEnter", nil)
                child:SetScript("OnLeave", nil)
            end
        end
        
        child:Hide()
        child:ClearAllPoints()
        child:SetParent(UIParent)
    end
    
    -- 安全移除并销毁所有区域
    local regions = {frame:GetRegions()}
    for _, region in ipairs(regions) do
        if region.GetObjectType and region:GetObjectType() == "FontString" then
            region:SetText("")
        end
        region:Hide()
        region:ClearAllPoints()
        region:SetParent(UIParent)
    end
end

-- 按本赛季副本列表补齐记录（缺失的补 0 值）并排序，同时返回 list / map 两个视图
local function MythicRunsDunFiller(runs)
    local existingMap = {}
    for _, item in ipairs(runs) do
        existingMap[item.challengeModeID] = item
    end

    local runsList = {}
    local runsMap = {}
    if not mppe.CurrentSeasonDungeon then
        return {},{}
    end
    for _, id in ipairs(mppe.CurrentSeasonDungeon) do
        table.insert(runsList, existingMap[id] or {challengeModeID = id, bestRunDurationMS = 0, finishedSuccess = false, mapScore = 0, bestRunLevel = 0})
        table.insert(runsMap, id, existingMap[id] or {challengeModeID = id, bestRunDurationMS = 0, finishedSuccess = false, mapScore = 0, bestRunLevel = 0})
    end   
    
    table.sort(runsList, function(a, b)
        -- 1. 按 mapScore 降序
        if a.mapScore ~= b.mapScore then return a.mapScore > b.mapScore end
        -- 2. 按 bestRunLevel 降序
        if a.bestRunLevel ~= b.bestRunLevel then return a.bestRunLevel > b.bestRunLevel end
        if a.bestRunDurationMS ~= b.bestRunDurationMS then return a.bestRunLevel < b.bestRunLevel end
        -- 3. 按 finishedSuccess 降序 (true > false)
        if a.finishedSuccess ~= b.finishedSuccess then
            -- 布尔转数字比较（Lua 里 true > false 不成立）
            local aSuccess = a.finishedSuccess and 1 or 0
            local bSuccess = b.finishedSuccess and 1 or 0
            return aSuccess > bSuccess
        end
        -- 4. 按 challengeModeID 降序
        return a.challengeModeID < b.challengeModeID
    end)

    return runsList, runsMap
end

-- 毫秒 →「分:秒.十分位」（例：754500 → "12:34.5"）
local function FormatKSTime(ms)
    if type(ms) ~= "number" or ms <= 0 then return "0:00.000" end
    local totalSeconds = ms / 1000
    local minutes = math.floor(totalSeconds / 60)
    local seconds = totalSeconds % 60
    return string.format("%d:%04.1f", minutes, seconds)
end

-- 副本名称：优先用客户端 API 的本地化全称（如「艾拉-卡拉，回响之城」），拿不到时退回本地化短名
local function GetDungeonName(dungeonId)
    local _entry = type(dungeonId) == "number" and mppe.Dungeons and mppe.Dungeons[dungeonId]
    if not _entry then return "UNKNOWN" end
    local _fullName = C_ChallengeMode.GetMapUIInfo(dungeonId)
    if _fullName and _fullName ~= "" then return _fullName end
    return (mppe.Translate and mppe.Translate[_entry.Name]) or _entry.Name or "UNKNOWN"
end

local function GeneratePlayerRunsRows(name, realm, score, hexColor, runsList)
    if type(runsList) ~= "table" then return nil end

    -- 行结构：left = 左列（左对齐），right = 右列（右对齐）；right 为 nil 时该行只占左列
    local _rows = {}
    table.insert(_rows, { left = string.format("|c%s%s(%s)|r - %s", hexColor, name, realm, mppe.Translate['Person Best M+ Records']) })
    table.insert(_rows, { left = string.format("%s|c%s%s|r", mppe.Translate['SeasonRating:'], mppe.GetColorByScore(score or 0, MythicPlusPageExtensionDB.PartyKeyStone_ScoreColorStyle, true), score or 0) })
    table.insert(_rows, { left = " " })   -- 空行：分隔标题与记录列表

    for i, r in pairs(runsList) do
        -- 左列：层数 + 副本名（层数固定两位、数字等宽 → 副本名天然成列）
        local _lv = (r.bestRunLevel and r.bestRunLevel > 0) and string.format("%02d", r.bestRunLevel) or "00"
        local _lvText = string.format("|c%s%s|r", r.finishedSuccess and "ff00ff00" or "ffff0000", _lv)
        local _dunName = GetDungeonName(r.challengeModeID)
        -- 右列：分数 + 时长（时长随是否完成着色；无记录用灰色 No Record）
        -- 分数保持「无色」写法（与旧版一致）：它是行内唯一不带色码的数值，不要写死白色
        local _scoreText = r.mapScore > 0 and tostring(r.mapScore) or string.format("|c00707070%s|r", mppe.Translate['No Record'])
        local _timeText = (r.bestRunDurationMS or 0) > 0 and string.format("|c%s(%s)|r", r.finishedSuccess and "ff00ff00" or "ffff0000", FormatKSTime(r.bestRunDurationMS)) or ""
        table.insert(_rows, {
            left  = string.format("%s |c00ffffff%s|r", _lvText, _dunName),
            right = (_timeText ~= "") and string.format("%s %s", _scoreText, _timeText) or _scoreText,
        })
    end
    return _rows
end

local function GenerateDungeonRunsRows(memberList, dungeonId)
    if type(memberList) ~= "table" or not dungeonId or dungeonId == 0 then return nil end
    local _dunName = GetDungeonName(dungeonId)
    -- 行结构：left = 左列（层数 + 玩家名），right = 右列（分数 + 时长）
    local _rows = {}
    table.insert(_rows, { left = string.format("%s - %s", _dunName, mppe.Translate['Dungeon Best M+ Records']) })
    table.insert(_rows, { left = " " })   -- 空行：分隔标题与记录列表
    for i, m in ipairs(memberList) do
        local _r = m.runsMap[dungeonId]
        if _r then
            local _lv = (_r.bestRunLevel and _r.bestRunLevel > 0) and string.format("%02d", _r.bestRunLevel) or "00"
            local _lvText = string.format("|c%s%s|r", _r.finishedSuccess and "ff00ff00" or "ffff0000", _lv)
            local _nameText = string.format("|c%s%s(%s)|r", m.hexColor, m.name, m.realm)
            local _scoreText = _r.mapScore > 0 and tostring(_r.mapScore) or string.format("|c00707070%s|r", mppe.Translate['No Record'])
            local _timeText = (_r.bestRunDurationMS or 0) > 0 and string.format("|c%s(%s)|r", _r.finishedSuccess and "ff00ff00" or "ffff0000", FormatKSTime(_r.bestRunDurationMS)) or ""
            table.insert(_rows, {
                left  = string.format("%s %s", _lvText, _nameText),
                right = (_timeText ~= "") and string.format("%s %s", _scoreText, _timeText) or _scoreText,
            })
        end
    end
    return _rows
end

-- 渲染「两列工具提示」：left 左对齐、right 右对齐
-- AddDoubleLine 是 GameTooltip 的原生两列 API：右列自动贴住右边缘，tooltip 宽度按最宽的行自适应 → 跨行的右列天然成列
-- 刻意不改字体、也不传颜色参数：一律使用 tooltip 自己的默认字体与默认文字色
--（GameTooltip 是共享帧，字体/颜色改动都会残留给物品、法术等其它 tooltip，所以这里不碰）
local function ShowRowsTooltip(owner, rows)
    if type(rows) ~= "table" or #rows == 0 then return end
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    -- AddLine / AddDoubleLine 是累加语义：构建前显式清空，避免重复 OnEnter 叠加多份内容
    GameTooltip:ClearLines()
    for _i, _row in ipairs(rows) do
        if _row.right and _row.right ~= "" then
            GameTooltip:AddDoubleLine(_row.left, _row.right)
        else
            GameTooltip:AddLine(_row.left)
        end
    end
    GameTooltip:Show()
end

local function GeneratePartyInfoV2()  
    -- REF AngryKeystones
    local _weeklyChest = ChallengesFrame.WeeklyInfo.Child.WeeklyChest
    _weeklyChest:ClearAllPoints()
    _weeklyChest:SetPoint("LEFT", 100, 0)
    local _description = ChallengesFrame.WeeklyInfo.Child.Description
    _description:ClearAllPoints()
    _description:SetPoint("TOP", ChallengesFrame, "TOP", 0, -50)
    local _runStatus = ChallengesFrame.WeeklyInfo.Child.WeeklyChest.RunStatus
    _runStatus:SetWordWrap(true)
    _runStatus:SetSize(200, 90)

    local xoffset = MythicPlusPageExtensionDB.PartyKeyStone_xOffset and MythicPlusPageExtensionDB.PartyKeyStone_xOffset or 0
    local yoffset = MythicPlusPageExtensionDB.PartyKeyStone_yOffset and MythicPlusPageExtensionDB.PartyKeyStone_yOffset or 0
    local pCount = 1
    if IsInGroup() and not IsInRaid() then
        pCount = GetNumGroupMembers()
    end

    local PartyInfoFrame = _G["mppePartyInfoFrame"] or CreateFrame("Frame" ,"mppePartyInfoFrame", ChallengesFrame)
    ClearFrameContents(PartyInfoFrame) -- 关键：每次运行都先清空
    GameTooltip:Hide()                 -- 重建行会销毁 FontString（不触发 OnLeave），先把可能悬着的 tooltip 收掉
    PartyInfoFrame:SetSize(MythicPlusPageExtensionDB.PartyInfo_Width and MythicPlusPageExtensionDB.PartyInfo_Width or 265, 135)
    PartyInfoFrame:SetPoint("BOTTOMRIGHT", ChallengesFrame, "BOTTOMRIGHT", -10 + xoffset, 75 + yoffset)
    PartyInfoFrame:Show() -- 确保显示
    
    local pif_bg = PartyInfoFrame:CreateTexture(nil, "BACKGROUND")
    pif_bg:SetAllPoints()
    pif_bg:SetAtlas("ChallengeMode-guild-background")
    
    local pif_title = PartyInfoFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    pif_title:SetPoint("TOPLEFT", 5, -5)
    pif_title:SetText(mppe.Translate['PartyInfo'])
    pif_title:SetFont(ChatFontNormal:GetFont(), 15, "OUTLINE")

    local pif_lfgTitle = PartyInfoFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    pif_lfgTitle:SetPoint("TOPRIGHT", -5, -5)
    pif_lfgTitle:SetSize(150,pif_title:GetHeight())
    pif_lfgTitle:SetText(mppe.LFG_Info and mppe.LFG_Info.typeName)
    pif_lfgTitle:SetFont(ChatFontNormal:GetFont(), 15, "OUTLINE")
    pif_lfgTitle:SetTextColor(1,1,1,1)
    local _lfgTooltip = mppe.LFG_Info.titleName or nil
    pif_lfgTitle:SetScript("OnEnter", function(self)
        if _lfgTooltip then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetText(_lfgTooltip)
            GameTooltip:Show()
        end
    end)
    pif_lfgTitle:SetScript("OnLeave", function(self) GameTooltip:Hide() end)

    local pif_line = PartyInfoFrame:CreateTexture(nil, "ARTWORK")
    pif_line:SetSize(PartyInfoFrame:GetWidth(), 1)
    pif_line:SetAtlas("spec-dividerline", false)
    pif_line:SetPoint("TOP", PartyInfoFrame, "TOP", 0, -22)

    local _pMember = {}
    for i = 1, pCount do
        local _name, _realm 
        if mppe.Mine.Name == nil then mppe.Mine.Name = UnitName("Player") end
        if mppe.Mine.Realm == nil then mppe.Mine.Realm = GetRealmName() end
        if i == 1 then 
            _name, _realm = mppe.Mine.Name, mppe.Mine.Realm
        else _name, _realm = UnitFullName("Party"..tostring(i-1)) end
        local _player = mppe.GetPlayer(_name, _realm)
        _player.bLeader = UnitIsGroupLeader(_player.fullName)
        
        local _classSpec = mppe.ClassSpec[_player.class]
        if _classSpec then _player.hexColor = mppe.ClassSpec[_player.class][0].color else _player.hexColor = "ffffffff" end

        _player.role = UnitGroupRolesAssigned(_player.fullName)
        if _player.role == "TANK" then _player.roleId = 1 elseif _player.role == "HEALER" then _player.roleId = 2 elseif _player.role == "DAMAGER" then _player.roleId = 3 end

        _pMember[i] = _player
        _player.runsList, _player.runsMap = MythicRunsDunFiller(_player.runs or {})
    end
    table.sort(_pMember, function(a, b)
        if a.bYou ~= b.bYou then return a.bYou end
        if a.roleId ~= b.roleId then return a.roleId < b.roleId end
        return a.name < b.name
    end)

    local pif_Member = {}
    for i, _p in ipairs(_pMember) do        
        local party = CreateFrame("Frame", nil, PartyInfoFrame)
        party:SetSize(PartyInfoFrame:GetWidth(), 21.5)
        if i == 1 then 
            party:SetPoint("TOP",pif_line,"BOTTOM", 0, -2)
        else 
            party:SetPoint("TOP",pif_Member[i-1],"BOTTOM", 0, 0)
        end

        -- 高亮背景（引用计数：鼠标在行内子元素间移动会 OnLeave/OnEnter 交错，直接 Show/Hide 会闪）
        local highlight = party:CreateTexture(nil, "BACKGROUND")
        highlight:SetAllPoints(party)
        highlight:SetColorTexture(1, 1, 1, 0.1)
        highlight:Hide()
        party.highlight = highlight
        
        party.mouseOverCount = 0
        
        local function AddMouseOver(self)
            self.mouseOverCount = self.mouseOverCount + 1
            if self.mouseOverCount == 1 then
                self.highlight:Show()
            end
        end
        
        local function RemoveMouseOver(self)
            self.mouseOverCount = math.max(0, self.mouseOverCount - 1)
            if self.mouseOverCount == 0 then
                self.highlight:Hide()
            end
        end

        _p.ksId = tonumber(_p.ksId)
        _p.ksLv = tonumber(_p.ksLv)
        if type(_p.ksId) ~= "number" then _p.ksId = 0 end
        if type(_p.ksLv) ~= "number" then _p.ksLv = 0 end
        -- 记录行改为「左列=层数+副本 / 右列=分数+时长」的两列结构（由 ShowRowsTooltip 渲染）
        party.pRecordRows = GeneratePlayerRunsRows(_p.name, _p.realm, _p.score, _p.hexColor, _p.runsList)
        party.dRecordRows = GenerateDungeonRunsRows(_pMember, _p.ksId)
        local _, _specName, _, _pIconId, _specRole, _, _className = GetSpecializationInfoByID(_p.spec or 0)

        -- 1. 职业数据（只取一次）
        local classData = _p.class and mppe.ClassSpec[_p.class]

        -- 2. 关键字段兜底：缓存里没有时再从单位读一次
        if not _p.class then _p.class = select(2, UnitClass(_p.fullName)) end

        -- 3. 获取专精数据（优先具体专精，其次通用专精[0]）
        local specData
        if classData then
            if _p.spec ~= nil then specData = classData[_p.spec] or classData[0]
            else specData = classData[0] end
        end

        -- 4. 用 specData 安全填充 _specName 和 _pIconId（保留 GetSpecializationInfoByID 的真实结果）
        if not _specName then _specName = mppe.Translate[specData and specData.name or "UNKNOWN"] end
        if not _pIconId then _pIconId = (specData and specData.icon) or 0 end
        -- 5. _specRole 和 _className 的防御性填充
        if not _specRole then _specRole = mppe.Translate["UNKNOWN"] end
        if not _className then _className = _p.class and mppe.Translate[_p.class] or "UNKNOWN" end

        local pIcon = party:CreateTexture(nil, "OVERLAY")        
        pIcon:SetSize(20, 20)
        pIcon:SetPoint("LEFT",party,"LEFT", 16, 0)
        if tonumber(_pIconId) then pIcon:SetTexture(_pIconId) 
        else pIcon:SetAtlas(_pIconId) end
        pIcon.tooltipText = string.format("%s(%s) %s", _specName, mppe.Translate[_specRole], _className)
        pIcon:SetScript("OnEnter", function(self)
            AddMouseOver(self:GetParent())
            if self.tooltipText then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetText(self.tooltipText)
                GameTooltip:Show()
            end
        end)
        pIcon:SetScript("OnLeave", function(self)
            RemoveMouseOver(self:GetParent())
            GameTooltip:Hide()
        end)
        
        local pRole = party:CreateTexture(nil, "ARTWORK")
        pRole:SetSize(20, 20)
        if _specRole == "TANK" then 
            _specRole = 1 
        elseif _specRole == "HEALER" then 
            _specRole = 2 
        else 
            _specRole = 3 
        end
        local _roleId = (_p.roleId == 9 and _specRole) and _specRole or _p.roleId
        if _roleId == 1 then 
            pRole:SetAtlas("GM-icon-role-tank", false)
        elseif _roleId == 2 then 
            pRole:SetAtlas("GM-icon-role-healer", false)
        else 
            pRole:SetAtlas("GM-icon-role-dps", true) 
        end
        pRole:SetPoint("RIGHT",pIcon,"LEFT", 3, -1)
        pRole:SetTexCoord(1, 0, 0, 1)
        local pLeader = party:CreateTexture(nil, "ARTWORK")
        pLeader:SetSize(14, 14)
        if _p.bLeader then 
            pLeader:SetAtlas("plunderstorm-glues-icon-leader", false)
            pLeader:SetPoint("BOTTOM",pRole,"TOP", 0, -9)
            pRole:SetPoint("RIGHT",pIcon,"LEFT", 3, -3)
        end

        local _name = _p.name
        -- 设置项 PartyInfo_ItemLevel 为真时才显示装等，否则不加装等前缀
        if MythicPlusPageExtensionDB.PartyInfo_ItemLevel then
            _p.iLv = tonumber(_p.iLv)
            if _p.iLv and _p.iLv > 0 then
                _name = string.format("%d|T:1:1|t|||T:1:1|t%s", _p.iLv, _name)
            else
                -- 装等未知：用灰色问号占位
                _name = string.format("|c00707070...|r|T:1:1|t|||T:1:1|t%s", _name)
            end
        else
             _name = string.format("|T:1:1|t%s", _name)
        end
        local pName = party:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")        
        pName:SetWordWrap(false)
        pName:SetJustifyH("LEFT")
        pName:SetPoint("LEFT",pIcon,"RIGHT", 0, 0)
        pName:SetText(_name)
        pName:SetWidth(party:GetWidth()/2 - 20)
        pName:SetTextColor(mppe.ColorHexToRGBA(_p.hexColor))
        pName:SetScript("OnEnter", function(self)
            AddMouseOver(self:GetParent())
            ShowRowsTooltip(self, self:GetParent().pRecordRows)
        end)
        pName:SetScript("OnLeave", function(self)
            RemoveMouseOver(self:GetParent())
            GameTooltip:Hide()
        end)

        local _pks = ""
        if _p.ksId > 0 and mppe.Dungeons[_p.ksId] then
            _pks = string.format("%s%s",(_p.ksLv > 0 and _p.ksLv or ""), mppe.Translate[mppe.Dungeons[_p.ksId].Name])
        end

        local pKs = party:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
        pKs:SetWidth(party:GetWidth()/2 - 20)
        pKs:SetWordWrap(false)
        pKs:SetPoint("RIGHT", party, "RIGHT", -2, 0)
        pKs:SetPoint("LEFT", pName, "RIGHT", 2, 0)
        pKs:SetJustifyH("RIGHT")
        pKs:SetText(_pks)
        -- 钥石与预创建队伍活动副本一致时，钥石文本变黄（提示"这本=谁的钥匙"）
        -- 注意：钥石是 challengeModeID，活动是 mapID，先经 GetMapUIInfo 归一化到 mapID 再比较
        local _ksMapID = 0
        if _p.ksId and _p.ksId > 0 then
            local _, _id, _, _, _, _mapID = C_ChallengeMode.GetMapUIInfo(_p.ksId)
            _ksMapID = _mapID or _id or 0
        end
        if _ksMapID > 0 and mppe.LFG_Info and _ksMapID == (mppe.LFG_Info.mapID or 0) then
            pKs:SetTextColor(1, 1, 0.39) -- 黄色            
        end
        pKs:SetScript("OnEnter", function(self)
            AddMouseOver(self:GetParent())
            ShowRowsTooltip(self, self:GetParent().dRecordRows)
        end)
        pKs:SetScript("OnLeave", function(self) 
            RemoveMouseOver(self:GetParent())
            GameTooltip:Hide()
        end)
        
        party:SetScript("OnEnter", function(self)
            AddMouseOver(self)
        end)
        
        party:SetScript("OnLeave", function(self)
            RemoveMouseOver(self)
        end)
        
        pif_Member[i] = party
    end
    PartyInfoFrame.Member = pif_Member
end

-- 刷新/初始化小队信息框架（防重入：执行中收到新请求则标记，跑完再补一次）
function mppe.RefreshPartyInfo(source)
    if not MythicPlusPageExtensionDB.PartyKeyStone_Enable then return end
    if not (PVEFrame:IsShown() and ChallengesFrame) then return end
    
    -- 如果正在执行，标记需要重新刷新
    if mppe.isGeneratingPartyInfo then
        mppe.needsRefreshPartyInfo = true
        return
    end
    
    mppe.isGeneratingPartyInfo = true
    mppe.needsRefreshPartyInfo = false
    
    C_Timer.After(0.1, function()
        GeneratePartyInfoV2()
        mppe.isGeneratingPartyInfo = false
        
        -- 如果在执行期间有新的刷新请求，再次执行
        if mppe.needsRefreshPartyInfo then
            mppe.RefreshPartyInfo()
        end
    end)
end