local ADDON_NAME, mppe = ...
-- 初始化开始
if not mppe then mppe = {} end
-- REF https://www.curseforge.com/wow/addons/keystoneloot
mppe.Translate = setmetatable({}, {
    __index = function(t, key)
        rawset(t, key, key);
        return key;
    end
});
mppe.Mine = mppe.Mine or {}
mppe.Mine.Name = mppe.Mine.Name or UnitName("Player")
mppe.Mine.Realm = mppe.Mine.Realm or GetRealmName()
mppe.CurrentSeasonDungeon = {} -- 赛季副本ID列表（由ScoreNTeleport首次填充并排序）

local MythicPlusPageExtension = CreateFrame("Frame")
MythicPlusPageExtension:RegisterEvent("ADDON_LOADED")
MythicPlusPageExtension:SetScript("OnEvent", function(self, event, addonName)
    if event == "ADDON_LOADED" and addonName == ADDON_NAME then
        -- 1. 加载/初始化主数据库
        MythicPlusPageExtensionDB = MythicPlusPageExtensionDB or {}
        -- 定义默认配置（仅在首次使用时生效）
        local defaultSettings = {
            ScoreNTeleport_Enable = true,
            ScoreNTeleport_TryClearOther = true,
            ScoreNTeleport_ScoreColorStyle = "highestlv",
            ScoreNTeleport_EnableTeleport = true,
            ScoreNTeleport_SendTeleportInfo = true,
            ScoreNTeleport_STI_CastStatus = "castsucceeded",
            ScoreNTeleport_UseOldStyle = false,
            ScoreNTeleport_DunShortName_FontSize = 13,
            ScoreNTeleport_DunShortName_PerLine = 7,
            ScoreNTeleport_DunLevel_FontSize = 22,
            ScoreNTeleport_DunScore_FontSize = 22,
            PartyKeyStone_Enable = true,
            PartyInfo_ItemLevel = true,
            PartyKeyStone_ScoreColorStyle = "raiderio",
            PartyInfo_Width = 265,
            PartyKeyStone_xOffset = 0,
            PartyKeyStone_yOffset = 0,
            WeeklyReport_Enable = true,
            WeeklyReport_HideRaiderIOFrame = true,
            WeeklyReport_ShowWeeklyTOP8 = true,
            WeeklyReport_FontSize = 15,
            WeeklyReport_FrameWidth = 400,
            WeeklyReport_FrameHeightCorrection = 0,
            WeeklyReport_ShowScrollBar = true,
            ToastQuickHide_Enable = false,
            GuildAndPartyKS_Enable = true,
            GuildAndPartyKS_ShowParty = false,
            GuildAndPartyKS_SlashKey = false
        }
        -- 2. (可选但推荐) 确保每个设置项都有默认值
        for key, defaultValue in pairs(defaultSettings) do
            if MythicPlusPageExtensionDB[key] == nil then
                MythicPlusPageExtensionDB[key] = defaultValue
            end
        end
        -- 3. 触发插件主初始化流程
        self:UnregisterEvent("ADDON_LOADED") -- 只需执行一次
    end
end)

local init = false
hooksecurefunc("PanelTemplates_SetTab", function(frame, id)
    if not init and frame == PVEFrame then
        if not init and id == 3 then
            ChallengesFrame:HookScript("OnShow", function() mppe.RefreshScoreNTeleport() mppe.WeeklyFrameShowOrHide(true) mppe.RefreshPartyInfo() end)
            ChallengesFrame:HookScript("OnHide", function() mppe.WeeklyFrameShowOrHide(false) end)
            init = true
        end
    end
end)
-- ==================================================================
-- 单表数据模型由 Model/PartyModel.lua 提供：
--   mppe.PartyDB / mppe.PartyUpsert_Member / mppe.PartyUpsert_Keystone
--   mppe.PartyUpsert_Best / mppe.GetPlayer / mppe.PartyCleanup
mppe.PartyEvent = CreateFrame("Frame")

mppe.LFG_Info = {
    titleName = "",
    typeName = "",
    modeName = "",
    activityID = 0,
    groupFinderActivityGroupID = 0,
    mapID = 0,
    -- descName = function()
    --     local value = ""
    --     if self.titleName or self.typeName then
    --         if self.titleName then
    --             value = self.titleName
    --         end
    --         if self.titleName and self.titleName then
    --             value = value.."\n"
    --         end
    --         value = value..self.typeName
    --     end
    --     return value
    -- end,
    -- _savedName = "" --保存一下titleName
}

