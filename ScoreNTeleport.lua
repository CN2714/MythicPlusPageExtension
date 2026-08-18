local ADDON_NAME, mppe = ...
-- REF https://wago.io/uPxmk1k-L https://wago.io/ud2YBS4WC
local function SelectBestSpellID(spellIDs)
    if (not spellIDs) then
        return
    end
    if #spellIDs > 1 then
        for _, spellID in next, spellIDs do
            if C_SpellBook.IsSpellInSpellBook(spellID) then
                return spellID
            end
        end
    end
    return spellIDs[1]
end
-- REF https://wago.io/uPxmk1k-L https://wago.io/ud2YBS4WC
local function UpdateGameTooltip(parent, spellID)
    -- 无有效法术ID时直接返回（空TeleportID副本仅展示，不触发Tooltip）
    if not spellID then return end
    local Button_OnEnter = parent:GetScript("OnEnter")
    if (not Button_OnEnter) then
        return
    end
    Button_OnEnter(parent)
    if C_SpellBook.IsSpellInSpellBook(spellID) then
        local spellCooldown = C_Spell.GetSpellCooldown(spellID)

        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(C_Spell.GetSpellName(spellID) or TELEPORT_TO_DUNGEON)
        if issecretvalue(spellCooldown.startTime) or issecretvalue(spellCooldown.duration) then -- 12.0秘密值判断
            GameTooltip:AddLine(mppe.Translate['Cannot get spell info while in the current state.'], 1, 0, 0)
        elseif not spellCooldown.startTime or not spellCooldown.duration then
            GameTooltip:AddLine(SPELL_FAILED_NOT_KNOWN, 1, 0, 0)
        elseif spellCooldown.duration == 0 then
            GameTooltip:AddLine(mppe.Translate['Click To Teleport'], 0, 1, 0)
        else
            GameTooltip:AddLine(SPELL_FAILED_NOT_READY..":"..SecondsToTime(ceil(spellCooldown.startTime + spellCooldown.duration - GetTime())), 1, 0, 0)
        end
    else
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(C_Spell.GetSpellName(spellID) or TELEPORT_TO_DUNGEON)
        GameTooltip:AddLine(SPELL_FAILED_NOT_KNOWN, 1, 0, 0)
    end
    GameTooltip:Show()
end

-- 获取字符串UTF8长度
local function utf8len(input)
    local len = string.len(input)
    local left = len
    local cnt = 0
    local arr = {0, 0xc0, 0xe0, 0xf0, 0xf8, 0xfc}
    while left ~= 0 do
        local tmp = string.byte(input, -left)
        local i = #arr
        while arr[i] do
            if tmp >= arr[i] then
                left = left - i
                break
            end
            i = i - 1
        end
        cnt = cnt + 1
    end
    return cnt
end

-- 在字符串的指定字符索引位置插入换行符
local function InsertNewlineAt(str, charIndex)
    if not str or charIndex <= 0 or charIndex > utf8len(str) then
        return str -- 参数无效，返回原字符串
    end

    local len = string.len(str)
    local bytePos = len
    local left = len
    local cnt = 0
    local arr = {0, 0xc0, 0xe0, 0xf0, 0xf8, 0xfc}
    while left ~= 0 do
        local tmp = string.byte(str, -left)
        local i = #arr
        while arr[i] do
            if tmp >= arr[i] then
                left = left - i
                break
            end
            i = i - 1
        end
        if cnt == charIndex then
            bytePos = len - left
            left = 0
        end
        cnt = cnt + 1
    end
    -- 使用utf8.offset找到第 charIndex 个字符的字节位置
    if not bytePos then
        return str
    end
    -- 在指定字节位置前插入换行符
    return string.sub(str, 1, bytePos - 1) .. "\n" .. string.sub(str, bytePos)
end

local function ClearDungeonIconsOtherText(DungeonIcons)
    if not DungeonIcons then return end

    local regions = {DungeonIcons:GetRegions()}
    for _, region in ipairs(regions) do
        if region:GetObjectType() == "FontString" then
            if region ~= DungeonIcons.HighestLevel and region:GetName() == nil then              
                region:SetText("")
                region:Hide()
                region:ClearAllPoints()
                region:SetParent(UIParent)
            end
        end
    end
end

