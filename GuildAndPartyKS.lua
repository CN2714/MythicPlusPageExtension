local ADDON_NAME, mppe = ...
local Translate = mppe.Translate
-- 公会/队伍钥石窗口（空窗口骨架，参考 mppeFrame 样式）

-- 公会钥石数据（缓存 / 接收器 / 请求）与筛选器控件分别由公共模块
-- GuildKeystoneCore.lua（mppe.GuildKeystoneCore）、GuildKeystoneFilterBar.lua（mppe.GuildKeystoneFilterBar）提供；
-- 队伍钥石走 Party* 系列（PartyDB / PartySyncService）

-- 窗口框架引用（首次创建后缓存）
local mppe_KeysFrame = nil
-- 公会职业映射缓存的释放定时器（窗体隐藏 10 秒后只释放 _guildMemberMapCache；
-- 公会钥石缓存由公共模块维护，不在这里清——否则会连名单页的数据一起清掉）
local _guildClearTimer = nil
-- 窗口初始化标志：createKeysFrame 内初始 Hide() 不触发 OnHide 清空定时器
local _guildInitializing = false
-- 公会钥石刷新防抖：首次 0.5s 快速刷新标记（每次打开窗口重置为 false，实现“首次快、后续慢”）
local _firstRefreshFired = false
-- 列表头高度（固定在滚动区域上方显示列标题；需在 createKeysFrame 之前声明以落入其词法作用域）
local HEADER_HEIGHT = 20
-- 相邻列间距（需在 createKeysFrame 之前声明，列头锚定需要引用）
local COL_GAP = 3
-- 标题栏高度（筛选器行与列表头的锚点基准；原先散落在 createKeysFrame 里的硬编码 28）
local TITLE_BAR_HEIGHT = 28

-- 性能排查调试开关（定位完卡顿后置 false 关闭 print）
local _gksDebug = false
local function _gksLog(...)
    if _gksDebug then print(...) end
end

-- 前向声明（initScrollUI/updateLayout 定义在本文件后方，createKeysFrame 需要提前引用）
local initScrollUI, updateLayout

-- 保存窗口当前的位置/大小到 SavedVariables（拖动/缩放结束或窗口隐藏时调用）
local function saveWindowState()
    if not MythicPlusPageExtensionDB or not mppe_KeysFrame then return end
    local _left, _bottom = mppe_KeysFrame:GetLeft(), mppe_KeysFrame:GetBottom()
    if not _left or not _bottom then return end
    local _state = MythicPlusPageExtensionDB.GuildAndPartyKS_Window or {}
    _state.left = _left
    _state.bottom = _bottom
    _state.width = mppe_KeysFrame:GetWidth()
    _state.height = mppe_KeysFrame:GetHeight()
    MythicPlusPageExtensionDB.GuildAndPartyKS_Window = _state
end

-- 恢复上次记忆的窗口位置/大小；无保存记录时返回 false（调用方保持默认居中 400x400）
local function restoreWindowState()
    if not MythicPlusPageExtensionDB or not mppe_KeysFrame then return false end
    local _state = MythicPlusPageExtensionDB.GuildAndPartyKS_Window
    if not _state or not _state.left or not _state.bottom or not _state.width or not _state.height then return false end
    local _w = math.max(_state.width, 360)
    local _h = math.max(_state.height, 300)
    mppe_KeysFrame:SetSize(_w, _h)
    -- 屏幕钳制：分辨率/缩放变化导致越界时夹回屏幕内
    local _screenW = UIParent:GetWidth()
    local _screenH = UIParent:GetHeight()
    local _left = math.max(0, math.min(_state.left, _screenW - _w))
    local _bottom = math.max(0, math.min(_state.bottom, _screenH - _h))
    mppe_KeysFrame:ClearAllPoints()
    mppe_KeysFrame:SetPoint("BOTTOMLEFT", UIParent, "BOTTOMLEFT", _left, _bottom)
    return true
end

-- ==================================================================
-- 筛选器行（下拉控件由公共模块 mppe.GuildKeystoneFilterBar 创建，样式与名单评分页一致）
-- 位置：标题栏下方、列表头（header）正上方；整组相对“窗体”水平居中
-- ==================================================================
local FILTER_TOP_GAP = 0              -- 筛选器行与标题栏条带的间距（0 = 紧贴标题栏；正数往下，负数会压进标题栏）
local FILTER_ROW_GAP = 5              -- 筛选器行与列表头之间的间距
-- 筛选器行占用的总高度（列表头与滚动区整体下移这么多）
local FILTER_ROW_TOTAL = mppe.GuildKeystoneFilterBar.HEIGHT + FILTER_TOP_GAP + FILTER_ROW_GAP

local _filter = nil                   -- 公共筛选器实例（createKeysFrame 里创建）

-- 筛选谓词：转发到公共筛选器（尚未创建时不限制）
local function passesWindowFilter(level, mapID, classFile)
    return not _filter or _filter:Passes(level, mapID, classFile)
end