-- =================================================================
-- 共用方法组
-- hex转rgba颜色
function mppe.ColorHexToRGBA(hexColor)
    -- 移除可能的#前缀
    hexColor = string.gsub(hexColor, "^#", "")

    -- 如果是8位ARGB格式
    if #hexColor == 8 then
        local a = tonumber(string.sub(hexColor, 1, 2), 16) / 255
        local r = tonumber(string.sub(hexColor, 3, 4), 16) / 255
        local g = tonumber(string.sub(hexColor, 5, 6), 16) / 255
        local b = tonumber(string.sub(hexColor, 7, 8), 16) / 255
        return r, g, b, a
    -- 如果是6位RGB格式（默认不透明）
    elseif #hexColor == 6 then
        local r = tonumber(string.sub(hexColor, 1, 2), 16) / 255
        local g = tonumber(string.sub(hexColor, 3, 4), 16) / 255
        local b = tonumber(string.sub(hexColor, 5, 6), 16) / 255
        return r, g, b, 1  -- 默认Alpha=1（不透明）
    else
        return 1, 1, 1, 1  -- 默认白色不透明
    end
end

-- 获取分数颜色(以魔兽标准品质颜色，在默认颜色逻辑基础上增加了artifact和poor颜色区间)
function mppe.GetColorByScore(score, colorStyle, bHexColor)
    score = score or 0
    local r, g, b = 1, 1 ,1
    if colorStyle == "raiderio" then
        -- REF Raider.IO 参考其颜色区间设置建立的算法函数
        local _rRange = mppe.RaiderIOScoreRange
        -- if type(NowRaiderIOTopScore) ~= "number" then NowRaiderIOTopScore = 4075 end
        -- 确保分数在有效范围内
        score = math.max(0, math.min(score, _rRange[1]))
        if score >= _rRange[2] then
            local t = (_rRange[1] - score) / (_rRange[1] - _rRange[2])
            r, g, b = 1-0.36*t, 0.5-0.29*t, 0.93*t
        elseif score >= _rRange[3] then
            local t = (_rRange[2] - score) / (_rRange[2] - _rRange[3])
            r, g, b = 0.64-0.39*t, 0.21+0.21*t, 0.93-0.05*t
        elseif score >= _rRange[4] then
            local t = (_rRange[3] - score) / (_rRange[3] - _rRange[4])
            r, g, b = 0.25-0.13*t, 0.42+0.58*t, 0.88-0.88*t
        elseif score >= _rRange[5] then
            local t = (_rRange[4] - score) / (_rRange[4] - _rRange[5])
            r, g, b = 0.12+0.26*t, 1.00, 0.28*t
        elseif score >= _rRange[6] then
            local t = (_rRange[5] - score) / (_rRange[5] - _rRange[6])
            r, g, b = 0.38+0.62*t, 1.00, 0.28+0.72*t
        else r, g, b = 1.00, 1.00, 1.00
        end
    else
        r,g,b = 0.62, 0.62, 0.62 -- poor
        if score >= 3000 then  r,g,b = 0.90, 0.80, 0.50 -- artifact
        elseif score >= 2200 then r,g,b = 1.00, 0.50, 0.00 -- legendary
        elseif score >= 1800 then r,g,b = 0.64, 0.21, 0.93 -- epic
        elseif score >= 1500 then r,g,b = 0.00, 0.44, 0.87 -- rare
        elseif score >= 1000 then r,g,b = 0.12, 1.00, 0.00 -- uncommon
        elseif score >= 500 then r,g,b = 1.00, 1.00, 1.00 --common
        end
    end
    if bHexColor then
        return string.format("FF%02X%02X%02X", r*255, g*255, b*255)
    else
        return r, g, b, 1
    end
end

function mppe.MathRound(value, decimalPlaces)
    if type(value) ~= "number" then value = 0 end
    if type(decimalPlaces) ~= "number" then decimalPlaces = 0 end
    if decimalPlaces > 10 then decimalPlaces = 10 end
    value = math.floor(value * math.pow(10, decimalPlaces) +0.5 ) / math.pow(10, decimalPlaces)
    return value
end

-- 通用的漂亮打印函数（递归处理嵌套表）
function mppe.DebugPrint(t, indent, visited)
    indent = indent or 0
    visited = visited or {}
    local spaces = string.rep("  ", indent) -- 缩进

    -- 防止循环引用导致无限递归
    if type(t) == "table" and visited[t] then
        print(spaces .. "（已打印过此表，防止循环引用）")
        return
    end
    if type(t) == "table" then
        visited[t] = true
    end

    for key, value in pairs(t) do
        local keyStr = tostring(key)
        if type(value) == "table" then
            print(string.format("%s[%s] => {", spaces, keyStr))
            mppe.DebugPrint(value, indent + 1, visited)
            print(spaces .. "}")
        else
            -- 对字符串值进行转义，使其更易读
            local valueStr = tostring(value)
            if type(value) == "string" then
                valueStr = '"' .. valueStr .. '"'
            end
            print(string.format("%s[%s] => %s", spaces, keyStr, valueStr))
        end
    end
end
