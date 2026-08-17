local ADDON_NAME, mppe = ...
local Translate = mppe.Translate
-- 公会/队伍钥石窗口（空窗口骨架，参考 mppeFrame 样式）

-- 窗口框架引用（首次创建后缓存）
local mppe_KeysFrame = nil

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
        -- 每次显示时刷新窗口内容（真实模式，真实数据部分暂留空）
        mppe.GuildAndPartyKS_Refresh(false)
    end)
    mppe_KeysFrame:Hide()

    -- 标题
    mppe_KeysFrame.title = mppe_KeysFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mppe_KeysFrame.title:SetPoint("TOP", mppe_KeysFrame, 0, -5)
    mppe_KeysFrame.title:SetText(Translate["MPPE - Keys"])

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

-- 切换窗口显示状态的函数（无参切换显示/隐藏）
function mppe.GuildAndPartyKS_Toggle()
    if not mppe_KeysFrame then mppe_KeysFrame = createKeysFrame() end
    if mppe_KeysFrame:IsShown() then
        mppe_KeysFrame:Hide()
    else
        mppe_KeysFrame:Show()
    end
end

-- 显示窗口并刷新内容的函数（isTestMode 为 true 时生成演示数据）
function mppe.GuildAndPartyKS_Show(isTestMode)
    if not mppe_KeysFrame then mppe_KeysFrame = createKeysFrame() end
    mppe_KeysFrame:Show()
    -- Show 会触发 OnShow 刷新（真实模式），此处再按需覆盖为演示数据
    mppe.GuildAndPartyKS_Refresh(isTestMode)
end

-- ==================================================================
-- 公会/队伍钥石窗口：列表内容与刷新逻辑
-- ==================================================================

-- 列表行高与可见行数（窗口 400x400，标题下方约 360px 可用）
local ROW_HEIGHT = 22
local VISIBLE_ROWS = 15
-- 史诗钥石物品ID
local KEYSTONE_ITEM_ID = 180653

-- 构造钥石链接的函数（Hkeystone 格式：itemID:mapID:level:affix1..affix5，悬停可显示钥石信息）
local function buildKeystoneLink(mapID, level)
    local _dungeonName = C_ChallengeMode.GetMapUIInfo(mapID) or "Unknown"
    -- 参考 Fake_Keystones 插件的 Hkeystone 链接格式（词缀先用 0 占位）
    return string.format(
        "|cffa335ee|Hkeystone:%d:%d:%d:0:0:0:0:0|h[+%d %s]|h|r",
        KEYSTONE_ITEM_ID, mapID, level, level, _dungeonName
    )
end

-- 生成演示数据的函数（测试模式使用，mapID 为挑战模式副本ID）
local function generateTestData()
    local _partyList = {
        { name = UnitName("player"), mapID = 499, level = 17 }, -- 圣焰隐修院
        { name = "测试队员B", mapID = 500, level = 12 }, -- 驭雷栖巢
        { name = "测试队员C", mapID = 503, level = 10 }, -- 艾拉-卡拉，回响之城
        { name = "测试队员D", mapID = 504, level = 8 },  -- 暗焰裂口
    }
    local _guildList = {
        { name = "测试会员A", mapID = 499, level = 19 }, -- 圣焰隐修院
        { name = "测试会员B", mapID = 525, level = 15 }, -- 水闸行动
        { name = "测试会员C", mapID = 500, level = 14 }, -- 驭雷栖巢
        { name = "测试会员D", mapID = 504, level = 11 }, -- 暗焰裂口
        { name = "测试会员E", mapID = 382, level = 9 },  -- 剧场
        { name = "测试会员F", mapID = 501, level = 18 }, -- 石库
        { name = "测试会员G", mapID = 502, level = 13 }, -- 丝线之城
        { name = "测试会员H", mapID = 505, level = 16 }, -- 破晓者号
        { name = "测试会员I", mapID = 506, level = 12 }, -- 硫磺酒坊
        { name = "测试会员J", mapID = 542, level = 10 }, -- 艾尔多姆生态穹顶
        { name = "测试会员K", mapID = 557, level = 17 }, -- 风行者尖塔
        { name = "测试会员L", mapID = 558, level = 8 },  -- 魔导师平台
        { name = "测试会员M", mapID = 559, level = 7 },  -- 克赛纳斯枢纽点
        { name = "测试会员N", mapID = 560, level = 6 },  -- 迈萨拉洞窟
        { name = "测试会员O", mapID = 503, level = 5 },  -- 艾拉-卡拉，回响之城
    }
    return _partyList, _guildList
end