-- 按筛选条件过滤一张成员列表（返回新表；无筛选条件时原样返回；供 test 模式的演示数据使用）
local function filterMemberList(list)
    if not (_filter and _filter:HasActive()) then return list end

    local _result = {}
    for _index = 1, #list do
        local _member = list[_index]
        if passesWindowFilter(_member.level, _member.mapID, _member.classFile) then
            _result[#_result + 1] = _member
        end
    end
    return _result
end

-- 创建空窗口框架的函数（参考 WeeklyReport.lua 中 mppeFrame 的创建方式）
local function createKeysFrame()
    _guildInitializing = true
    mppe_KeysFrame = CreateFrame("Frame", "MPPE_KSFrame", UIParent, "SettingsFrameTemplate")
    mppe_KeysFrame:SetSize(400, 400)
    mppe_KeysFrame:SetPoint("CENTER")
    mppe_KeysFrame:SetMovable(true)
    mppe_KeysFrame:EnableMouse(true)
    mppe_KeysFrame:SetClampedToScreen(true)
    -- 窗体提升到 DIALOG 层：窗体背景与内容整体盖过 MEDIUM 层外部 UI，避免背景被遮挡、内容却悬浮其上的割裂
    mppe_KeysFrame:SetFrameStrata("DIALOG")
    -- 恢复上次记忆的窗口位置/大小（无保存记录时保持默认居中 400x400）
    restoreWindowState()
    mppe_KeysFrame:SetScript("OnShow", function()
        _gksLog("[MPPE][GKS] OnShow") -- 追踪：窗口显示时机
        -- 重置首次快速刷新标记：本次打开首次收到回复用 0.5s 快速展示，后续请求 1.5s 节流
        _firstRefreshFired = false
        -- 显示时取消待执行的缓存清空定时器
        if _guildClearTimer then
            _guildClearTimer:Cancel()
            _guildClearTimer = nil
        end
        -- 每次显示时刷新窗口内容（真实模式），并强制重建一次公会职业映射（获取一次）
        mppe.GuildAndPartyKS_Refresh(false, true)
        -- 打开时请求一次公会钥石信息（收到回复后动态追加展示）
        mppe.GuildAndPartyKS_RequestGuild()
    end)
    mppe_KeysFrame:SetScript("OnHide", function()
        -- 初始化期间的初始 Hide()（createKeysFrame 末尾）不设置清空定时器
        if _guildInitializing then _guildInitializing = false return end
        _gksLog("[MPPE][GKS] OnHide") -- 追踪：窗口隐藏时机
        saveWindowState() -- 关闭时保存当前窗口位置/大小（下次打开保持）
        -- 隐藏 10 秒后释放公会职业映射缓存（钥石缓存由公共模块维护、不再在这里清空，
        -- 否则会把名单评分页正在用的数据一起清掉）
        if _guildClearTimer then _guildClearTimer:Cancel() end
        _guildClearTimer = C_Timer.After(10, function()
            _guildClearTimer = nil
            _guildMemberMapCache = nil -- 释放公会职业映射缓存
            -- 延迟主动全量 GC（窗口已隐藏，安全）：回收浮动垃圾并诊断内存是否回落
            C_Timer.After(1, function()
                local _envBefore = collectgarbage("count") / 1024
                local _addonBefore = (GetAddOnMemoryUsage and GetAddOnMemoryUsage(ADDON_NAME) or 0) / 1024
                collectgarbage("collect")
                local _envAfter = collectgarbage("count") / 1024
                local _addonAfter = (GetAddOnMemoryUsage and GetAddOnMemoryUsage(ADDON_NAME) or 0) / 1024
                _gksLog(string.format("[MPPE][GKS] GC collect: env %.1f->%.1fMB addon %.1f->%.1fMB", _envBefore, _envAfter, _addonBefore, _addonAfter))
            end)
        end)
    end)
    mppe_KeysFrame:Hide()
    _guildInitializing = false

    -- 标题
    mppe_KeysFrame.title = mppe_KeysFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    mppe_KeysFrame.title:SetPoint("TOP", mppe_KeysFrame, 0, -5)
    mppe_KeysFrame.title:SetText(Translate["MPPE - Guild and Party Keystones"])

    -- 标题栏（仅点击标题栏区域可拖动窗口）
    local _titleBar = CreateFrame("Button", "MPPE_KSTitleBar", mppe_KeysFrame)
    _titleBar:SetHeight(TITLE_BAR_HEIGHT)
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
                -- 左键已释放则停止拖动并保存窗口位置
                if not IsMouseButtonDown("LeftButton") then
                    s:SetScript("OnUpdate", nil)
                    saveWindowState()
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

    -- 关闭按钮（SettingsFrameTemplate 自带；模板默认 L510 过高，统一降到窗体基准 +10，覆盖内容即可）
    local _closeBtn = mppe_KeysFrame.ClosePanelButton
    _closeBtn:SetFrameLevel(mppe_KeysFrame:GetFrameLevel() + 10)
    _closeBtn:SetScript("OnClick", function()
        mppe_KeysFrame:Hide()
    end)

    -- 刷新按钮（位置/尺寸以关闭按钮为基准：紧贴其左侧并同尺寸；使用红色刷新三态图集；与关闭按钮同层）
    local _refreshBtn = CreateFrame("Button", "MPPE_KS_RefreshBtn", mppe_KeysFrame)
    local _btnW, _btnH = _closeBtn:GetSize()
    _refreshBtn:SetSize(_btnW, _btnH)
    -- 右侧紧贴关闭按钮左侧（留 2px 间隙），垂直与关闭按钮居中
    _refreshBtn:SetPoint("RIGHT", _closeBtn, "LEFT", -2, 0)
    -- 层级与关闭按钮一致（模板关闭按钮原为 L510，统一降到窗体+10 后两者同层，避免被标题栏/内容遮挡）
    _refreshBtn:SetFrameLevel(_closeBtn:GetFrameLevel())
    -- 三态纹理：正常 / 按下 / 高亮（128-RedButton-Refresh 系列为图集，用 SetAtlas 系列方法）
    _refreshBtn:SetNormalAtlas("128-RedButton-Refresh")
    _refreshBtn:SetPushedAtlas("128-RedButton-Refresh-Pressed")
    _refreshBtn:SetHighlightAtlas("128-RedButton-Refresh-Highlight")
    _refreshBtn:SetScript("OnClick", function()
        -- 强制刷新：清空公共公会钥石缓存并立即重新请求，然后重建窗口列表
        mppe.GuildKeystoneCore.ForceGuildRefresh()
        mppe.GuildAndPartyKS_Refresh(mppe_KeysFrame.isTestMode or false, true)
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

    -- 列表头：名称/钥石列标题（固定在滚动区域上方，不随内容滚动；列宽与行内由 updateLayout 统一对齐）
    local _header = CreateFrame("Frame", "MPPE_KSHeader", mppe_KeysFrame)
    _header:SetHeight(HEADER_HEIGHT)
    -- 底部紧贴滚动区域顶部（宽度与滚动区域一致，与内容列宽对齐）
    _header:SetPoint("BOTTOMLEFT", mppe_KeysFrame.scrollFrame, "TOPLEFT", 0, 0)
    _header:SetPoint("BOTTOMRIGHT", mppe_KeysFrame.scrollFrame, "TOPRIGHT", 0, 0)
    local _headerBg = _header:CreateTexture(nil, "BACKGROUND")
    _headerBg:SetAllPoints()
    _headerBg:SetColorTexture(0.3, 0.3, 0.3, 1)
    -- 名称列标题（左偏移/宽度与行内 name 列一致，由 updateLayout 同步；起点 0 相对原 8 整体左移 8px）
    _header.nameFS = _header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _header.nameFS:SetPoint("LEFT", _header, "LEFT", 0, 0)
    _header.nameFS:SetJustifyH("CENTER")
    _header.nameFS:SetText(string.format("|c00ffff63%s|r",Translate["Name"]))
    -- 分数列标题（名称列右侧 +5，固定宽度，与行内 score 列一致）
    _header.scoreFS = _header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _header.scoreFS:SetPoint("LEFT", _header.nameFS, "RIGHT", COL_GAP, 0)
    _header.scoreFS:SetJustifyH("CENTER")
    _header.scoreFS:SetText(string.format("|c00ffff63%s|r",Translate["Score"]))
    -- 钥石列标题（分数列右侧 +5，宽度与行内 keystone 列一致）
    _header.keystoneFS = _header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _header.keystoneFS:SetPoint("LEFT", _header.scoreFS, "RIGHT", COL_GAP, 0)
    _header.keystoneFS:SetJustifyH("CENTER")
    _header.keystoneFS:SetText(string.format("|c00ffff63%s|r",Translate["Keystone"]))
    -- 当前位置列标题（钥石列右侧 +5，宽度与行内 zone 列一致）
    _header.zoneFS = _header:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _header.zoneFS:SetPoint("LEFT", _header.keystoneFS, "RIGHT", COL_GAP, 0)
    _header.zoneFS:SetJustifyH("CENTER")
    _header.zoneFS:SetText(string.format("|c00ffff63%s|r",Translate["Zone"]))
    mppe_KeysFrame.header = _header

    -- 筛选器行（控件由公共模块创建，样式与名单评分页一致）：
    -- 整组锚在标题栏下方的“窗体水平中心”（TOP 锚点的 x 即窗体中心）；
    -- 内容整体下移 FILTER_ROW_TOTAL，见下面 scrollFrame 的锚点
    _filter = mppe.GuildKeystoneFilterBar.Create{
        parent = mppe_KeysFrame,
        namePrefix = "MPPE_GuildKSWinFilter",
        onChange = function()
            -- 条件变化：直接用缓存重建窗口列表（数据不用重新请求）
            if mppe_KeysFrame and mppe_KeysFrame:IsShown() then
                mppe.GuildAndPartyKS_Refresh(mppe_KeysFrame.isTestMode or false)
            end
        end,
    }
    _filter.bar:SetPoint("TOP", mppe_KeysFrame, "TOP", 0, -(TITLE_BAR_HEIGHT + FILTER_TOP_GAP))

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

    -- 滚动区域底部紧贴提示栏顶部（footer 创建后再重锚定，后续调整 footer 也会自动跟随）；
    -- 顶部下移：标题栏 + 筛选器行 + 列表头
    mppe_KeysFrame.scrollFrame:ClearAllPoints()
    mppe_KeysFrame.scrollFrame:SetPoint("TOPLEFT", mppe_KeysFrame, "TOPLEFT", 10, -(TITLE_BAR_HEIGHT + FILTER_ROW_TOTAL + HEADER_HEIGHT))
    mppe_KeysFrame.scrollFrame:SetPoint("BOTTOMRIGHT", mppe_KeysFrame.footer, "TOPRIGHT", -20, 0)

    -- 窗口可调整大小（当前版本用 SetResizeBounds 设置大小范围；最小宽度360保证三列放得下）
    mppe_KeysFrame:SetResizable(true)
    mppe_KeysFrame:SetResizeBounds(435, 300, 650, 700)

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
                    saveWindowState() -- 缩放结束：保存窗口大小/位置
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
    -- 抬高手柄层级：与关闭/刷新按钮同层（窗体+10），高于滚动轴/滚动条即可正常点击拖动
    _grip:SetFrameLevel(mppe_KeysFrame:GetFrameLevel() + 10)
    mppe_KeysFrame.resizeGrip = _grip

    -- 窗口大小变化时自动调整内容布局（钥石列自适应）
    mppe_KeysFrame:SetScript("OnSizeChanged", function()
        updateLayout()
    end)

    -- 应用初始布局
    updateLayout()

    return mppe_KeysFrame
end

-- 打开/切换钥石窗口的统一入口（args: 斜杠命令参数；"test"=测试模式打开 | "restore"=重置窗口位置并显示 | 其他/nil=真实模式切换）
function mppe.GuildAndPartyKS_Open(args)
    -- 解析子命令参数：restore 为维护性命令，不受功能开关限制
    local _sub = (type(args) == "string") and strlower(strtrim(args)) or ""
    local _bRestore = _sub == "restore"
    local _isTestMode = _sub == "test"
    local _bToggle = not _bRestore and _sub ~= "test"
    -- 功能开关：GuildAndPartyKS_Enable 未启用时不执行（restore 除外）
    if not _bRestore and not (MythicPlusPageExtensionDB and MythicPlusPageExtensionDB.GuildAndPartyKS_Enable) then return end
    if not mppe_KeysFrame then mppe_KeysFrame = createKeysFrame() end
    if _bToggle and mppe_KeysFrame:IsShown() then
        mppe_KeysFrame:Hide()
        return
    end
    -- 重置模式：show 前清空位置记忆并应用默认位置/大小（恢复居中 400x400）
    if _bRestore then
        if MythicPlusPageExtensionDB then MythicPlusPageExtensionDB.GuildAndPartyKS_Window = nil end
        mppe_KeysFrame:SetSize(400, 400)
        mppe_KeysFrame:ClearAllPoints()
        mppe_KeysFrame:SetPoint("CENTER")
        updateLayout()
    end
    mppe_KeysFrame:Show()
    -- Show 会触发 OnShow 刷新（真实模式），此处再按需覆盖为演示数据
    mppe.GuildAndPartyKS_Refresh(_isTestMode, true)
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

-- 列宽布局：名称列与钥石列各占剩余宽度 50%，分数列为固定宽度（可分配宽度 = 内容宽 - 分数列宽 - 间距 - 边距）
-- COL_GAP 在文件顶部声明（createKeysFrame 列头需要引用）
local CONTENT_MARGIN = 12   -- 内容左右边距合计
local SCORE_WIDTH = 45      -- 分数列固定宽度

-- 构造钥石链接的函数（Hkeystone 格式：itemID:mapID:level:affix1..affix5，悬停可显示钥石信息）
local function buildKeystoneLink(mapID, level)
    local _dungeonName = C_ChallengeMode.GetMapUIInfo(mapID) or "Unknown"
    -- 参考 Fake_Keystones 插件的 Hkeystone 链接格式（词缀先用 0 占位）
    return string.format(
        "|cffa335ee|Hkeystone:%d:%d:%d:0:0:0:0:0|h[%d %s]|h|r",
        KEYSTONE_ITEM_ID, mapID, level, level, _dungeonName
    )
end

-- 构造钥石显示文本（转公共模块：shortName 为 true 用本地化短名，未命中 / 缺翻译回退原名避免空显示）
local function buildKeystoneText(mapID, level, shortName)
    return mppe.GuildKeystoneCore.KeystoneText(mapID, level, shortName)
end

-- 构造钥石聊天纯文本（不含任何颜色/链接管道转义码，供私信发送；聊天发送时消息中的 "|" 会被当作转义码解析，含非法转义即报 Invalid escape code）
local function buildKeystoneChatText(mapID, level)
    local _dungeonName = C_ChallengeMode.GetMapUIInfo(mapID) or "Unknown"
    return string.format("%d %s", level, _dungeonName)
end

-- 拆分玩家名（可能是纯名或 Name-Realm）为：纯名（列表显示用）+ 私信目标名（跨服需带服务器名才能私信成功，同服用纯名）
local function splitDisplayName(fullName)
    -- 纯名统一走公共模块（Ambiguate("short") + 记忆化），保证与公会钥石缓存的 key 完全一致
    local _pureName = mppe.GuildKeystoneCore.PureName(fullName) or fullName
    -- 提取服务器名：取最后一个 "-" 之后的部分（服务器名不含 "-"；角色名本身可含 "-"，故从最后一个分隔）；无 "-" 则无服务器后缀
    local _realm = fullName:match("^.*%-(.+)$")
    -- 有服务器名且不是当前服：私信必须带服务器名；否则直接用纯名
    local _pmName = (_realm and _realm ~= "" and _realm ~= GetRealmName()) and (_pureName.."-".._realm) or _pureName
    return _pureName, _pmName
end

-- 公会名册 纯名 → 职业英文标识 缓存（职业为静态信息）
-- 重建时机：缓存为空 / 名册真的变过（_guildMemberMapDirty）/ 距上次重建超过 GUILD_MAP_MIN_INTERVAL 秒
-- 为什么加时间闸门：整册遍历（GetGuildRosterInfo × 成员数，每人数个字符串 + 一张小表）在人多的公会
-- 一次就是 1~3 MB 临时对象；而“反复开关窗口”会每开一次全量重建一次 → 短时间堆出几十 MB
-- （Blizzard 的归属记账把这些都算在本插件头上，于是内存监测会看到 100+ MB 的数字）。
local GUILD_MAP_MIN_INTERVAL = 30   -- 两次全量重建之间的最小间隔（秒）；“当前位置”列最多旧这么久
local _guildMemberMapCache = nil
local _guildMemberMapDirty = false
local _guildMemberMapTime = 0       -- 上次全量重建的时刻（GetTime）
local function buildGuildMemberMap(force)
    local _now = GetTime()

    -- 非强制：缓存有效且未标记重建 → 直接复用
    if _guildMemberMapCache and not force and not _guildMemberMapDirty then return _guildMemberMapCache end

    -- 强制重建也过时间闸门（名册真变过才例外）：职业是静态信息、位置列旧一点无所谓，
    -- 比每次开窗都整册遍历划算得多
    if _guildMemberMapCache and not _guildMemberMapDirty and (_now - _guildMemberMapTime) < GUILD_MAP_MIN_INTERVAL then
        return _guildMemberMapCache
    end

    local _start = debugprofilestop()
    local _map = {}
    local _mapCount = 0
    local _count, _online = GetNumGuildMembers()
    _count = _count or 0
    _online = _online or 0
    for _i = 1, _count do
        local _name, _, _, _, _, _zone, _, _, _isOnline, _, _classFile = GetGuildRosterInfo(_i)
        -- 遍历名册全部成员（含离线）：离线成员的职业（classFileName）同样能获取，供名字染色
        if _name and _classFile and _classFile ~= "" then
            -- 名册名字可能带 Realm（Name-Realm），统一提取纯名与公会钥石缓存 key 对齐（"short" 跨服也返回纯名）
            local _pureName = Ambiguate and Ambiguate(_name, "short") or (_name:gsub("^([^-]+)%-?.*", "%1"))
            if _pureName and _pureName ~= "" then
                _map[_pureName] = _map[_pureName] or {}
                _map[_pureName].class = _classFile
                _map[_pureName].zone = _zone or ""
                _mapCount = _mapCount + 1
            end
        end
    end
    _guildMemberMapCache = _map
    _guildMemberMapDirty = false
    _guildMemberMapTime = _now
    _gksLog(string.format("[MPPE][GKS] buildGuildMemberMap: total=%d online=%d map=%d cost=%.2fms", _count, _online, _mapCount, debugprofilestop() - _start))
    return _map
end

-- 名册加载完成（有成员数据）后即取消常驻监听：职业 map 之后只在打开/手动刷新时 force 重建（获取一次）
local _guildRosterFrame = CreateFrame("Frame")
_guildRosterFrame:RegisterEvent("GUILD_ROSTER_UPDATE")
_guildRosterFrame:SetScript("OnEvent", function()
    if (GetNumGuildMembers() or 0) > 0 then
        _guildRosterFrame:UnregisterEvent("GUILD_ROSTER_UPDATE")
    end
    _guildMemberMapDirty = true
end)

-- 生成演示数据的函数（测试模式使用，mapID 为挑战模式副本ID；classFile 供名字染色预览）
local function generateTestData()
    local _partyList = {
        { name = UnitName("player"), mapID = 499, level = 17, rating = 2850, classFile = select(2, UnitClass("player")) }, -- 圣焰隐修院
        { name = "测试队员B", mapID = 500, level = 12, rating = 1750, classFile = "MAGE" }, -- 驭雷栖巢
        { name = "测试队员C", mapID = 503, level = 10, rating = 1450, classFile = "PRIEST" }, -- 艾拉-卡拉，回响之城
        { name = "测试队员D", mapID = 504, level = 8,  rating = 900,  classFile = "WARRIOR" },  -- 暗焰裂口
    }
    local _guildList = {
        { name = "测试会员A", mapID = 499, level = 19, rating = 3250, classFile = "PALADIN" }, -- 圣焰隐修院
        { name = "测试会员B", mapID = 525, level = 15, rating = 2450, classFile = "MAGE" }, -- 水闸行动
        { name = "测试会员C", mapID = 500, level = 14, rating = 2050, classFile = "PRIEST" }, -- 驭雷栖巢
        { name = "测试会员D", mapID = 504, level = 11, rating = 1850, classFile = "WARRIOR" }, -- 暗焰裂口
        { name = "测试会员E", mapID = 382, level = 9,  rating = 1650, classFile = "HUNTER" },  -- 剧场
        { name = "测试会员F", mapID = 501, level = 18, rating = 1400, classFile = "DRUID" }, -- 石库
        { name = "测试会员G", mapID = 502, level = 13, rating = 1200, classFile = "ROGUE" }, -- 丝线之城
        { name = "测试会员H", mapID = 505, level = 16, rating = 950,  classFile = "SHAMAN" }, -- 破晓者号
        { name = "测试会员I", mapID = 506, level = 12, rating = 750,  classFile = "WARLOCK" }, -- 硫磺酒坊
        { name = "测试会员J", mapID = 542, level = 10, rating = 620,  classFile = "DEATHKNIGHT" }, -- 艾尔多姆生态穹顶
        { name = "测试会员K", mapID = 557, level = 17, rating = 480,  classFile = "MONK" }, -- 风行者尖塔
        { name = "测试会员L", mapID = 558, level = 8,  rating = 350,  classFile = "DEMONHUNTER" },  -- 魔导师平台
        { name = "测试会员M", mapID = 559, level = 7,  rating = 250,  classFile = "EVOKER" },  -- 克赛纳斯枢纽点
        { name = "测试会员N", mapID = 560, level = 6,  rating = 120,  classFile = "PRIEST" },  -- 迈萨拉洞窟
        { name = "测试会员O", mapID = 503, level = 5,  rating = 0,    classFile = "HUNTER" },  -- 艾拉-卡拉，回响之城
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
        row.score:SetText("") -- 清除复用行残留的分数
        row.keystone:SetText("")
        row.zone:SetText("")
        row.keystone.data = nil -- 清除复用行残留的成员数据，避免标题行误显示 tooltip
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
        -- 标题文字区域也显示行高亮（无 tooltip）
        row.name:SetScript("OnEnter", function(self)
            if row.bg then row.bg:Show() end
        end)
        row.name:SetScript("OnLeave", function(self)
            if row.bg then row.bg:Hide() end
        end)
    else
        -- 行复用：清除可能残留的分组标题折叠脚本，恢复成员私信点击逻辑
        row:SetScript("OnMouseUp", nil)
        row:EnableMouse(true)
        row.name:SetScript("OnClick", row.nameClick)
        -- 名字区域也显示行高亮 + 行 tooltip（name 按钮会拦截鼠标事件，需单独挂）
        row.name:SetScript("OnEnter", function(self)
            if row.bg then row.bg:Show() end
            row.tooltipEnter(row)
        end)
        row.name:SetScript("OnLeave", function(self)
            GameTooltip:Hide()
            if row.bg then row.bg:Hide() end
        end)
        row.nameFS:SetText(entry.data.displayName or entry.data.name)
        -- 职业染色：有 classFile 时取 RAID_CLASS_COLORS 职业色；职业未匹配（含无法获取职业的离线成员）染白灰色标记
        local _classColor = entry.data.classFile and RAID_CLASS_COLORS[entry.data.classFile]
        if _classColor then
            row.nameFS:SetTextColor(_classColor.r, _classColor.g, _classColor.b)
        else
            row.nameFS:SetTextColor(0.8, 0.8, 0.8)
        end
        -- 分数列：染色模式与 tooltip 一致（raiderio hex 染色），无分数显示 0
        local _rating = entry.data.rating or 0
        row.score:SetText(string.format("|c%s%d|r", mppe.GetColorByScore(_rating, "raiderio", true), _rating))
        -- 钥石列文本：GuildAndPartyKS_ShortDunName 开启时用短副本名（tooltip 内始终用原名，见行 tooltip）
        local _shortDun = MythicPlusPageExtensionDB and MythicPlusPageExtensionDB.GuildAndPartyKS_ShortDunName
        row.keystone:SetText(buildKeystoneText(entry.data.mapID, entry.data.level, _shortDun))
        row.zone:SetText(entry.data.zone or "")
        row.keystone.data = entry.data -- 挂载数据供悬停 tooltip 使用
    end
end

-- 创建单行UI的函数（生成玩家名/钥石链接/私信按钮一行的完整UI）
local function createRowUI(parent)
    local _row = CreateFrame("Frame", nil, parent)
    _row:SetHeight(ROW_HEIGHT)
    -- 位置与宽度由 updateScrollList 通过 SetPoint(TOPLEFT/TOPRIGHT) 统一设置
    -- 描边：名字/分数沿用 GameFontHighlightSmall 字号叠加 OUTLINE 黑色描边（提升彩色文字可读性）
    local _font, _size = GameFontHighlightSmall:GetFont()

    -- 玩家名（按钮：点击将私信内容填入聊天框，玩家确认后发送）
    _row.name = CreateFrame("Button", nil, _row)
    _row.name:SetPoint("LEFT", _row, "LEFT", 1, 0)
    _row.name:SetWidth(180)
    _row.name:SetHeight(ROW_HEIGHT)
    _row.name:SetNormalFontObject("GameFontHighlightSmall")
    _row.name:SetHighlightFontObject("GameFontHighlight")
    -- 名称文字 FontString（直接操作，避免 Button 文字机制不显示）
    _row.nameFS = _row.name:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _row.nameFS:SetFont(_font, _size, "OUTLINE") -- 黑色描边
    _row.nameFS:SetPoint("LEFT", _row.name, "LEFT", 2, 0)
    _row.nameFS:SetPoint("RIGHT", _row.name, "RIGHT", -2, 0)
    _row.nameFS:SetJustifyH("LEFT")
    _row.nameFS:SetWordWrap(true)
    _row.nameFS:SetText("")
    -- 私信点击逻辑（保存到行对象供行复用后恢复；行可能从分组标题复用为成员行，需要重新挂回该脚本）
    local function _nameClick(self)
        local _entry = self:GetParent().data
        if _entry and _entry.type == "member" and _entry.data then
            -- 用无转义码纯文本钥石描述（原名副本）：颜色码/超链接中的 "|" 在聊天发送时会被判为非法转义码（Invalid escape code）
            local _keystoneText = buildKeystoneChatText(_entry.data.mapID, _entry.data.level)
            -- 私信模板：设置里已存内容（含空串）时优先使用，仅未设置（nil）才回退默认模板
            local _pmContent = MythicPlusPageExtensionDB and MythicPlusPageExtensionDB.GuildAndPartyKS_PMContent
            local _template = (type(_pmContent) == "string") and _pmContent or Translate["Can I run your %s?"]
            -- 含 %s 占位符则替换为钥石纯文本，不含则原样使用（gsub 函数形式避免特殊字符被转义）
            local _text = _template:gsub("%%s", function() return _keystoneText end)
            -- 新调整：填入聊天输入框（whisper），玩家确认后按回车再发送
            ChatFrame_OpenChat(string.format("/w %s %s", _entry.data.name, _text), nil)
        end
    end
    _row.nameClick = _nameClick
    _row.name:SetScript("OnClick", _nameClick)

    -- 分数（固定宽度列，染色模式与 tooltip 一致：GetColorByScore raiderio hex）
    _row.score = _row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _row.score:SetFont(_font, _size, "OUTLINE") -- 黑色描边
    _row.score:SetPoint("LEFT", _row.name, "RIGHT", COL_GAP, 0)
    _row.score:SetWidth(SCORE_WIDTH)
    _row.score:SetJustifyH("CENTER")
    _row.score:SetText("")

    -- 钥石（纯文本模式，非超链接；悬停 tooltip 查看钥石信息）
    _row.keystone = _row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _row.keystone:SetFont(_font, _size, "OUTLINE") -- 黑色描边
    _row.keystone:SetPoint("LEFT", _row.score, "RIGHT", COL_GAP, 0)
    _row.keystone:SetWidth(125)
    _row.keystone:SetJustifyH("LEFT")
    _row.keystone:SetWordWrap(true)
    -- 纯文本模式：无超链接/无独立 tooltip，鼠标穿透到行，整行统一 tooltip

    -- 当前位置（区域名）：左锚定钥石列右侧 +1，右锚定到行右缘 -1（双锚定后自动占满行剩余空间）
    _row.zone = _row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    _row.zone:SetFont(_font, _size, "OUTLINE") -- 黑色描边
    _row.zone:SetPoint("LEFT", _row.keystone, "RIGHT", COL_GAP, 0)
    _row.zone:SetPoint("RIGHT", _row, "RIGHT", 0, 0)
    _row.zone:SetJustifyH("LEFT")
    _row.zone:SetWordWrap(false)
    _row.zone:SetText("")

    -- 行高亮：鼠标进入整行显示半透明背景（含名字/分数/钥石/位置区域）
    local _rowBg = _row:CreateTexture(nil, "BACKGROUND")
    _rowBg:SetAllPoints()
    _rowBg:SetColorTexture(0.3, 0.3, 0.3, 0.5)
    _rowBg:Hide()
    _row.bg = _rowBg
    -- 行 tooltip：鼠标悬停在整行任意位置显示成员信息（名字-评分-区域），锚点行上方
    _row.tooltipEnter = function(self)
        local _entry = self.data
        if not (_entry and _entry.type == "member" and _entry.data) then return end
        local _d = _entry.data
        local _classColor = _d.classFile and RAID_CLASS_COLORS[_d.classFile]
        local _nameColor = _classColor and _classColor:GenerateHexColor() or "FFCCCCCC"
        -- 锚点改为行右上角（_row.bg 与 _row 同尺寸，其右上角即行右上角；ANCHOR_TOPRIGHT 使 tooltip 固定在行右上外侧，不再跟随鼠标跳动）
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(string.format("|c%s%s|r", _nameColor, _d.name))
        GameTooltip:AddLine(string.format("%s: |c%s%s|r", Translate["Score"], mppe.GetColorByScore(_d.rating,"raiderio",true), _d.rating or "-"))
        local _dungeonName = C_ChallengeMode.GetMapUIInfo(_d.mapID) or Translate["UNKNOWN"]
        GameTooltip:AddLine(string.format("%s: |c%s%d %s|r", Translate["Keystone"], "FFFFFFFF", _d.level or "", _dungeonName))
        GameTooltip:AddLine(string.format("%s: |c%s%s|r", Translate["Zone"], "FFFFFFFF", _d.zone or Translate["UNKNOWN"]))
        GameTooltip:Show()
    end
    _row:EnableMouse(true)
    _row:SetScript("OnEnter", function(self)
        if self.bg then self.bg:Show() end
        self.tooltipEnter(self)
    end)
    _row:SetScript("OnLeave", function(self)
        GameTooltip:Hide()
        if self.bg then self.bg:Hide() end
    end)

    return _row
end

-- 更新滚动列表的函数（重建所有行；列宽/行高/定位由 updateLayout 统一处理）
local function updateScrollList(rows)
    if not mppe_KeysFrame or not mppe_KeysFrame.scrollContent then return end
    local _content = mppe_KeysFrame.scrollContent
    local _start = debugprofilestop()
    local _pool = mppe_KeysFrame.rowPool or {}

    -- 行复用：从对象池取行，只增删差值，不再每次刷新销毁/重建全部行 UI（避免公会人多时反复创建数百行 UI 对象）
    local _shownRows = {}
    for _i = 1, #rows do
        local _row = _pool[_i]
        if not _row then
            _row = createRowUI(_content)
            _pool[_i] = _row
        else
            _row:SetParent(_content)
            _row:Show()
        end
        renderRow(_row, rows[_i])
        _shownRows[_i] = _row
    end
    -- 隐藏多余行（保留在池中供下次复用，不销毁）
    for _i = #rows + 1, #_pool do
        _pool[_i]:Hide()
        _pool[_i]:SetParent(nil)
    end
    mppe_KeysFrame.rowPool = _pool
    mppe_KeysFrame.rowsUI = _shownRows

    -- 记录并恢复滚动位置（折叠/展开刷新不跳顶；内容变短由滚动框自动夹紧）
    local _oldScroll = mppe_KeysFrame.scrollFrame:GetVerticalScroll()
    updateLayout()
    mppe_KeysFrame.scrollFrame:SetVerticalScroll(_oldScroll)
    -- _gksLog(string.format("[MPPE][GKS] updateScrollList: rows=%d pool=%d reused=%d cost=%.2fms", #rows, #_pool, math.min(#rows, #_pool), debugprofilestop() - _start))
end

-- 根据窗口大小调整内容布局：名称/钥石列始终各占 50%，并自动计算换行行高与重排
updateLayout = function()
    if not mppe_KeysFrame or not mppe_KeysFrame.scrollFrame or not mppe_KeysFrame.scrollContent then return end
    local _start = debugprofilestop()
    local _scrollWidth = mppe_KeysFrame.scrollFrame:GetWidth()
    local _contentWidth = math.max(_scrollWidth - 0, 100)
    mppe_KeysFrame.scrollContent:SetWidth(_contentWidth)

    -- 名称/钥石/当前位置三列分配剩余宽度（可分配宽度 = 内容宽 - 分数列固定宽 - 3 个间距 - 边距）
    local _availWidth = math.max(_contentWidth - SCORE_WIDTH - COL_GAP * 3 - CONTENT_MARGIN, 0)
    -- 钥石列占比：GuildAndPartyKS_ShortDunName 开启（显示短名）时减半（0.4→0.3），让出的宽度由右锚定 zone 列自动吸收
    local _shortDun = MythicPlusPageExtensionDB and MythicPlusPageExtensionDB.GuildAndPartyKS_ShortDunName
    local _nameWidth = _availWidth * (_shortDun and 0.35 or 0.3)
    local _keystoneWidth = _availWidth * (_shortDun and 0.35 or 0.4)
    local _zoneWidth = _availWidth * 0.3

    -- 同步列表头列宽（与行内名称/分数/钥石/位置列完全对齐；分数列为固定宽度）
    local _header = mppe_KeysFrame.header
    if _header then
        _header:SetWidth(_contentWidth)
        if _header.nameFS then _header.nameFS:SetWidth(_nameWidth) end
        if _header.scoreFS then _header.scoreFS:SetWidth(SCORE_WIDTH) end
        if _header.keystoneFS then _header.keystoneFS:SetWidth(_keystoneWidth) end
        if _header.zoneFS then _header.zoneFS:SetWidth(_zoneWidth) end
    end

    -- 重排所有行：设置列宽 → 按换行重算行高 → 累计定位
    local _cursor = 0
    for _i, _row in ipairs(mppe_KeysFrame.rowsUI) do
        if _row.name then _row.name:SetWidth(_nameWidth) end
        if _row.score then _row.score:SetWidth(SCORE_WIDTH) end
        if _row.keystone then _row.keystone:SetWidth(_keystoneWidth) end
        -- zone 列不设固定宽度：createRowUI 已左/右双锚定，随行宽自动占满剩余空间（右留 1px）
        -- 行高 = 名称/钥石/位置换行后的最大实际高度（GetStringHeight 不依赖布局，窗口刚打开/刷新即可正确计算换行；至少 ROW_HEIGHT）
        local _rowH = ROW_HEIGHT
        if _row.data and _row.data.type == "member" then
            _rowH = math.max(_row.nameFS:GetStringHeight() or 0, _row.keystone:GetStringHeight() or 0, _row.zone:GetStringHeight() or 0, ROW_HEIGHT)
        end
        _row:SetHeight(_rowH)
        _row:ClearAllPoints()
        _row:SetPoint("TOPLEFT", mppe_KeysFrame.scrollContent, "TOPLEFT", 0, -_cursor)
        _row:SetPoint("TOPRIGHT", mppe_KeysFrame.scrollContent, "TOPRIGHT", 0, -_cursor)
        _cursor = _cursor + _rowH
    end
    mppe_KeysFrame.scrollContent:SetHeight(math.max(_cursor, 1))
    -- _gksLog(string.format("[MPPE][GKS] updateLayout: rows=%d cost=%.2fms", #mppe_KeysFrame.rowsUI, debugprofilestop() - _start))
end

-- 初始化列表滚动区域与内容容器的函数（创建窗口时调用一次）
initScrollUI = function()
    -- 标准滚动面板（UIPanelScrollFrameTemplate 自带滚动条，真实滚动内容）
    -- 右侧留出较大空间（-45），避免滚动条遮挡右下角调整大小手柄
    local _scroll = CreateFrame("ScrollFrame", nil, mppe_KeysFrame, "ScrollFrameTemplate")
    -- 顶部下移：标题栏 + 筛选器行 + 列表头
    _scroll:SetPoint("TOPLEFT", mppe_KeysFrame, "TOPLEFT", 10, -(TITLE_BAR_HEIGHT + FILTER_ROW_TOTAL + HEADER_HEIGHT))
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
    mppe_KeysFrame.rowPool = {}
end

-- 构建小队成员 纯名 → 当前区域 的映射（实时查询 C_Map，供"当前位置"列展示；GetBestMapForUnit 仅对玩家/队员有效）
local function buildPartyZoneMap()
    local _map = {}
    local _count = GetNumSubgroupMembers() -- 不含自己
    for _i = 1, _count do
        local _unit = "party".._i
        local _unitName = UnitName(_unit)
        if _unitName and _unitName ~= "" then
            local _pureName = Ambiguate and Ambiguate(_unitName, "short") or _unitName
            local _mapID = C_Map.GetBestMapForUnit(_unit)
            if _mapID then
                local _info = C_Map.GetMapInfo(_mapID)
                if _info and _info.name then
                    _map[_pureName] = _info.name
                end
            end
        end
    end
    return _map
end

-- 上一次刷新时的公会缓存条数（诊断：检测 cache 意外减少，定位人数减少问题）
local _lastGuildCacheCount = nil

-- 刷新窗口内容的函数（isTestMode 为 true 时生成演示数据，否则真实数据从缓存读取）
function mppe.GuildAndPartyKS_Refresh(isTestMode, forceClassMap)
    if not mppe_KeysFrame then mppe_KeysFrame = createKeysFrame() end
    mppe_KeysFrame.isTestMode = isTestMode or false
    local _start = debugprofilestop()

    local _partyList, _guildList
    if isTestMode then
        _partyList, _guildList = generateTestData()
        -- 演示数据同样套筛选，便于用 /mppe keys test 验证筛选器
        _partyList = filterMemberList(_partyList)
        _guildList = filterMemberList(_guildList)
    else
        -- 真实数据：小队钥石从 PartyDB 取、公会钥石从公共缓存 mppe.GuildKeystoneCore.cache 取（过滤掉自己）
        _partyList = {}
        _guildList = {}
        local _myName = mppe.Mine.Name or UnitName("player")
        -- 小队：仅当设置 GuildAndPartyKS_ShowParty 为真时才加载（从 PartyDB 取有钥石的成员，class 为英文职业标识供名字染色）
        if MythicPlusPageExtensionDB.GuildAndPartyKS_ShowParty then
            -- 小队成员当前位置映射（实时查询，供"当前位置"列）
            local _partyZoneMap = buildPartyZoneMap()
            for _fullName, _rec in pairs(mppe.PartyDB or {}) do
                if _rec.inParty and _rec.ksId and _rec.ksId > 0 and _rec.ksLv and _rec.ksLv > 0 then
                    -- 过滤自己：PartyDB key 为 Name-Realm，提取纯名比较；name 为私信目标名（跨服带服务器），displayName 为显示用纯名
                    local _pureName, _pmName = splitDisplayName(_fullName)
                    -- 过滤自己 + 筛选器（职业 / 层数区间 / 副本）
                    if _pureName ~= _myName and passesWindowFilter(_rec.ksLv, _rec.ksId, _rec.class) then
                        table.insert(_partyList, { name = _pmName, displayName = _pureName, mapID = _rec.ksId, level = _rec.ksLv, rating = _rec.rating or 0, classFile = _rec.class, zone = _partyZoneMap[_pureName] or "" })
                    end
                end
            end
            table.sort(_partyList, function(_a, _b) return _a.level > _b.level end)
        end
        -- 公会：从公共公会钥石缓存读取（收到回复动态追加）；forceClassMap 为打开/手动刷新时强制重建一次职业映射
        local _guildClassMap = buildGuildMemberMap(forceClassMap)
        local _cacheCount = 0
        local _shownCount = 0
        for _name, _data in pairs(mppe.GuildKeystoneCore.cache) do
            _cacheCount = _cacheCount + 1
            if _data and _data.mapID and _data.mapID > 0 and _data.level and _data.level > 0 then
                -- 过滤自己：缓存 key 可能是短名或 Name-Realm，统一提取纯名比较；name 为私信目标名（跨服带服务器），displayName 为显示用纯名
                local _pureName, _pmName = splitDisplayName(_name)
                -- 名册映射可能没有这个纯名（例如刚退会但缓存里还有记录）→ 取不到就当作无职业
                local _classInfo = _guildClassMap[_pureName]
                -- 过滤自己 + 筛选器（职业 / 层数区间 / 副本）
                if _pureName ~= _myName and passesWindowFilter(_data.level, _data.mapID, _classInfo and _classInfo.class) then
                    table.insert(_guildList, { name = _pmName, displayName = _pureName, mapID = _data.mapID, level = _data.level, rating = _data.rating or 0, classFile = _classInfo and _classInfo.class, zone = _classInfo and _classInfo.zone })
                    _shownCount = _shownCount + 1
                end
            end
        end
        -- _gksLog(string.format("[MPPE][GKS] guild cache=%d shown=%d", _cacheCount, _shownCount))
        -- 诊断：cache 比上次刷新减少（无 wipe 来源时不应发生）
        if _lastGuildCacheCount and _cacheCount < _lastGuildCacheCount then
            _gksLog(string.format("[MPPE][GKS] !! cache DECREASED prev=%d now=%d", _lastGuildCacheCount, _cacheCount))
        end
        _lastGuildCacheCount = _cacheCount
        table.sort(_guildList, function(_a, _b) return _a.level > _b.level end)
    end

    -- 组装带折叠分组标题的行列表（折叠的分组只保留标题行，不插入成员行）
    local _rows = {}
    -- 小队分组：仅当设置开启时才显示标题与成员行
    if MythicPlusPageExtensionDB.GuildAndPartyKS_ShowParty then
        table.insert(_rows, { type = "header", text = Translate["Party"], section = "party", count = #_partyList })
        if _sectionExpanded.party then
            for _, _data in ipairs(_partyList) do
                table.insert(_rows, { type = "member", data = _data })
            end
        end
        table.insert(_rows, { type = "header", text = Translate["Guild"], section = "guild", count = #_guildList })
    end
    
    if _sectionExpanded.guild then
        for _, _data in ipairs(_guildList) do
            table.insert(_rows, { type = "member", data = _data })
        end
    end

    updateScrollList(_rows)
    -- _gksLog(string.format("[MPPE][GKS] Refresh: mode=%s party=%d guild=%d cost=%.2fms", isTestMode and "TEST" or "REAL", #_partyList, #_guildList, debugprofilestop() - _start))
end

-- 公会钥石刷新防抖：首次 0.5s 快速刷新（首屏及时），后续请求合并为每 1.0s 一次（避免逐条回调触发全量刷新导致卡顿）
local _guildRefreshTimer = nil
local _refreshBurstCount = 0
local function scheduleRefresh()
    _refreshBurstCount = _refreshBurstCount + 1
    if _guildRefreshTimer then _guildRefreshTimer:Cancel() end
    local _delay = _firstRefreshFired and 1.0 or 0.5
    _guildRefreshTimer = C_Timer.After(_delay, function()
        _guildRefreshTimer = nil
        _firstRefreshFired = true
        _refreshBurstCount = 0
        if mppe_KeysFrame and mppe_KeysFrame:IsShown() then
            mppe.GuildAndPartyKS_Refresh(mppe_KeysFrame.isTestMode or false)
        end
    end)
end

-- 请求一次公会钥石信息（转公共模块：LibKeystone 的 GUILD 频道 + LibOpenRaid 的公会请求，带 30 秒节流）
function mppe.GuildAndPartyKS_RequestGuild()
    mppe.GuildKeystoneCore.RequestGuild()
end

-- ==================================================================
-- 订阅公共数据中枢：公会钥石数据到达 → 去抖刷新窗口
-- 必需：接收器已迁到 GuildKeystoneCore.lua，这里不订阅的话“边收边显示”就断了
--       （表现为：首次打开窗口空白，关掉重开才从缓存里读到数据）
-- 窗口没开时 scheduleRefresh 内部会跳过，不会产生无谓刷新
-- ==================================================================
mppe.GuildKeystoneCore.Subscribe(function()
    scheduleRefresh()
end)