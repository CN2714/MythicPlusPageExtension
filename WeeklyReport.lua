local ADDON_NAME, mppe = ...
local translate = mppe.Translate

-- 周报主窗体引用（供外部函数访问）
mppe.WeeklyReportFrame = nil

-- ==================================================================
-- 常量与工具函数
-- ==================================================================

-- 宝库奖励等级映射（下标 = 大秘层数 → 对应奖励文本）
local VaultRewards = {
    "",
    translate['Champion'].."4",
    translate['Hero'].."1",
    translate['Hero'].."1",
    translate['Hero'].."2",
    translate['Hero'].."2",
    translate['Hero'].."3",
    translate['Hero'].."4",
    translate['Hero'].."4",
    translate['Myth'].."1",
}

-- 根据是否超时为大秘层数着色（超时红色 / 正常绿色）
local function colorByOvertime(level, overtime)
    return string.format("%s%d|r", overtime and "|cffff0000" or "|cff00ff00", level)
end

-- 获取副本短名称（未知副本返回 "Unknown"）
local function getDungeonShortName(dunID)
    local dungeonInfo = mppe.Dungeons[dunID]
    return dungeonInfo and translate[dungeonInfo.Name] or "Unknown"
end

-- 文本模式可用宽度：内容宽 - 左侧 4px 内边距（防止最右字符被裁切）
local function getTextAreaWidth(scrollChild)
    if not scrollChild then return 0 end
    return math.max(scrollChild:GetWidth() - 4, 60)
end

-- 依据文本内容刷新滚动区尺寸（宽度跟随窗体，高度跟随文本，并复位到顶部）
local function refreshScrollSize(frame)
    local scrollChild = frame.scrollChild
    local mainText = frame.mainText
    if not scrollChild or not mainText then return end
    scrollChild:SetWidth(frame.scrollFrame:GetWidth())
    mainText:SetWidth(getTextAreaWidth(scrollChild))
    scrollChild:SetHeight(mainText:GetStringHeight())
    frame.scrollFrame:UpdateScrollChildRect()
    frame.scrollFrame:SetVerticalScroll(0)
end

-- ==================================================================
-- 文本模式渲染
-- ==================================================================