-- 渲染单行的函数（根据条目类型显示分组标题或成员行）
local function renderRow(row, entry)
    row.data = entry
    if entry.type == "header" then
        row.nameFS:SetText(entry.text)
        row.nameFS:SetTextColor(1, 0.82, 0)
        row.keystone:SetText("")
    else
        row.nameFS:SetText(entry.data.name)
        row.nameFS:SetTextColor(1, 1, 1)
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
    _row.nameFS:SetText("")
    _row.name:SetScript("OnClick", function(self)
        local _entry = self:GetParent().data
        if _entry and _entry.type == "member" and _entry.data then
            local _link = buildKeystoneLink(_entry.data.mapID, _entry.data.level)
            -- 原模式：直接发送私信（已注释保留，需要时可恢复）
            -- C_ChatInfo.SendChatMessage(string.format("能一起打你的%s吗？", _link), "WHISPER", nil, _entry.data.name)
            -- 新调整：填入聊天输入框（whisper），玩家确认后按回车再发送
            local _text = string.format("能一起打你的[%s]吗？", _link)
            ChatFrame_OpenChat(string.format("/w %s %s", _entry.data.name, _text), nil)
        end
    end)

    -- 钥石链接（Hkeystone 链接，悬停需手动触发 tooltip）
    _row.keystone = _row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _row.keystone:SetPoint("LEFT", _row.name, "RIGHT", 5, 0)
    _row.keystone:SetWidth(125)
    _row.keystone:SetJustifyH("LEFT")
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

-- 更新滚动列表的函数（重建所有行并设置内容高度，UIPanelScrollFrameTemplate 自动滚动）
local function updateScrollList(rows)
    if not mppe_KeysFrame or not mppe_KeysFrame.scrollContent then return end
    local _content = mppe_KeysFrame.scrollContent

    -- 清空旧行
    for _, _oldRow in ipairs(mppe_KeysFrame.rowsUI) do
        _oldRow:Hide()
        _oldRow:SetParent(nil)
    end
    mppe_KeysFrame.rowsUI = {}

    -- 重建所有行
    local _count = #rows
    for _i = 1, _count do
        local _row = createRowUI(_content)
        _row:SetPoint("TOPLEFT", _content, "TOPLEFT", 0, -((_i - 1) * ROW_HEIGHT))
        _row:SetPoint("TOPRIGHT", _content, "TOPRIGHT", 0, -((_i - 1) * ROW_HEIGHT))
        renderRow(_row, rows[_i])
        table.insert(mppe_KeysFrame.rowsUI, _row)
    end

    -- 设置内容高度（决定滚动范围）
    _content:SetHeight(math.max(_count * ROW_HEIGHT, 1))
    -- 重置滚动到顶部
    mppe_KeysFrame.scrollFrame:SetVerticalScroll(0)
    -- 应用布局（钥石列自适应宽度）
    updateLayout()
end

-- 根据窗口大小调整内容布局的函数（玩家名/私信列宽固定，钥石列自适应）
updateLayout = function()
    if not mppe_KeysFrame or not mppe_KeysFrame.scrollFrame or not mppe_KeysFrame.scrollContent then return end
    local _scrollWidth = mppe_KeysFrame.scrollFrame:GetWidth()
    local _contentWidth = math.max(_scrollWidth - 0, 100)
    mppe_KeysFrame.scrollContent:SetWidth(_contentWidth)
    -- 钥石列宽 = 内容宽 - 名称列宽(180) - 间距(5) - 边距(12)
    local _keystoneWidth = math.max(_contentWidth - 180 - 5 - 12, 60)
    for _, _row in ipairs(mppe_KeysFrame.rowsUI) do
        if _row.keystone then
            _row.keystone:SetWidth(_keystoneWidth)
        end
    end
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

-- 刷新窗口内容的函数（isTestMode 为 true 时生成演示数据，否则真实数据暂留空）
function mppe.GuildAndPartyKS_Refresh(isTestMode)
    if not mppe_KeysFrame then mppe_KeysFrame = createKeysFrame() end

    local _partyList, _guildList
    if isTestMode then
        _partyList, _guildList = generateTestData()
    else
        -- TODO: 获取真实的小队/公会成员钥石信息（留空，后续实现）
        _partyList = {}
        _guildList = {}
    end

    -- 组装带分组标题的完整行列表
    local _rows = {}
    table.insert(_rows, { type = "header", text = "====小队====" })
    for _, _data in ipairs(_partyList) do
        table.insert(_rows, { type = "member", data = _data })
    end
    table.insert(_rows, { type = "header", text = "====公会====" })
    for _, _data in ipairs(_guildList) do
        table.insert(_rows, { type = "member", data = _data })
    end

    updateScrollList(_rows)
end

-- 调试诊断函数（打印窗口与列表状态，用于排查显示问题）
function mppe.GuildAndPartyKS_Debug()
    print("=== MPPE Keys Debug ===")
    print("frame="..tostring(mppe_KeysFrame))
    if not mppe_KeysFrame then return end
    print("frame shown="..tostring(mppe_KeysFrame:IsShown()).." size="..tostring(mppe_KeysFrame:GetWidth()).."x"..tostring(mppe_KeysFrame:GetHeight()))
    local _scroll = mppe_KeysFrame.scrollFrame
    print("scroll="..tostring(_scroll))
    if _scroll then
        print("scroll shown="..tostring(_scroll:IsShown()).." size="..tostring(_scroll:GetWidth()).."x"..tostring(_scroll:GetHeight()))
    end
    local _rowsUI = mppe_KeysFrame.rowsUI
    print("rowsUI count="..(_rowsUI and #_rowsUI or "nil"))
    if _rowsUI then
        for _i = 1, math.min(5, #_rowsUI) do
            local _row = _rowsUI[_i]
            local _text = (_row.name and _row.name:GetText()) or "no name"
            print("row".._i.." shown="..tostring(_row:IsShown()).." name=["..tostring(_text).."]")
        end
    end
end