-- 生成/刷新[分数&传送门]控件（循环遍历每个副本图标）
local function GenerateScoreNTeleport()
    -- 赛季副本表由主文件保证存在；仅首次运行时填充并排序
    mppe.CurrentSeasonDungeon = mppe.CurrentSeasonDungeon or {}
    local _firstRun = #mppe.CurrentSeasonDungeon == 0
    for _index, _dungeonIcon in ipairs(ChallengesFrame.DungeonIcons) do
        if _firstRun then table.insert(mppe.CurrentSeasonDungeon, _dungeonIcon.mapID) end
        local _s = select(2, C_MythicPlus.GetSeasonBestAffixScoreInfoForMap(_dungeonIcon.mapID)) or 0
        if MythicPlusPageExtensionDB.ScoreNTeleport_TryClearOther and MythicPlusPageExtensionDB.ScoreNTeleport_TryClearOther == true then ClearDungeonIconsOtherText(_dungeonIcon) end
        _dungeonIcon.HighestLevel:ClearAllPoints()
        _dungeonIcon.HighestLevel:SetPoint("TOP", ChallengesFrame.DungeonIcons[_index], 0, -2) 
        _dungeonIcon.HighestLevel:SetFont(_dungeonIcon.HighestLevel:GetFont() or STANDARD_TEXT_FONT, MythicPlusPageExtensionDB.ScoreNTeleport_DunLevel_FontSize, "OUTLINE")

        local teleportID = mppe.Dungeons[_dungeonIcon.mapID] and SelectBestSpellID(mppe.Dungeons[_dungeonIcon.mapID].TeleportID)
        local dunShortname = mppe.Dungeons[_dungeonIcon.mapID] and mppe.Translate[mppe.Dungeons[_dungeonIcon.mapID].Name]

        -- REF https://wago.io/uPxmk1k-L https://wago.io/ud2YBS4WC
        local dungeonTeleport = _G["mppeDT".._dungeonIcon.mapID] or CreateFrame("Button", "mppeDT".._dungeonIcon.mapID, _dungeonIcon, "InsecureActionButtonTemplate")
        -- 无有效传送法术ID时不注册点击（空TeleportID副本仅展示名字/分数）
        if MythicPlusPageExtensionDB.ScoreNTeleport_EnableTeleport and MythicPlusPageExtensionDB.ScoreNTeleport_EnableTeleport == true and teleportID then
            dungeonTeleport:RegisterForClicks("AnyDown", "AnyUp")
            dungeonTeleport:SetAttribute("type", "spell")
            dungeonTeleport:SetScript("OnEnter", function() UpdateGameTooltip(_dungeonIcon, teleportID) end)
            dungeonTeleport:SetScript("OnLeave", function() if GameTooltip:IsOwned(_dungeonIcon) then GameTooltip:Hide() end end)
            dungeonTeleport:SetAllPoints(_dungeonIcon)
            dungeonTeleport:SetAttribute("spell", teleportID)
        end
        local dunNameWordWarp = false
        local dungeonName = _G["mppeDN".._dungeonIcon.mapID] or dungeonTeleport:CreateFontString("mppeDN".._dungeonIcon.mapID, "OVERLAY", "GameFontNormal")
        dungeonName:ClearAllPoints()
        dungeonName:SetPoint("BOTTOM", ChallengesFrame.DungeonIcons[_index], 0, 0)
        dungeonName:SetTextColor(1,1,1,1)
        dungeonName:SetFont(dungeonName:GetFont() or STANDARD_TEXT_FONT, MythicPlusPageExtensionDB.ScoreNTeleport_DunShortName_FontSize, "OUTLINE")
        dungeonName:SetWordWrap(dunNameWordWarp)
        if dunShortname and utf8len(dunShortname) > MythicPlusPageExtensionDB.ScoreNTeleport_DunShortName_PerLine then
            dunShortname = InsertNewlineAt(dunShortname, MythicPlusPageExtensionDB.ScoreNTeleport_DunShortName_PerLine)
            dungeonName:SetHeight(26)
            dunNameWordWarp = true
            dungeonName:SetWordWrap(dunNameWordWarp)
            dungeonName:SetPoint("BOTTOM", ChallengesFrame.DungeonIcons[_index], 0, -5)
        end
        dungeonName:SetText(dunShortname)
        dungeonName:SetWidth(_dungeonIcon:GetWidth() + 4)

        local dungeonName_bg = _G["mppeDN".._dungeonIcon.mapID.."_bg"] or dungeonTeleport:CreateTexture("mppeDN".._dungeonIcon.mapID.."_bg", "BACKGROUND")
        dungeonName_bg:SetSize(ChallengesFrame.DungeonIcons[_index]:GetWidth(), dungeonName:GetHeight() + 2)
        if dunNameWordWarp then dungeonName_bg:SetSize(ChallengesFrame.DungeonIcons[_index]:GetWidth(), dungeonName:GetHeight() - 4) end
        dungeonName_bg:SetAtlas("ChallengeMode-guild-background")
        dungeonName_bg:ClearAllPoints()
        dungeonName_bg:SetPoint("BOTTOM", ChallengesFrame.DungeonIcons[_index], 0, 0)
        dungeonName_bg:SetVertexColor(0, 0, 0, 0.6)
        
        local dungeonScore = _G["mppeDS".._dungeonIcon.mapID] or dungeonTeleport:CreateFontString("mppeDS".._dungeonIcon.mapID, "OVERLAY", "GameFontNormal")
        dungeonScore:ClearAllPoints()
        dungeonScore:SetPoint("CENTER", ChallengesFrame.DungeonIcons[_index], 0, -3)
        dungeonScore:SetFont(dungeonScore:GetFont() or STANDARD_TEXT_FONT, MythicPlusPageExtensionDB.ScoreNTeleport_DunScore_FontSize, "OUTLINE")
        dungeonScore:SetTextColor(_dungeonIcon.HighestLevel:GetTextColor())
        dungeonScore:SetText(_s > 0 and _s or "")

        if MythicPlusPageExtensionDB.ScoreNTeleport_UseOldStyle then
            dungeonName:ClearAllPoints()
            dungeonName_bg:ClearAllPoints()
            _dungeonIcon.HighestLevel:ClearAllPoints()
            dungeonScore:ClearAllPoints()
            dungeonName:SetTextColor(_dungeonIcon.HighestLevel:GetTextColor())
            dungeonName:SetPoint("TOP", ChallengesFrame.DungeonIcons[_index], 0, -2)
            dungeonName_bg:SetVertexColor(0, 0, 0, 0)
            dungeonName_bg:SetPoint("TOP", ChallengesFrame.DungeonIcons[_index], 0, -2)
            _dungeonIcon.HighestLevel:SetPoint("BOTTOM", ChallengesFrame.DungeonIcons[_index], 0, 2) 
            dungeonScore:SetPoint("CENTER", ChallengesFrame.DungeonIcons[_index], 0, 1.5)
        end
        dungeonTeleport:SetFrameLevel(_dungeonIcon:GetFrameLevel() + 10) -- 防止其他插件的东西阻挡失效
        if MythicPlusPageExtensionDB.ScoreNTeleport_ScoreColorStyle ~= "highestlv" then
            dungeonScore:SetTextColor(mppe.GetColorByScore(_s * 8, MythicPlusPageExtensionDB.ScoreNTeleport_ScoreColorStyle))
        end
    end
    if _firstRun then 
        table.sort(mppe.CurrentSeasonDungeon, function(a, b)
                return a < b
        end)
    end
