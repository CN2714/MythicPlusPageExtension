local ADDON_NAME, mppe = ...
local Translate = mppe.Translate
-- 公会/队伍钥石窗口（空窗口骨架，参考 mppeFrame 样式）

-- LibKeystone / LibOpenRaid 引用与公会钥石缓存（名字 -> { mapID, level, rating }）
local LKS = LibStub("LibKeystone")
local LOR = LibStub("LibOpenRaid-1.0")
mppe.GuildKS = mppe.GuildKS or {}

-- 窗口框架引用（首次创建后缓存）
local mppe_KeysFrame = nil
-- 公会钥石缓存清空定时器（窗体隐藏 1 分钟后销毁数据）
local _guildClearTimer = nil

-- 前向声明（initScrollUI/updateLayout 定义在本文件后方，createKeysFrame 需要提前引用）
local initScrollUI, updateLayout

-- 创建空窗口框架的函数（参考 WeeklyReport.lua 中 mppeFrame 的创建方式）
local function createKeysFrame()
    mppe_KeysFrame = CreateFrame("Frame", "MPPE_KSFrame", UIParent, "SettingsFrameTemplate")
    mppe_KeysFrame:SetSize(400, 400)
    mppe_KeysFrame:SetPoint("CENTER")
    mppe_KeysFrame:SetMovable(true)
    mppe_KeysFrame:EnableMouse(true)
    mppe_KeysFrame:SetClampedToScreen(true)
    mppe_KeysFrame:SetScript("OnShow", function()
        -- 显示时取消待执行的缓存清空定时器
        if _guildClearTimer then
            _guildClearTimer:Cancel()
            _guildClearTimer = nil
        end
        -- 每次显示时刷新窗口内容（真实模式）
        mppe.GuildAndPartyKS_Refresh(false)
        -- 打开时请求一次公会钥石信息（收到回复后动态追加展示）
        mppe.GuildAndPartyKS_RequestGuild()
    end)
    mppe_KeysFrame:SetScript("OnHide", function()
        -- 隐藏 1 分钟后清空公会钥石缓存，避免脏数据遗留
        if _guildClearTimer then _guildClearTimer:Cancel() end
        _guildClearTimer = C_Timer.After(60, function()
            _guildClearTimer = nil
            table.wipe(mppe.GuildKS)
        end)
    end)
    mppe_KeysFrame:Hide()

    -- 标题
    mppe_KeysFrame.title = mppe_KeysFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mppe_KeysFrame.title:SetPoint("TOP", mppe_KeysFrame, 0, -5)
    mppe_KeysFrame.title:SetText(Translate["MPPE - Guild and Party Keystones"])

    -- 标题栏（仅点击标题栏区域可拖动窗口）
    local _titleBar = CreateFrame("Button", "MPPE_KSTitleBar", mppe_KeysFrame)
    _titleBar:SetHeight(28)
    _titleBar:SetPoint("TOPLEFT", mppe_KeysFrame, "TOPLEFT", 0, 0)
    _titleBar:SetPoint("TOPRIGHT", mppe_KeysFrame, "TOPRIGHT", 0, 0)
    _titleBar:EnableMouse(true)
    -- 用 OnMouseDown 按下立即响应拖动，避免 RegisterForDrag/OnDragStart 的触发延迟
    _titleBar:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            self.startCursorX, self.startCursorY = GetCursorPosition()
            self.startLeft, self.startBottom = mppe_KeysFrame:GetLeft(), mppe_KeysFrame:GetBottom()
            self.uiScale = mppe_KeysFrame:GetEffectiveScale()
            self:SetScript("OnUpdate", function(s)
                -- 左键已释放则停止拖动
                if not IsMouseButtonDown("LeftButton") then
                    s:SetScript("OnUpdate", nil)
                    return
                end
                local _curX, _curY = GetCursorPosition()
                local _dx = (_curX - s.startCursorX) / s.uiScale
                local _dy = (_curY - s.startCursorY) / s.uiScale
                local _newLeft = s.startLeft + _dx
                local _newBottom = s.startBottom + _dy
                -- 屏幕边界钳制（模拟 SetClampedToScreen）
                local _screenW = UIParent:GetWidth()
                local _screenH = UIParent:GetHeight()
                _newLeft = math.max(0, math.min(_screenW - mppe_KeysFrame:GetWidth(), _newLeft))
                _newBottom = math.max(0, math.min(_screenH - mppe_KeysFrame:GetHeight(), _newBottom))
                mppe_KeysFrame:ClearAllPoints()
                mppe_KeysFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", _newLeft, _newBottom)
            end)
        end
    end)
    mppe_KeysFrame.titleBar = _titleBar

    -- 关闭按钮（SettingsFrameTemplate 自带）
    mppe_KeysFrame.ClosePanelButton:SetScript("OnClick", function()
        mppe_KeysFrame:Hide()
    end)

    -- 刷新按钮（位置/尺寸以关闭按钮为基准：紧贴其左侧并同尺寸；使用红色刷新三态图集；抬高层级避免被顶部标题栏遮挡）
    local _closeBtn = mppe_KeysFrame.ClosePanelButton
    local _refreshBtn = CreateFrame("Button", "MPPE_KS_RefreshBtn", mppe_KeysFrame)
    local _btnW, _btnH = _closeBtn:GetSize()
    _refreshBtn:SetSize(_btnW, _btnH)
    -- 右侧紧贴关闭按钮左侧（留 2px 间隙），垂直与关闭按钮居中
    _refreshBtn:SetPoint("RIGHT", _closeBtn, "LEFT", -2, 0)
    -- 抬高层级到标题栏之上（标题栏覆盖顶部 28px，默认层级会拦截鼠标事件，导致点击/tooltip 失效）
    _refreshBtn:SetFrameLevel(mppe_KeysFrame:GetFrameLevel() + 50)
    -- 三态纹理：正常 / 按下 / 高亮（128-RedButton-Refresh 系列为图集，用 SetAtlas 系列方法）
    _refreshBtn:SetNormalAtlas("128-RedButton-Refresh")
    _refreshBtn:SetPushedAtlas("128-RedButton-Refresh-Pressed")
    _refreshBtn:SetHighlightAtlas("128-RedButton-Refresh-Highlight")
    _refreshBtn:SetScript("OnClick", function()
        -- 强制刷新：先销毁旧公会钥石缓存，再重新申请数据
        table.wipe(mppe.GuildKS)
        mppe.GuildAndPartyKS_Refresh(mppe_KeysFrame.isTestMode or false)
        mppe.GuildAndPartyKS_RequestGuild()
    end)
    _refreshBtn:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(mppe.Translate['Refresh'], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    _refreshBtn:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    mppe_KeysFrame.refreshBtn = _refreshBtn

    -- 初始化列表滚动区域
    initScrollUI()

    -- 底部提示栏（高度与标题栏相同）
    local _footer = CreateFrame("Frame", "MPPE_KSFooter", mppe_KeysFrame)
    _footer:SetHeight(20)
    _footer:SetPoint("BOTTOMLEFT", mppe_KeysFrame, "BOTTOMLEFT", 6, 2)
    _footer:SetPoint("BOTTOMRIGHT", mppe_KeysFrame, "BOTTOMRIGHT", -1, 0)
    local _footerBg = _footer:CreateTexture(nil, "BACKGROUND")
    _footerBg:SetAllPoints()
    _footerBg:SetColorTexture(0.3, 0.3, 0.3, 1)
    local _footerText = _footer:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _footerText:SetPoint("CENTER")
    _footerText:SetText(string.format("|c00ffff63%s|r", Translate["Click name to create PM (manual send)."]))
    mppe_KeysFrame.footer = _footer

    -- 滚动区域底部紧贴提示栏顶部（footer 创建后再重锚定，后续调整 footer 也会自动跟随）
    mppe_KeysFrame.scrollFrame:ClearAllPoints()
    mppe_KeysFrame.scrollFrame:SetPoint("TOPLEFT", mppe_KeysFrame, "TOPLEFT", 10, -28)
    mppe_KeysFrame.scrollFrame:SetPoint("BOTTOMRIGHT", mppe_KeysFrame.footer, "TOPRIGHT", -20, 0)

    -- 窗口可调整大小（当前版本用 SetResizeBounds 设置大小范围；最小宽度360保证三列放得下）
    mppe_KeysFrame:SetResizable(true)
    mppe_KeysFrame:SetResizeBounds(360, 300, 650, 700)

    -- 右下角调整大小手柄
    local _grip = CreateFrame("Frame", "MPPE_KSResizeGrip", mppe_KeysFrame)
    _grip:SetSize(10, 10)
    _grip:SetPoint("BOTTOMRIGHT", mppe_KeysFrame, "BOTTOMRIGHT", -1, 2)
    _grip:EnableMouse(true) -- Frame 默认不接收鼠标事件，必须启用才能拖动
    _grip:RegisterForDrag("LeftButton")
    _grip:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            self:GetParent():StartSizing("BOTTOMRIGHT")
            -- OnUpdate 检测左键释放后正确结束调整大小
            self:SetScript("OnUpdate", function(s)
                if not IsMouseButtonDown("LeftButton") then
                    s:SetScript("OnUpdate", nil)
                    s:GetParent():StopMovingOrSizing()
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
    _grip:SetFrameLevel(mppe_KeysFrame:GetFrameLevel() + 20)
    mppe_KeysFrame.resizeGrip = _grip

    -- 窗口大小变化时自动调整内容布局（钥石列自适应）
    mppe_KeysFrame:SetScript("OnSizeChanged", function()
        updateLayout()
    end)

    -- 应用初始布局
    updateLayout()

    return mppe_KeysFrame
end

-- 打开/切换钥石窗口的统一入口（isTestMode 为 true 时演示数据；bToggle 为 true 且窗口已显示时隐藏）
function mppe.GuildAndPartyKS_Open(isTestMode, bToggle)
    -- 功能开关：GuildAndPartyKS_Enable 未启用时不执行
    if not (MythicPlusPageExtensionDB and MythicPlusPageExtensionDB.GuildAndPartyKS_Enable) then
        print("[MPPE] " .. (mppe.Translate['Guild/Party Keystones disabled. Enable it in Settings (/mppe).'] or "Guild/Party Keystones disabled. Enable it in Settings (/mppe)."))
        return
    end
    if not mppe_KeysFrame then mppe_KeysFrame = createKeysFrame() end
    if bToggle and mppe_KeysFrame:IsShown() then
        mppe_KeysFrame:Hide()
        return
    end
    mppe_KeysFrame:Show()
    -- Show 会触发 OnShow 刷新（真实模式），此处再按需覆盖为演示数据
    mppe.GuildAndPartyKS_Refresh(isTestMode or false)
end

-- ==================================================================
-- 公会/队伍钥石窗口：列表内容与刷新逻辑
-- ==================================================================

-- 列表行高与可见行数（窗口 400x400，标题下方约 360px 可用）
local ROW_HEIGHT = 22
local VISIBLE_ROWS = 15
-- 史诗钥石物品ID
local KEYSTONE_ITEM_ID = 180653
-- 分组折叠状态（点击分组标题行切换；party=小队，guild=公会）
local _sectionExpanded = { party = true, guild = true }

-- 列宽布局：名称列与钥石列始终各占 50%（可分配宽度 = 内容宽 - 间距 - 边距）
local COL_GAP = 5           -- 名称列与钥石列间距
local CONTENT_MARGIN = 12   -- 内容左右边距合计

-- 构造钥石链接的函数（Hkeystone 格式：itemID:mapID:level:affix1..affix5，悬停可显示钥石信息）
local function buildKeystoneLink(mapID, level)
    local _dungeonName = C_ChallengeMode.GetMapUIInfo(mapID) or "Unknown"
    -- 参考 Fake_Keystones 插件的 Hkeystone 链接格式（词缀先用 0 占位）
    return string.format(
        "|cffa335ee|Hkeystone:%d:%d:%d:0:0:0:0:0|h[+%d %s]|h|r",
        KEYSTONE_ITEM_ID, mapID, level, level, _dungeonName
    )
end

-- 构建公会名册 纯名 → 职业英文标识 的映射（取自 GetGuildRosterInfo 第11返回值 classFileName，供名字染色）
local function buildGuildClassMap()
    local _map = {}
    local _count = GetNumGuildMembers() or 0
    for _i = 1, _count do
        local _name = GetGuildRosterInfo(_i)
        if _name then
            -- 名册名字可能带 Realm（Name-Realm），统一提取纯名与 GuildKS 缓存 key 对齐
            local _pureName = Ambiguate and Ambiguate(_name, "none") or (_name:gsub("^([^-]+)%-?.*", "%1"))
            local _classFile = select(11, GetGuildRosterInfo(_i))
            if _pureName and _pureName ~= "" and _classFile and _classFile ~= "" then
                _map[_pureName] = _classFile
            end
        end
    end
    return _map
end

-- 生成演示数据的函数（测试模式使用，mapID 为挑战模式副本ID；classFile 供名字染色预览）
local function generateTestData()
    local _partyList = {
        { name = UnitName("player"), mapID = 499, level = 17, classFile = select(2, UnitClass("player")) }, -- 圣焰隐修院
        { name = "测试队员B", mapID = 500, level = 12, classFile = "MAGE" }, -- 驭雷栖巢
        { name = "测试队员C", mapID = 503, level = 10, classFile = "PRIEST" }, -- 艾拉-卡拉，回响之城
        { name = "测试队员D", mapID = 504, level = 8,  classFile = "WARRIOR" },  -- 暗焰裂口
    }
    local _guildList = {
        { name = "测试会员A", mapID = 499, level = 19, classFile = "PALADIN" }, -- 圣焰隐修院
        { name = "测试会员B", mapID = 525, level = 15, classFile = "MAGE" }, -- 水闸行动
        { name = "测试会员C", mapID = 500, level = 14, classFile = "PRIEST" }, -- 驭雷栖巢
        { name = "测试会员D", mapID = 504, level = 11, classFile = "WARRIOR" }, -- 暗焰裂口
        { name = "测试会员E", mapID = 382, level = 9,  classFile = "HUNTER" },  -- 剧场
        { name = "测试会员F", mapID = 501, level = 18, classFile = "DRUID" }, -- 石库
        { name = "测试会员G", mapID = 502, level = 13, classFile = "ROGUE" }, -- 丝线之城
        { name = "测试会员H", mapID = 505, level = 16, classFile = "SHAMAN" }, -- 破晓者号
        { name = "测试会员I", mapID = 506, level = 12, classFile = "WARLOCK" }, -- 硫磺酒坊
        { name = "测试会员J", mapID = 542, level = 10, classFile = "DEATHKNIGHT" }, -- 艾尔多姆生态穹顶
        { name = "测试会员K", mapID = 557, level = 17, classFile = "MONK" }, -- 风行者尖塔
        { name = "测试会员L", mapID = 558, level = 8,  classFile = "DEMONHUNTER" },  -- 魔导师平台
        { name = "测试会员M", mapID = 559, level = 7,  classFile = "EVOKER" },  -- 克赛纳斯枢纽点
        { name = "测试会员N", mapID = 560, level = 6,  classFile = "PRIEST" },  -- 迈萨拉洞窟
        { name = "测试会员O", mapID = 503, level = 5,  classFile = "HUNTER" },  -- 艾拉-卡拉，回响之城
    }
    return _partyList, _guildList
end

-- 渲染单行的函数（分组标题行为可点击折叠菜单，成员行显示名字/钥石）
local function renderRow(row, entry)
    row.data = entry
    if entry.type == "header" then
        -- 分组标题：折叠标记（- 展开 / + 折叠）+ 成员数；点击整行或标题文字切换展开/折叠
        local _marker = _sectionExpanded[entry.section] and "-" or "+"
        row.nameFS:SetText(string.format("%s %s ( %d )", _marker, entry.text, entry.count or 0))
        row.nameFS:SetTextColor(1, 0.82, 0)
        row.keystone:SetText("")
        local _toggle = function()
            _sectionExpanded[entry.section] = not _sectionExpanded[entry.section]
            if mppe_KeysFrame then
                mppe.GuildAndPartyKS_Refresh(mppe_KeysFrame.isTestMode or false)
            end
        end
        -- 整行可点击（EnableMouse + OnMouseUp）
        row:EnableMouse(true)
        row:SetScript("OnMouseUp", function(self, _btn)
            if _btn == "LeftButton" then _toggle() end
        end)
        -- 标题文字按钮同样可点击（覆盖默认私信逻辑）
        row.name:SetScript("OnClick", _toggle)
    else
        row.nameFS:SetText(entry.data.name)
        -- 职业染色：有 classFile 时取 RAID_CLASS_COLORS 职业色，未知职业保持白色
        local _classColor = entry.data.classFile and RAID_CLASS_COLORS[entry.data.classFile]
        if _classColor then
            row.nameFS:SetTextColor(_classColor.r, _classColor.g, _classColor.b)
        else
            row.nameFS:SetTextColor(1, 1, 1)
        end
        row.keystone:SetText(buildKeystoneLink(entry.data.mapID, entry.data.level))
        row.keystone.data = entry.data -- 挂载数据供悬停 tooltip 使用
    end
end

-- 创建单行UI的函数（生成玩家名/钥石链接/私信按钮一行的完整UI）
local function createRowUI(parent)
    local _row = CreateFrame("Frame", nil, parent)
    _row:SetHeight(ROW_HEIGHT)
    -- 位置与宽度由 updateScrollList 通过 SetPoint(TOPLEFT/TOPRIGHT) 统一设置

    -- 玩家名（按钮：点击将私信内容填入聊天框，玩家确认后发送）
    _row.name = CreateFrame("Button", nil, _row)
    _row.name:SetPoint("LEFT", _row, "LEFT", 8, 0)
    _row.name:SetWidth(180)
    _row.name:SetHeight(ROW_HEIGHT)
    _row.name:SetNormalFontObject("GameFontHighlightSmall")
    _row.name:SetHighlightFontObject("GameFontHighlight")
    -- 名称文字 FontString（直接操作，避免 Button 文字机制不显示）
    _row.nameFS = _row.name:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _row.nameFS:SetPoint("LEFT", _row.name, "LEFT", 2, 0)
    _row.nameFS:SetPoint("RIGHT", _row.name, "RIGHT", -2, 0)
    _row.nameFS:SetJustifyH("LEFT")
    _row.nameFS:SetWordWrap(true)
    _row.nameFS:SetText("")
    _row.name:SetScript("OnClick", function(self)
        local _entry = self:GetParent().data
        if _entry and _entry.type == "member" and _entry.data then
            local _link = buildKeystoneLink(_entry.data.mapID, _entry.data.level)
            -- 原模式：直接发送私信（已注释保留，需要时可恢复）
            -- C_ChatInfo.SendChatMessage(string.format("能一起打你的%s吗？", _link), "WHISPER", nil, _entry.data.name)
            -- 新调整：填入聊天输入框（whisper），玩家确认后按回车再发送
            local _text = string.format(Translate["Can I run your %s?"], _link)
            ChatFrame_OpenChat(string.format("/w %s %s", _entry.data.name, _text), nil)
        end
    end)

    -- 钥石链接（Hkeystone 链接，悬停需手动触发 tooltip）
    _row.keystone = _row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _row.keystone:SetPoint("LEFT", _row.name, "RIGHT", 5, 0)
    _row.keystone:SetWidth(125)
    _row.keystone:SetJustifyH("LEFT")
    _row.keystone:SetWordWrap(true)
    -- 普通 FontString 不会自动显示超链接 tooltip，需手动 SetHyperlink
    _row.keystone:EnableMouse(true)
    _row.keystone:SetScript("OnEnter", function(self)
        local _data = self.data
        if _data then
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:SetHyperlink(buildKeystoneLink(_data.mapID, _data.level))
            GameTooltip:Show()
        end
    end)
    _row.keystone:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

    return _row
end

-- 更新滚动列表的函数（重建所有行；列宽/行高/定位由 updateLayout 统一处理）
local function updateScrollList(rows)
    if not mppe_KeysFrame or not mppe_KeysFrame.scrollContent then return end
    local _content = mppe_KeysFrame.scrollContent

    -- 清空旧行
    for _, _oldRow in ipairs(mppe_KeysFrame.rowsUI) do
        _oldRow:Hide()
        _oldRow:SetParent(nil)
    end
    mppe_KeysFrame.rowsUI = {}

    -- 重建所有行（仅设置内容，布局交给 updateLayout）
    for _i = 1, #rows do
        local _row = createRowUI(_content)
        renderRow(_row, rows[_i])
        table.insert(mppe_KeysFrame.rowsUI, _row)
    end

    -- 记录并恢复滚动位置（折叠/展开刷新不跳顶；内容变短由滚动框自动夹紧）
    local _oldScroll = mppe_KeysFrame.scrollFrame:GetVerticalScroll()
    updateLayout()
    mppe_KeysFrame.scrollFrame:SetVerticalScroll(_oldScroll)
end

-- 根据窗口大小调整内容布局：名称/钥石列始终各占 50%，并自动计算换行行高与重排
updateLayout = function()
    if not mppe_KeysFrame or not mppe_KeysFrame.scrollFrame or not mppe_KeysFrame.scrollContent then return end
    local _scrollWidth = mppe_KeysFrame.scrollFrame:GetWidth()
    local _contentWidth = math.max(_scrollWidth - 0, 100)
    mppe_KeysFrame.scrollContent:SetWidth(_contentWidth)

    -- 名称列与钥石列始终各占 50%（可分配宽度 = 内容宽 - 间距 - 边距）
    local _availWidth = math.max(_contentWidth - COL_GAP - CONTENT_MARGIN, 0)
    local _nameWidth = _availWidth * 0.5
    local _keystoneWidth = _availWidth * 0.5

    -- 重排所有行：设置列宽 → 按换行重算行高 → 累计定位
    local _cursor = 0
    for _i, _row in ipairs(mppe_KeysFrame.rowsUI) do
        if _row.name then _row.name:SetWidth(_nameWidth) end
        if _row.keystone then _row.keystone:SetWidth(_keystoneWidth) end
        -- 行高 = 名称/钥石换行后的最大实际高度（GetStringHeight 不依赖布局，窗口刚打开/刷新即可正确计算换行；至少 ROW_HEIGHT）
        local _rowH = ROW_HEIGHT
        if _row.data and _row.data.type == "member" then
            _rowH = math.max(_row.nameFS:GetStringHeight() or 0, _row.keystone:GetStringHeight() or 0, ROW_HEIGHT)
        end
        _row:SetHeight(_rowH)
        _row:ClearAllPoints()
        _row:SetPoint("TOPLEFT", mppe_KeysFrame.scrollContent, "TOPLEFT", 0, -_cursor)
        _row:SetPoint("TOPRIGHT", mppe_KeysFrame.scrollContent, "TOPRIGHT", 0, -_cursor)
        _cursor = _cursor + _rowH
    end
    mppe_KeysFrame.scrollContent:SetHeight(math.max(_cursor, 1))
end

-- 初始化列表滚动区域与内容容器的函数（创建窗口时调用一次）
initScrollUI = function()
    -- 标准滚动面板（UIPanelScrollFrameTemplate 自带滚动条，真实滚动内容）
    -- 右侧留出较大空间（-45），避免滚动条遮挡右下角调整大小手柄
    local _scroll = CreateFrame("ScrollFrame", nil, mppe_KeysFrame, "ScrollFrameTemplate")
    _scroll:SetPoint("TOPLEFT", mppe_KeysFrame, "TOPLEFT", 10, -28)
    _scroll:SetPoint("BOTTOMRIGHT", mppe_KeysFrame, "BOTTOMRIGHT", -20, 30) -- 底部预留提示栏高度
    _scroll:Show()
    mppe_KeysFrame.scrollFrame = _scroll

    -- 内容容器（所有行放入其中，高度随数据变化，可自动滚动）
    local _content = CreateFrame("Frame", nil, _scroll)
    _content:SetPoint("TOPLEFT", _scroll, "TOPLEFT", 0, 0)
    _content:SetWidth(350)
    _scroll:SetScrollChild(_content)
    mppe_KeysFrame.scrollContent = _content
    mppe_KeysFrame.rowsUI = {}
end

-- 刷新窗口内容的函数（isTestMode 为 true 时生成演示数据，否则真实数据从缓存读取）
function mppe.GuildAndPartyKS_Refresh(isTestMode)
    if not mppe_KeysFrame then mppe_KeysFrame = createKeysFrame() end
    mppe_KeysFrame.isTestMode = isTestMode or false

    local _partyList, _guildList
    if isTestMode then
        _partyList, _guildList = generateTestData()
    else
        -- 真实数据：小队/公会钥石分别从 PartyDB / GuildKS 缓存读取（过滤掉自己）
        _partyList = {}
        _guildList = {}
        local _myName = mppe.Mine.Name or UnitName("player")
        -- 小队：从 PartyDB 取有钥石的成员（class 为英文职业标识，供名字染色）
        for _fullName, _rec in pairs(mppe.PartyDB or {}) do
            if _rec.inParty and _rec.ksId and _rec.ksId > 0 and _rec.ksLv and _rec.ksLv > 0 then
                -- 过滤自己：PartyDB key 为 Name-Realm，提取纯名比较
                local _pureName = Ambiguate and Ambiguate(_fullName, "none") or (_fullName:gsub("^([^-]+)%-?.*", "%1"))
                if _pureName ~= _myName then
                    table.insert(_partyList, { name = _rec.name or _pureName, mapID = _rec.ksId, level = _rec.ksLv, classFile = _rec.class })
                end
            end
        end
        table.sort(_partyList, function(_a, _b) return _a.level > _b.level end)
        -- 公会：从 mppe.GuildKS 缓存读取（收到回复动态追加）
        local _guildClassMap = buildGuildClassMap()
        for _name, _data in pairs(mppe.GuildKS) do
            if _data and _data.mapID and _data.mapID > 0 and _data.level and _data.level > 0 then
                -- 过滤自己：缓存 key 可能是短名或 Name-Realm，统一提取纯名比较
                local _pureName = Ambiguate and Ambiguate(_name, "none") or (_name:gsub("^([^-]+)%-?.*", "%1"))
                if _pureName ~= _myName then
                    table.insert(_guildList, { name = _name, mapID = _data.mapID, level = _data.level, classFile = _guildClassMap[_pureName] })
                end
            end
        end
        table.sort(_guildList, function(_a, _b) return _a.level > _b.level end)
    end

    -- 组装带折叠分组标题的行列表（折叠的分组只保留标题行，不插入成员行）
    local _rows = {}
    table.insert(_rows, { type = "header", text = Translate["Party"], section = "party", count = #_partyList })
    if _sectionExpanded.party then
        for _, _data in ipairs(_partyList) do
            table.insert(_rows, { type = "member", data = _data })
        end
    end
    table.insert(_rows, { type = "header", text = Translate["Guild"], section = "guild", count = #_guildList })
    if _sectionExpanded.guild then
        for _, _data in ipairs(_guildList) do
            table.insert(_rows, { type = "member", data = _data })
        end
    end

    updateScrollList(_rows)
end

-- 请求一次公会钥石信息（LKS GUILD 频道 + LOR 公会请求，均自带节流）
function mppe.GuildAndPartyKS_RequestGuild()
    if not IsInGuild() then return end
    if LKS then LKS.Request("GUILD") end
    if LOR then LOR:RequestKeystoneDataFromGuild() end
end

-- ==================================================================
-- 公会钥石回复回调：收到 LKS GUILD / LOR Keystone 回复后写入缓存并动态刷新窗口
-- ==================================================================
do
    local _guildKSFrame = CreateFrame("Frame")
    if LKS then
        LKS.Register(_guildKSFrame, function(keyLevel, keyChallengeMapID, playerRating, shortName, channel)
            if channel ~= "GUILD" then return end
            if not shortName or shortName == "" then return end
            -- 仅窗体打开时接收并写入公会钥石，避免窗口关闭期间积累脏数据
            if not (mppe_KeysFrame and mppe_KeysFrame:IsShown()) then return end
            -- 有钥石才写入；无钥石不删除，避免与 LOR 来源互相覆盖导致先显示又消失
            if keyLevel and keyLevel > 0 and keyChallengeMapID and keyChallengeMapID > 0 then
                mppe.GuildKS[shortName] = { mapID = keyChallengeMapID, level = keyLevel, rating = playerRating or 0 }
                --print(string.format("MPPE: Received guild keystone from LKS: %s +%d (mapID=%d, rating=%d)", shortName, keyLevel, keyChallengeMapID, playerRating or 0))
            end
            -- 窗口打开时动态刷新（追加展示最新公会钥石；保持当前测试/真实模式）
            mppe.GuildAndPartyKS_Refresh(mppe_KeysFrame.isTestMode or false)
        end)
    end
    -- LOR 公会钥石（KeystoneUpdate 回调，独立注册不冲突；MPPE/AKS 仅小队共享，不处理）
    if LOR then
        local _lorKS = {}
        function _lorKS.OnKeystoneUpdate(unitName, keystoneInfo)
            if type(keystoneInfo) ~= "table" then return end
            if not unitName or unitName == "" then return end
            -- 仅窗体打开时接收并写入公会钥石，避免窗口关闭期间积累脏数据
            if not (mppe_KeysFrame and mppe_KeysFrame:IsShown()) then return end
            -- 统一 key 为短名（与 LKS 对齐），避免同一玩家两条
            local _key = Ambiguate and Ambiguate(unitName, "none") or unitName
            -- mythicPlusMapID 供 C_ChallengeMode.GetMapUIInfo 取副本名；challengeMapID 兜底
            local _level = rawget(keystoneInfo, "level") or 0
            local _mapID = rawget(keystoneInfo, "mythicPlusMapID") or rawget(keystoneInfo, "challengeMapID") or 0
            local _rating = rawget(keystoneInfo, "rating") or 0
            -- 有钥石才写入；无钥石不删除，避免与 LKS 来源互相覆盖导致先显示又消失
            if _level > 0 and _mapID > 0 then
                mppe.GuildKS[_key] = { mapID = _mapID, level = _level, rating = _rating }
                --print(string.format("MPPE: Received guild keystone from LOR: %s +%d (mapID=%d, rating=%d)", _key, _level, _mapID, _rating))
            end
            if mppe_KeysFrame and mppe_KeysFrame:IsShown() then
                mppe.GuildAndPartyKS_Refresh(mppe_KeysFrame.isTestMode or false)
            end
        end
        LOR.RegisterCallback(_lorKS, "KeystoneUpdate", "OnKeystoneUpdate")
    end
end