-- 生成文本模式的周报内容（保持原有输出样式不变，滚动区自适应高度）
function mppe.WeeklyReport_TextMode(isTestMode)
    local frame = mppe.WeeklyReportFrame
    if not frame then return end
    local mainText = frame.mainText
    if not mainText then return end

    mainText:SetFont(mainText:GetFont(), MythicPlusPageExtensionDB.WeeklyReport_FontSize)
    mainText:SetJustifyH("LEFT")
    mainText:SetJustifyV("TOP")

    local dunRuns = frame:GetWeeklyData(isTestMode)

    -- 无记录时显示占位文案并收起滚动区
    if not dunRuns.TOTAL or #dunRuns.TOTAL == 0 then
        mainText:SetText("|c00FFBA1A"..translate['There are no records for this week yet!'] .. "|r")
        refreshScrollSize(frame)
        return
    end

    local textParts = {}

    -- TOP8 部分（按设置决定是否显示）
    if MythicPlusPageExtensionDB.WeeklyReport_ShowWeeklyTOP8 then
        table.insert(textParts, "|c00FFBA1A" .. translate['Top 8 Weekly Mythic+ Runs:'] .. "|r")
        table.insert(textParts, "\n")
        for _index, _run in ipairs(dunRuns.TOP8) do
            local line = "\n  " .. colorByOvertime(_run.level, _run.overtime) .. "  " .. getDungeonShortName(_run.dunID)
            -- 第 1 / 4 / 8 条附带宝库奖励等级
            if _index == 1 or _index == 4 or _index == 8 then
                local vaultLevel = math.min(_run.level, 10)
                line = line .. string.format(" |cffa335ee %s%s|r", translate['iLvl:'], VaultRewards[vaultLevel])
            end
            table.insert(textParts, line)
        end
        table.insert(textParts, "\n\n")
    end

    -- 总计部分（按副本分组统计）
    local totalCount = 0
    local dungeonDetails = {}
    for _, _detail in ipairs(dunRuns.TOTAL) do
        local runsText = {}
        for _, _run in ipairs(_detail.runs) do
            table.insert(runsText, colorByOvertime(_run.level, _run.overtime))
            totalCount = totalCount + 1
        end
        table.insert(dungeonDetails, string.format("\n  %s(|T:1:1|t|c00ffff63%d|T:1:1|t|r): %s",
            getDungeonShortName(_detail.dunID), #_detail.runs, table.concat(runsText, ", ")))
    end

    table.insert(textParts, "|c00FFBA1A" .. translate['Weekly Mythic+ Total Runs:'] .. "|r|c00ffff63 " .. totalCount .. " |r")
    table.insert(textParts, "\n")
    for _, _detail in ipairs(dungeonDetails) do
        table.insert(textParts, _detail)
    end

    mainText:SetText(table.concat(textParts, ""))

    -- 内容超出可视区时自动出现滚动条
    refreshScrollSize(frame)
end

-- ==================================================================
-- 风琴模式（暂未优化显示效果，仅保证兼容滚动容器）
-- ==================================================================

local function Accordion_Show(isTestMode)
    local frame = mppe.WeeklyReportFrame
    if not frame then return end
    local scrollChild = frame.scrollChild
    if not scrollChild then return end
    local mainText = frame.mainText
    if mainText then mainText:SetText("") end

    local dunRuns = frame:GetWeeklyData(isTestMode)

    -- 确保内容宽度与当前滚动区一致（避免窗体尺寸变化后残留旧宽度，导致文本换行/高度计算不准）
    scrollChild:SetWidth(frame.scrollFrame:GetWidth())

    -- 预声明区块框架，供滚动高度刷新闭包引用
    local Frame_Top8, Frame_Total

    -- 根据风琴内容总高度刷新滚动区
    local function updateScrollHeight()
        local top = Frame_Top8 and Frame_Top8:GetTop()
        local bottom = Frame_Total and Frame_Total:GetBottom()
        if top and bottom then
            scrollChild:SetHeight(math.max(0, top - bottom))
            frame.scrollFrame:UpdateScrollChildRect()
        end
    end

    -- ========== TOP8 区块 ==========

    -- 复用或创建 TOP8 框架（渲染进滚动容器）
    Frame_Top8 = _G["mppe_WeeklyReportAccordion_Top8"] or
                 CreateFrame("Frame", "mppe_WeeklyReportAccordion_Top8", scrollChild)
    Frame_Top8:SetWidth(scrollChild:GetWidth())
    Frame_Top8:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 0, 0)
    Frame_Top8:Show()

    -- TOP8 标题（可点击展开/收起）
    local Header_Top8 = _G["mppe_WeeklyReportAccordion_Top8_Header"] or
                        CreateFrame("Button", "mppe_WeeklyReportAccordion_Top8_Header", Frame_Top8)
    if not Header_Top8.initialized then
        Header_Top8:SetHeight(25)
        Header_Top8:SetPoint("TOP")

        Header_Top8.bg = Header_Top8:CreateTexture(nil, "BACKGROUND")
        Header_Top8.bg:SetAllPoints()
        Header_Top8.bg:SetColorTexture(0.25, 0.25, 0.25, 0.5)

        Header_Top8.title = Header_Top8:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        Header_Top8.title:SetPoint("LEFT", 10, 0)
        Header_Top8.title:SetText(translate['Top 8 Weekly Mythic+ Runs:'])

        Header_Top8.expandIcon = Header_Top8:CreateTexture(nil, "OVERLAY")
        Header_Top8.expandIcon:SetSize(12, 12)
        Header_Top8.expandIcon:SetPoint("RIGHT", -10, 0)

        Header_Top8.initialized = true
    end

    Header_Top8:SetWidth(Frame_Top8:GetWidth())

    -- TOP8 内容区域
    local Content_Top8 = _G["mppe_WeeklyReportAccordion_Top8_Content"] or
                         CreateFrame("Frame", "mppe_WeeklyReportAccordion_Top8_Content", Frame_Top8)
    Content_Top8:SetPoint("TOP", Header_Top8, "BOTTOM")
    Content_Top8:SetWidth(Frame_Top8:GetWidth())

    if not Content_Top8.initialized then
        Content_Top8.bg = Content_Top8:CreateTexture(nil, "BACKGROUND")
        Content_Top8.bg:SetAllPoints()
        Content_Top8.bg:SetColorTexture(0.25, 0.25, 0.25, 0.25)
        Content_Top8.initialized = true
    end

    -- 清空并移除旧内容
    Content_Top8:Hide()
    for _index = Content_Top8:GetNumChildren(), 1, -1 do
        local child = select(_index, Content_Top8:GetChildren())
        child:Hide()
        child:SetParent(nil)
    end
    local regions = {Content_Top8:GetRegions()}
    for _, _region in ipairs(regions) do
        if _region ~= Content_Top8.bg then
            _region:Hide()
            _region:SetParent(nil)
        end
    end

    -- 创建 TOP8 内容
    if dunRuns and dunRuns.TOP8 and #dunRuns.TOP8 > 0 then
        local contentHeight = 0
        local itemHeight = 20
        local padding = 0

        for _index, _run in ipairs(dunRuns.TOP8) do
            local dunShortname = getDungeonShortName(_run.dunID)
            local _lv = Content_Top8:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            _lv:SetPoint("TOPLEFT", 5, -((_index-1) * (itemHeight + padding))-2)
            _lv:SetText(colorByOvertime(_run.level, _run.overtime))
            _lv:SetWidth(20)

            local _v = Content_Top8:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            if _index == 1 or _index == 4 or _index == 8 then
                local vaultLevel = math.min(_run.level, 10)
                _v:SetPoint("TOPRIGHT", -5, -((_index-1) * (itemHeight + padding))-2)
                _v:SetText(string.format("|cffa335ee %s%s|r", translate['iLvl:'], VaultRewards[vaultLevel]))
                _v:SetWidth(_v:GetStringWidth())
            end

            local _dun = Content_Top8:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            _dun:SetPoint("LEFT", _lv, "RIGHT", 3, 0)
            _dun:SetWidth(Content_Top8:GetWidth() - _lv:GetWidth() - (_v:GetWidth() or 0) - 10)
            _dun:SetText(dunShortname)
            _dun:SetJustifyH("LEFT")

            contentHeight = contentHeight + itemHeight + padding
        end

        Content_Top8:SetHeight(contentHeight + padding)

        -- 默认收起
        Header_Top8.expandIcon:SetAtlas("common-icon-plus")
        Frame_Top8:SetHeight(Header_Top8:GetHeight())

        -- 点击展开/收起 TOP8
        Header_Top8:SetScript("OnClick", function()
            if Content_Top8:IsShown() then
                Content_Top8:Hide()
                Frame_Top8:SetHeight(Header_Top8:GetHeight())
                Header_Top8.expandIcon:SetAtlas("common-icon-plus")
            else
                Content_Top8:Show()
                Frame_Top8:SetHeight(Header_Top8:GetHeight() + Content_Top8:GetHeight())
                Header_Top8.expandIcon:SetAtlas("common-icon-minus")
            end
            updateScrollHeight()
        end)

        Header_Top8:Enable()
    else
        -- 没有数据时禁用点击
        Header_Top8:Disable()
        Frame_Top8:SetHeight(Header_Top8:GetHeight())
    end

    -- ========== 总计区块 ==========

    -- 复用或创建总计框架（渲染进滚动容器）
    Frame_Total = _G["mppe_WeeklyReportAccordion_Total"] or
                  CreateFrame("Frame", "mppe_WeeklyReportAccordion_Total", scrollChild)
    Frame_Total:SetWidth(scrollChild:GetWidth())
    Frame_Total:SetPoint("TOP", Frame_Top8, "BOTTOM", 0, 0)
    Frame_Total:Show()

    -- 总计标题（可点击展开/收起）
    local Header_Total = _G["mppe_WeeklyReportAccordion_Total_Header"] or
                        CreateFrame("Button", "mppe_WeeklyReportAccordion_Total_Header", Frame_Total)
    if not Header_Total.initialized then
        Header_Total:SetHeight(25)
        Header_Total:SetPoint("TOP")

        Header_Total.bg = Header_Total:CreateTexture(nil, "BACKGROUND")
        Header_Total.bg:SetAllPoints()
        Header_Total.bg:SetColorTexture(0.25, 0.25, 0.25, 0.5)

        Header_Total.title = Header_Total:CreateFontString(nil, "OVERLAY", "GameFontNormal")
        Header_Total.title:SetPoint("LEFT", 10, 0)
        Header_Total.title:SetText(translate['Weekly Mythic+ Total Runs:'])

        Header_Total.expandIcon = Header_Total:CreateTexture(nil, "OVERLAY")
        Header_Total.expandIcon:SetSize(12, 12)
        Header_Total.expandIcon:SetPoint("RIGHT", -10, 0)

        Header_Total.initialized = true
    end

    Header_Total:SetWidth(Frame_Total:GetWidth())

    -- 总计内容区域
    local Content_Total = _G["mppe_WeeklyReportAccordion_Total_Content"] or
                         CreateFrame("Frame", "mppe_WeeklyReportAccordion_Total_Content", Frame_Total)
    Content_Total:SetPoint("TOP", Header_Total, "BOTTOM")
    Content_Total:SetWidth(Frame_Total:GetWidth())

    if not Content_Total.initialized then
        Content_Total.bg = Content_Total:CreateTexture(nil, "BACKGROUND")
        Content_Total.bg:SetAllPoints()
        Content_Total.bg:SetColorTexture(0.25, 0.25, 0.25, 0.25)
        Content_Total.initialized = true
    end

    -- 清空并移除旧内容
    Content_Total:Hide()
    for _index = Content_Total:GetNumChildren(), 1, -1 do
        local child = select(_index, Content_Total:GetChildren())
        child:Hide()
        child:SetParent(nil)
    end
    local regions = {Content_Total:GetRegions()}
    for _, _region in ipairs(regions) do
        if _region ~= Content_Total.bg then
            _region:Hide()
            _region:SetParent(nil)
        end
    end

    -- 创建总计内容
    if dunRuns and dunRuns.TOTAL and #dunRuns.TOTAL > 0 then
        local contentHeight = 0
        local itemHeight = 20
        local padding = 0
        local lastItem = Content_Total

        for _index, _detail in ipairs(dunRuns.TOTAL) do
            local dunShortname = getDungeonShortName(_detail.dunID)

            local totalItem = CreateFrame("Frame", "mppe_WeeklyReportAccordion_Total_Content_i".._index, Content_Total)
            totalItem:SetWidth(Content_Total:GetWidth())
            if _index == 1 then
                totalItem:SetPoint("TOP", lastItem, "TOP", 0, 0)
            else
                totalItem:SetPoint("TOP", lastItem, "BOTTOM", 0, 0)
            end
            totalItem:Show()

            local runsText = {}
            local totalCount = 0
            for _, _run in ipairs(_detail.runs) do
                table.insert(runsText, colorByOvertime(_run.level, _run.overtime))
                totalCount = totalCount + 1
            end

            local headerItem = CreateFrame("Button", "mppe_WeeklyReportAccordion_Total_Header_Item".._index, totalItem)
            headerItem:SetHeight(25)
            headerItem:SetPoint("TOP")

            headerItem.bg = headerItem:CreateTexture(nil, "BACKGROUND")
            headerItem.bg:SetAllPoints()
            headerItem.bg:SetColorTexture(0.25, 0.25, 0.25, 0.5)

            headerItem.title = headerItem:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            headerItem.title:SetPoint("LEFT", 10, 0)
            headerItem.title:SetText(string.format("|c00ffffff%s|r (|T:1:1|t|c00ffff63%d|r|T:1:1|t)", dunShortname, totalCount))

            headerItem.expandIcon = headerItem:CreateTexture(nil, "OVERLAY")
            headerItem.expandIcon:SetSize(12, 12)
            headerItem.expandIcon:SetPoint("RIGHT", -10, 0)
            headerItem:SetWidth(totalItem:GetWidth())

            -- 每行地牢的展开详情
            local contentItem = CreateFrame("Frame", "mppe_WeeklyReportAccordion_Total_ContentDetail_".._index, totalItem)
            contentItem:SetPoint("TOPLEFT", headerItem, "BOTTOMLEFT", 0, 0)
            contentItem:SetWidth(totalItem:GetWidth())

            contentItem.bg = contentItem:CreateTexture(nil, "BACKGROUND")
            contentItem.bg:SetAllPoints()
            contentItem.bg:SetColorTexture(0.25, 0.25, 0.25, 0.25)
            contentItem:Hide()

            local detailItem = contentItem:CreateFontString(nil, "OVERLAY", "GameFontNormal")
            detailItem:SetPoint("TOPLEFT", contentItem, "TOPLEFT", 15, -2)
            -- 显式设置文本宽度（左右各留 15 内边距），并强制按宽度自动换行
            detailItem:SetWidth(math.max(contentItem:GetWidth() - 30, 60))
            detailItem:SetWordWrap(true)
            detailItem:SetText(table.concat(runsText, ", "))
            detailItem:SetJustifyH("LEFT")

            -- 用实际行数 × 单行行高计算总高度（GetNumLines 直接返回换行后的行数，最可靠）
            local _lineCount = math.max(detailItem:GetNumLines(), 1)
            local _detailHeight = _lineCount * detailItem:GetLineHeight()
            detailItem:SetHeight(_detailHeight)
            contentItem:SetHeight(_detailHeight + 4 + 6)

            -- 默认收起
            headerItem.expandIcon:SetAtlas("common-icon-plus")
            totalItem:SetHeight(headerItem:GetHeight())

            headerItem.contentItem = contentItem
            totalItem.headerItem = headerItem

            -- 点击展开/收起该地牢详情
            headerItem:SetScript("OnClick", function()
                if contentItem:IsShown() then
                    contentItem:Hide()
                    totalItem:SetHeight(headerItem:GetHeight())
                    headerItem.expandIcon:SetAtlas("common-icon-plus")
                else
                    contentItem:Show()
                    totalItem:SetHeight(headerItem:GetHeight() + contentItem:GetHeight())
                    headerItem.expandIcon:SetAtlas("common-icon-minus")
                end
                updateScrollHeight()
            end)

            lastItem = totalItem
            contentHeight = contentHeight + itemHeight + padding
        end

        Content_Total:SetHeight(contentHeight + padding)

        -- 默认收起
        Header_Total.expandIcon:SetAtlas("common-icon-plus")
        Frame_Total:SetHeight(Header_Total:GetHeight())

        -- 点击展开/收起整个总计区块（收起前先关闭所有已展开的地牢子面板）
        Header_Total:SetScript("OnClick", function()
            if Content_Total:IsShown() then
                for _, _child in ipairs({Content_Total:GetChildren()}) do
                    if _child.headerItem and _child.headerItem.contentItem then
                        local header = _child.headerItem
                        if header.contentItem:IsShown() then
                            local onClick = header:GetScript("OnClick")
                            if onClick then
                                onClick(header)
                            end
                        end
                    end
                end
                Content_Total:Hide()
                Frame_Total:SetHeight(Header_Total:GetHeight())
                Header_Total.expandIcon:SetAtlas("common-icon-plus")
            else
                Content_Total:Show()
                Frame_Total:SetHeight(Header_Total:GetHeight() + Content_Total:GetHeight())
                Header_Total.expandIcon:SetAtlas("common-icon-minus")
            end
            updateScrollHeight()
        end)

        Header_Total:Enable()
    else
        -- 没有数据时禁用点击
        Header_Total:Disable()
        Frame_Total:SetHeight(Header_Total:GetHeight())
    end

    -- 依据内容总高度刷新滚动区
    updateScrollHeight()
end

-- ==================================================================
-- 懒初始化：仅在启用时创建周报主窗体
-- ==================================================================

-- 创建设置按钮（通用创建 + 右上角定位；皮肤差异由各 UI 分支另行处理）
local function createSettingBtn(frame)
    frame.SettingBtn = CreateFrame("Button", "MPPE_WRF_SettingBtn", frame, "UIPanelIconDropdownButtonTemplate")
    frame.SettingBtn:SetPoint("TOPRIGHT", -27, -4)
    return frame.SettingBtn
end

-- 创建周报主窗体并按 UI 插件应用皮肤（含设置按钮；UI 检测由 CreateWeeklyReportFrame 传入）
local function applyUiSkin(UiE, UiN, UiEll)
    local frame

    -- 根据 UI 插件应用窗体样式（各分支仅处理皮肤差异，设置按钮统一用 createSettingBtn）
    if UiE then
        frame = CreateFrame("Frame", "MPPE_WeeklyReportFrame", UIParent)
        frame:CreateBackdrop("Transparent")
        local closeButton = CreateFrame("Button", "MPPE_WRF_UiECloseBtn", frame)
        closeButton:SetSize(20, 20)
        closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
        closeButton:SetScript("OnClick", function() frame:Hide() end)
        local skins = UiE:GetModule('Skins')
        skins:HandleCloseButton(closeButton)
        -- 设置按钮（ElvUI 已自动皮肤化，无需额外纹理）
        createSettingBtn(frame)
    elseif UiN then
        frame = CreateFrame("Frame", "MPPE_WeeklyReportFrame", UIParent, "SettingsFrameTemplate")
        local skins = UiN:GetModule("Skins")
        UiN.StripTextures(frame)
        UiN.SetBD(frame)

        UiN.ReskinClose(frame.ClosePanelButton)
        -- 设置按钮（NDui 就地皮肤化）
        createSettingBtn(frame)
        UiN.Reskin(frame.SettingBtn)
        frame.SettingBtn:ClearAllPoints()
        frame.SettingBtn:SetPoint("TOPRIGHT", -27, -6)
    elseif UiEll then
        frame = CreateFrame("Frame", "MPPE_WeeklyReportFrame", UIParent, "SettingsFrameTemplate")
        -- 提前创建设置按钮（供 RegisterSkin 回调直接处理）
        createSettingBtn(frame)
        -- 注册 EllesmereUI 皮肤：窗口与设置按钮均已创建，回调统一为全部控件套壳
        if EllesmereUI.RegisterSkin then
            EllesmereUI.RegisterSkin("MythicPlusPageExtension", function(skin)
                if not frame then return end
                skin.Shell(frame)
                if frame.ClosePanelButton then
                    skin.CloseButton(frame.ClosePanelButton)
                end
                if frame.SettingBtn then
                    skin.Button(frame.SettingBtn, {"Icon", "ButtonIcon", "Arrow"})
                end
            end)
        end
    else
        frame = CreateFrame("Frame", "MPPE_WeeklyReportFrame", UIParent, "SettingsFrameTemplate")
        -- 设置按钮（默认 Blizzard 样式）
        createSettingBtn(frame)
        local settingsBtn_texture = frame.SettingBtn:CreateTexture(nil, "OVERLAY")
        settingsBtn_texture:SetSize(frame.SettingBtn:GetWidth()+16,frame.SettingBtn:GetWidth()+16)
        settingsBtn_texture:SetPoint("CENTER", 0, -3)
        settingsBtn_texture:SetAtlas("common-dropdown-a-button-settings-shadowless")
    end

    return frame
end

-- 创建周报主窗体（保持主容器结构不变，新增滚动区；仅在启用周报时调用）
local function CreateWeeklyReportFrame()
    if mppe.WeeklyReportFrame then return end

    -- 检测已安装的 UI 插件，用于应用对应皮肤与跟随偏移
    local UiE = ElvUI and ElvUI[1]
    local UiN = NDui and NDui[1]
    local UiEll = EllesmereUI

    -- 创建主窗体并按 UI 插件应用皮肤（含设置按钮）
    local weeklyReportFrame = applyUiSkin(UiE, UiN, UiEll)

    -- 公共属性（保持原有设置）
    weeklyReportFrame:SetSize(300, 300)
    weeklyReportFrame:SetPoint("CENTER")
    -- 窗体不可手动拖动：位置完全由跟随逻辑接管（UpdateFollowFramePosition / ReanchorToTarget），故不注册拖动脚本
    weeklyReportFrame:SetMovable(false)
    weeklyReportFrame:SetScript("OnShow", function()
        if not MythicPlusPageExtensionDB.WeeklyReport_Enable then
            weeklyReportFrame:Hide()
        else
            -- 每次显示时应用最新滚动条显隐设置（设置切换后无需重载 UI 即可生效）
            weeklyReportFrame:ApplyScrollBarMode(MythicPlusPageExtensionDB.WeeklyReport_ShowScrollBar)
            weeklyReportFrame:UpdateFollowFramePosition()
        end
        if MythicPlusPageExtensionDB.WeeklyReport_HideRaiderIOFrame and RaiderIO_ProfileTooltip then
            RaiderIO_ProfileTooltip:Hide()
        end
    end)
    weeklyReportFrame:Hide()

    -- 允许临时调整窗体大小（仅用于打开时查看；重开时由 UpdateFollowFramePosition 恢复默认尺寸）
    weeklyReportFrame:SetResizable(true)
    weeklyReportFrame:SetResizeBounds(260, 150, 900, 1000)

    -- 标题
    weeklyReportFrame.title = weeklyReportFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    weeklyReportFrame.title:SetPoint("TOP", weeklyReportFrame, 0, -5)
    weeklyReportFrame.title:SetText("MPPE")

    -- ==================================================================
    -- 可滚动内容区（ScrollFrameTemplate 自动创建新版 MinimalScrollBar 滚动条）
    -- ==================================================================
    local scrollFrame = CreateFrame("ScrollFrame", "MPPE_WRF_ScrollFrame", weeklyReportFrame, "ScrollFrameTemplate")
    scrollFrame:SetPoint("TOPLEFT", weeklyReportFrame, "TOPLEFT", 10, -28)
    scrollFrame:EnableMouseWheel(true)
    -- 滚动条被隐藏时，用 OnShow 钩子防止内部逻辑重新显示（由 ApplyScrollBarMode 的 hideScrollBar 开关控制）
    scrollFrame.ScrollBar:HookScript("OnShow", function(self)
        if scrollFrame.hideScrollBar then
            self:Hide()
        end
    end)

    -- 滚动内容容器（文本模式 / 风琴模式的内容都渲染于此）
    local scrollChild = CreateFrame("Frame", "MPPE_WRF_ScrollChild", scrollFrame)
    scrollFrame:SetScrollChild(scrollChild)
    scrollChild:SetWidth(scrollFrame:GetWidth())

    -- 文本显示区域（文本模式使用，宽度显式设置、高度由内容决定）
    local mainText = scrollChild:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    mainText:SetPoint("TOPLEFT", scrollChild, "TOPLEFT", 4, -2)
    mainText:SetWidth(getTextAreaWidth(scrollChild))
    mainText:SetJustifyH("LEFT")
    mainText:SetJustifyV("TOP")
    mainText:SetText("|c00FFBA1A"..translate['There are no records for this week yet!'] .. "|r")

    -- 存储引用供各函数使用
    weeklyReportFrame.scrollFrame = scrollFrame
    weeklyReportFrame.scrollChild = scrollChild
    weeklyReportFrame.mainText = mainText

    -- 运行时切换滚动条显隐（show=true 显示；false 隐藏但保留鼠标滚轮），并同步滚动内容
    function weeklyReportFrame:ApplyScrollBarMode(show)
        local scrollBar = scrollFrame.ScrollBar
        scrollFrame.hideScrollBar = not show
        if show then
            -- 显示：右侧内缩 21 预留滚动条空间，滚动条始终显示
            scrollFrame:SetPoint("BOTTOMRIGHT", weeklyReportFrame, "BOTTOMRIGHT", -21, 2)
            scrollBar:SetHideIfUnscrollable(false)
            scrollBar:Show()
        else
            -- 隐藏：右侧内缩 10，内容更贴近窗体右边框
            scrollFrame:SetPoint("BOTTOMRIGHT", weeklyReportFrame, "BOTTOMRIGHT", -10, 2)
            scrollBar:SetHideIfUnscrollable(true)
            scrollBar:Hide()
        end
        -- 宽度变化后同步滚动内容并刷新
        scrollChild:SetWidth(scrollFrame:GetWidth())
        if MythicPlusPageExtensionDB.WeeklyReport_FrameStyle ~= "accordion" then
            mainText:SetWidth(getTextAreaWidth(scrollChild))
            scrollChild:SetHeight(mainText:GetStringHeight())
        end
        scrollFrame:UpdateScrollChildRect()
    end

    -- 窗体大小变化时同步滚动内容（文本模式重新换行并计算高度；风琴模式高度由自身管理）
    weeklyReportFrame:SetScript("OnSizeChanged", function()
        if not scrollFrame or not scrollChild then return end
        scrollChild:SetWidth(scrollFrame:GetWidth())
        if MythicPlusPageExtensionDB.WeeklyReport_FrameStyle ~= "accordion" then
            mainText:SetWidth(getTextAreaWidth(scrollChild))
            scrollChild:SetHeight(mainText:GetStringHeight())
        end
        scrollFrame:UpdateScrollChildRect()
    end)

    -- 存储要跟随的窗口
    local targetFrame = PVEFrame

    -- 更新跟随框体位置的函数（窗体尺寸变化时同步滚动区宽度）
    function weeklyReportFrame:UpdateFollowFramePosition()
        if not targetFrame or not targetFrame:IsShown() then
            weeklyReportFrame:Hide()
            return
        end
        if UiE or UiN or UiEll then
            weeklyReportFrame:SetSize(MythicPlusPageExtensionDB.WeeklyReport_FrameWidth, targetFrame:GetHeight()+MythicPlusPageExtensionDB.WeeklyReport_FrameHeightCorrection)
            weeklyReportFrame:ClearAllPoints()
            weeklyReportFrame:SetPoint("TOPLEFT", targetFrame, "TOPRIGHT", 0, MythicPlusPageExtensionDB.WeeklyReport_FrameHeightCorrection/2)
        else
            weeklyReportFrame:SetSize(MythicPlusPageExtensionDB.WeeklyReport_FrameWidth, targetFrame:GetHeight())
            weeklyReportFrame:ClearAllPoints()
            weeklyReportFrame:SetPoint("TOPLEFT", targetFrame, "TOPRIGHT", -7, 0)
        end
        -- 确保跟随窗口不会超出屏幕
        if weeklyReportFrame:GetLeft() < 0 then
            weeklyReportFrame:SetPoint("LEFT", UIParent, "LEFT", 5, 0)
        end

        -- 窗体宽度变化后同步滚动内容宽度
        scrollChild:SetWidth(scrollFrame:GetWidth())

        weeklyReportFrame:Show()
    end

    -- 重新锚定跟随位置（仅恢复对 PVEFrame 的锚点，保持手动调整后的尺寸不变）
    function weeklyReportFrame:ReanchorToTarget()
        if not targetFrame then return end
        weeklyReportFrame:ClearAllPoints()
        if UiE or UiN or UiEll then
            weeklyReportFrame:SetPoint("TOPLEFT", targetFrame, "TOPRIGHT", 0, MythicPlusPageExtensionDB.WeeklyReport_FrameHeightCorrection/2)
        else
            weeklyReportFrame:SetPoint("TOPLEFT", targetFrame, "TOPRIGHT", -7, 0)
        end
        -- 确保跟随窗口不会超出屏幕
        if weeklyReportFrame:GetLeft() < 0 then
            weeklyReportFrame:SetPoint("LEFT", UIParent, "LEFT", 5, 0)
        end
    end

    -- 处理目标窗口移动
    if targetFrame.SetScript then
        local originalOnDragStop = targetFrame:GetScript("OnDragStop")
        if originalOnDragStop then
            targetFrame:SetScript("OnDragStop", function(self, ...)
                originalOnDragStop(self, ...)
                weeklyReportFrame:UpdateFollowFramePosition()
            end)
        end

        local originalOnSizeChanged = targetFrame:GetScript("OnSizeChanged")
        if originalOnSizeChanged then
            targetFrame:SetScript("OnSizeChanged", function(self, ...)
                if originalOnSizeChanged then
                    originalOnSizeChanged(self, ...)
                end
                weeklyReportFrame:UpdateFollowFramePosition()
            end)
        end
    end

    -- 初始检查（如果目标窗口已经打开）
    if targetFrame:IsShown() then
        weeklyReportFrame:UpdateFollowFramePosition()
    end

    -- ==================================================================
    -- 设置按钮脚本
    local originalOnMouseDown = weeklyReportFrame.SettingBtn:GetScript("OnMouseDown")
    local originalOnMouseUp = weeklyReportFrame.SettingBtn:GetScript("OnMouseUp")
    weeklyReportFrame.SettingBtn:SetScript("OnMouseDown", function(self, button, ...)
        self.downButton = button
        if originalOnMouseDown then return originalOnMouseDown(self, button, ...) end
    end)

    weeklyReportFrame.SettingBtn:SetScript("OnMouseUp", function(self, button, ...)
        if self.downButton == button then
            if button == "LeftButton" and IsShiftKeyDown() then
                mppe.RefreshWeeklyReport(true)
            elseif button == "LeftButton" then
                mppe.SettingsShow()
            elseif button == "RightButton" and IsShiftKeyDown() then
                mppe.RefreshWeeklyReport(true)
            elseif button == "RightButton" then
                mppe.RequestPartyInfo()
                mppe.RefreshScoreNTeleport()
                mppe.RefreshWeeklyReport()
                mppe.RefreshPartyInfo()
                mppe.RefreshPartyInspector()
            end
        end
        self.downButton = nil
        if originalOnMouseUp then return originalOnMouseUp(self, button, ...) end
    end)

    weeklyReportFrame.SettingBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText("MPPE By CN2714"..(mppe.Translator and " ("..mppe.Translator..")" or ""))
        GameTooltip:AddLine(mppe.Translate['Left-Click:Settings(/mppe)'], 1, 1, 1)
        GameTooltip:AddLine(mppe.Translate['Right-Click:Refresh(Score&Teleport/PartyInfo/WeeklyReport)'], 1, 1, 1)
        GameTooltip:Show()
    end)
    weeklyReportFrame.SettingBtn:SetScript("OnLeave", function(self)
        self.downButton = nil
        GameTooltip:Hide()
    end)

    -- ==================================================================
    -- 获取周数据方法（测试模式生成随机数据，真实模式读取大秘记录）
    function weeklyReportFrame:GetWeeklyData(isTestMode)
        local dunRuns = {
            TOP8 = {},
            TOTAL = {}
        }

        local runHistory

        -- 测试模式：生成随机数据
        if isTestMode then
            local testData = {
                dungeons = {499, 505, 503, 525, 542, 391, 392, 378},
                levels = {2, 3, 4, 5, 6, 7, 8, 9, 10, 11,},
                completed = {true, false}
            }

            local function randomFromArray(array)
                return array[math.random(1, #array)]
            end

            local totalRuns = math.random(100, 200)
            runHistory = {}

            for _index = 1, totalRuns do
                runHistory[_index] = {
                    mapChallengeModeID = randomFromArray(testData.dungeons),
                    level = randomFromArray(testData.levels),
                    completed = randomFromArray(testData.completed)
                }
            end
        else
            -- 真实数据
            runHistory = C_MythicPlus.GetRunHistory(false, true)
        end

        if #runHistory == 0 then
            return dunRuns
        end

        -- 对 runHistory 按 level、completed（未完成在前）降序排序
        table.sort(runHistory, function(leftRun, rightRun)
            if leftRun.level ~= rightRun.level then
                return leftRun.level > rightRun.level
            end
            if leftRun.completed ~= rightRun.completed then
                return leftRun.completed
            end
            return leftRun.mapChallengeModeID < rightRun.mapChallengeModeID
        end)

        -- 处理 TOP8
        for _index = 1, math.min(8, #runHistory) do
            local _run = runHistory[_index]
            dunRuns.TOP8[_index] = {
                dunID = _run.mapChallengeModeID,
                level = _run.level,
                overtime = not _run.completed
            }
        end

        -- 按副本分组统计所有记录
        local dungeonGroups = {}

        for _, _run in ipairs(runHistory) do
            local dungeonId = _run.mapChallengeModeID
            local dungeonGroup = dungeonGroups[dungeonId]

            if not dungeonGroup then
                dungeonGroup = {dunID = dungeonId, runs = {}}
                dungeonGroups[dungeonId] = dungeonGroup
                table.insert(dunRuns.TOTAL, dungeonGroup)
            end

            table.insert(dungeonGroup.runs, {
                level = _run.level,
                overtime = not _run.completed
            })
        end

        -- 对 dunRuns.TOTAL 按 dunID 升序排序
        table.sort(dunRuns.TOTAL, function(leftDun, rightDun)
            return leftDun.dunID < rightDun.dunID
        end)
        return dunRuns
    end

    -- ==================================================================
    -- 右下角调整大小手柄（仅用于打开时临时调整查看，重开恢复默认尺寸）
    local _grip = CreateFrame("Frame", "MPPE_WRF_ResizeGrip", weeklyReportFrame)
    _grip:SetSize(10, 10)
    _grip:SetPoint("BOTTOMRIGHT", weeklyReportFrame, "BOTTOMRIGHT", -1, 2)
    _grip:EnableMouse(true)
    _grip:RegisterForDrag("LeftButton")
    _grip:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            self:GetParent():StartSizing("BOTTOMRIGHT")
            -- OnUpdate 检测左键释放后正确结束调整大小
            self:SetScript("OnUpdate", function(s)
                if not IsMouseButtonDown("LeftButton") then
                    s:SetScript("OnUpdate", nil)
                    s:GetParent():StopMovingOrSizing()
                    -- 恢复对 PVEFrame 的跟随锚点（保持手动调整后的尺寸不变）
                    s:GetParent():ReanchorToTarget()
                end
            end)
        end
    end)
    local _gripTex = _grip:CreateTexture(nil, "OVERLAY")
    _gripTex:SetAllPoints()
    _gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    -- 鼠标悬停高亮：默认金黄色不透明，进入时切换为加法混合并提亮为白色，移开后还原
    local gripDefaultAlpha = 1
    _gripTex:SetAlpha(gripDefaultAlpha)
    _gripTex:SetVertexColor(1, 1, 0.6)
    _grip:SetScript("OnEnter", function()
        _gripTex:SetBlendMode("ADD")
        _gripTex:SetAlpha(1)
        _gripTex:SetVertexColor(1, 1, 1)
    end)
    _grip:SetScript("OnLeave", function()
        _gripTex:SetBlendMode("BLEND")
        _gripTex:SetAlpha(gripDefaultAlpha)
        _gripTex:SetVertexColor(1, 1, 0.6)
    end)
    -- 抬高手柄层级，确保不被滚动条等元素遮挡、可正常点击拖动
    _grip:SetFrameLevel(weeklyReportFrame:GetFrameLevel() + 20)
    weeklyReportFrame.resizeGrip = _grip

    -- 将框架赋值给 mppe.WeeklyReportFrame 以供外部函数使用
    mppe.WeeklyReportFrame = weeklyReportFrame
end

-- 确保周报窗体已初始化（未启用时不创建，懒初始化避免占用资源）
local function EnsureWeeklyReportInit()
    if mppe.WeeklyReportFrame then return true end
    if not MythicPlusPageExtensionDB.WeeklyReport_Enable then return false end
    CreateWeeklyReportFrame()
    return true
end

-- ==================================================================
-- 外部接口
-- ==================================================================

-- 显示或隐藏周报窗体（未启用时隐藏且不创建窗体）
function mppe.WeeklyFrameShowOrHide(show)
    if not MythicPlusPageExtensionDB.WeeklyReport_Enable then
        local frame = mppe.WeeklyReportFrame
        if frame then frame:Hide() end
        return
    end
    if not EnsureWeeklyReportInit() then return end
    local frame = mppe.WeeklyReportFrame
    if show then
        frame:Show()
        mppe.RefreshWeeklyReport()
    else
        frame:Hide()
    end
end

-- 根据设置的窗口样式刷新周报内容
function mppe.RefreshWeeklyReport(isTestMode)
    local frame = mppe.WeeklyReportFrame
    if not frame then return end
    if MythicPlusPageExtensionDB.WeeklyReport_FrameStyle == "accordion" then
        Accordion_Show(isTestMode)
    else
        mppe.WeeklyReport_TextMode(isTestMode)
    end
end

-- ==================================================================
-- 监听 PLAYER_LOGIN：仅在启用周报时初始化主窗体
-- ==================================================================
local loginFrame = CreateFrame("Frame")
loginFrame:RegisterEvent("PLAYER_LOGIN")
loginFrame:SetScript("OnEvent", function()
    -- 仅在启用周报时初始化，避免不启用时占用资源
    if MythicPlusPageExtensionDB.WeeklyReport_Enable then
        CreateWeeklyReportFrame()
    end
end)