end

-- 刷新/初始化[分数&传送门]控件
function mppe.RefreshScoreNTeleport()
    if MythicPlusPageExtensionDB.ScoreNTeleport_Enable then
        -- 延迟执行，确保首次打开窗体时能正确取到mapid
        if ChallengesFrame then 
            C_Timer.After(0.02, function() GenerateScoreNTeleport() end)
        end
    end
end
--==================================================================
-- 通报事件控制器
local sendTeleportInfo_eventFrame = CreateFrame("Frame")
local TpIdToDunID = {}
-- 通报传送法术（开始/完成共用；templateKey为本地化文案key）
local function AnnounceTeleport(spellID, templateKey)
    local _dunName = C_ChallengeMode.GetMapUIInfo(TpIdToDunID[spellID]) or "unknown"
    if IsInGroup() then
        C_ChatInfo.SendChatMessage("[MPPE]"..string.format(mppe.Translate[templateKey], C_Spell.GetSpellLink(spellID), _dunName), IsInRaid() and "RAID" or "PARTY")
    end
end
sendTeleportInfo_eventFrame:RegisterEvent("UNIT_SPELLCAST_START")
sendTeleportInfo_eventFrame:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
sendTeleportInfo_eventFrame:SetScript("OnEvent", function(self, event, unitTarget, castGUID, spellID)
    if event ~= "UNIT_SPELLCAST_START" and event ~= "UNIT_SPELLCAST_SUCCEEDED" then return end
    if not MythicPlusPageExtensionDB.ScoreNTeleport_Enable or not MythicPlusPageExtensionDB.ScoreNTeleport_SendTeleportInfo then return end
    if (unitTarget ~= "player") or (not spellID) or (not TpIdToDunID[spellID]) then return end

    if MythicPlusPageExtensionDB.ScoreNTeleport_STI_CastStatus == "caststart" and event == "UNIT_SPELLCAST_START" then
        AnnounceTeleport(spellID, 'Activating teleport %s, destination set to [%s]!')
    elseif MythicPlusPageExtensionDB.ScoreNTeleport_STI_CastStatus == "castsucceeded" and event == "UNIT_SPELLCAST_SUCCEEDED" then 
        AnnounceTeleport(spellID, 'Teleport %s completed, arrived at destination [%s]!')
    end  
end)
local function BuildTpIdToDunID()
    TpIdToDunID = {} 
    for dungeonID, dungeonInfo in pairs(mppe.Dungeons) do
        if type(dungeonInfo) == "table" and dungeonInfo.TeleportID and type(dungeonInfo.TeleportID) == "table" then
            for _, teleportID in ipairs(dungeonInfo.TeleportID) do
                TpIdToDunID[teleportID] = dungeonID
            end
        end
    end       
    return TpIdToDunID
end
BuildTpIdToDunID()