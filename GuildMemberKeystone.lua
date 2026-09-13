local ADDON_NAME, mppe = ...
local Translate = mppe.Translate

-- 公会名单「史诗钥石评分」页：第 6 列（备注）懒更新为该成员的钥石信息，第 7 列（评分）重新上色
-- 数据与筛选控件来自公共模块 GuildKeystoneCore.lua / GuildKeystoneFilterBar.lua；本页只处理“公会”钥石

-- 功能开关：设置项 MythicPlusPageExtensionDB.GuildMemberKeystone_Show（支持热加载 / 热卸载）
-- hooksecurefunc 装上后无法卸载，所以“卸载”= 所有 hook 入口先查 _installed 空转
local _installed = false        -- 运行时开关：功能当前是否生效
local _hooksInstalled = false   -- hook / 控件 / 订阅是否已装好（一次性）

local TARGET_GUILD_COLUMN_INDEX = 5   -- 附加列：史诗钥石评分（第 5 个附加列 = DUNGEON_SCORE）
local NOTE_COLUMN_INDEX = 6           -- 第 6 列 = 备注（行元素 Note / 表头 ID = 6）
local HEADER_TEXT = Translate["Keystone"]            -- 备注列的表头标题
local EMPTY_TEXT = "-"                -- 无钥石数据时的占位
local SCORE_COLOR_STYLE = "raiderio"  -- 分数染色风格（可改 "highestlv"）
local SORT_DEBOUNCE_FIRST = 0.3       -- 首次重排延迟（秒）：进页首屏尽快有序
local SORT_DEBOUNCE_NEXT = 0.6        -- 后续重排延迟（秒）：把一轮回复的数据合并成一次重排
local SORT_MAX_WAIT = 2.0             -- 一轮数据的最长等待（秒）：防止持续到达把重排无限推迟

-- 数据与工具函数均由公共模块 mppe.GuildKeystoneCore（GuildKeystoneCore.lua）提供
local _refreshQueued = false   -- 同一批数据只排一次可见行刷新
local _fullRefreshQueued = false -- 同一批筛选变化只排一次“整行重刷”
local _needFullRowRefresh = false -- 刚改过列表内容 → 下一次可见范围变化时整行重刷
local _sortTimer = nil         -- 待触发的去抖重排定时器
local _sortBurstStart = nil    -- 本轮数据到达的起始时间（配合 SORT_MAX_WAIT）
local _sortFirstFired = false  -- 是否已触发过首次重排（决定用 FIRST 还是 NEXT 延迟）
local _sortLevelTable = {}     -- 复用表：[memberInfo] = 钥石等级（排序前预计算，比较时只查表）
local _orderScratch = {}       -- 复用表：重排前的旧顺序（只存指针，用于判断顺序是否变化）

local refreshVisibleRows       -- 前向声明（缓存写入函数需要调用）
local refreshVisibleRowsFull   -- 前向声明（筛选变化后整行重刷需要调用）
local refreshVisibleRowsNow    -- 前向声明（立即刷新当前可见行）
local scheduleKeystoneSort     -- 前向声明（钥石缓存写入后触发去抖重排）

-- 是否停留在「名单」大页面（显示模式 = ROSTER）
-- 聊天页与名单页共用同一个 MemberList，判断页面只能看显示模式（子帧 IsShown 不可信）
local function isRosterPageShown()
    local _frame = CommunitiesFrame
    if not _frame or not _frame:IsShown() or not _frame.GetDisplayMode then return false end

    local _modes = COMMUNITIES_FRAME_DISPLAY_MODES
    if not _modes or not _modes.ROSTER then return false end

    return _frame:GetDisplayMode() == _modes.ROSTER
end

-- 是否正停留在「史诗钥石评分」附加列（名单页 + 附加列索引 = 评分列）
local function isGuildKSPageShown()
    if not isRosterPageShown() then return false end

    local _memberList = CommunitiesFrame.MemberList
    return _memberList ~= nil and _memberList:GetGuildColumnIndex() == TARGET_GUILD_COLUMN_INDEX
end

-- 生成某成员的钥石显示文本（0 分配：字符串已由公共模块按 mapID/level 长期缓存，这里只做两次查表）
-- 格式与钥石窗口一致：“|cffa335ee<等级><副本短名>|r”（列宽有限，用无空格的紧凑样式）
local function getKeystoneText(pureName)
    local _data = mppe.GuildKeystoneCore.Get(pureName)
    if not _data then return EMPTY_TEXT end

    return mppe.GuildKeystoneCore.KeystoneTextCompact(_data.mapID, _data.level) or EMPTY_TEXT
end

-- 取某成员的钥石数据（统一走公共缓存；无数据返回 nil）
local function getKeystoneData(memberInfo)
    local _pureName = memberInfo and mppe.GuildKeystoneCore.PureName(memberInfo.name)
    if not _pureName then return nil end

    return mppe.GuildKeystoneCore.Get(_pureName)
end

-- 取某成员的钥石等级（0 = 无数据，排序时排最后）
local function getKeystoneLevel(memberInfo)
    local _data = getKeystoneData(memberInfo)
    return (_data and _data.level) or 0
end

-- 写入单行的备注列（钥石文本）：行数据 O(1) 获取，不遍历任何表
local function updateNoteColumn(memberEntry)
    if memberEntry.guildColumnIndex ~= TARGET_GUILD_COLUMN_INDEX then return end

    local _fontString = memberEntry.Note
    if not _fontString then return end

    local _memberInfo = memberEntry:GetMemberInfo()
    local _pureName = _memberInfo and mppe.GuildKeystoneCore.PureName(_memberInfo.name)
    local _text = _pureName and getKeystoneText(_pureName) or EMPTY_TEXT

    -- 文本没变就不写（本页刷得很频繁，每次 SetText 都会白跑一遍排版）
    if _fontString:GetText() ~= _text then _fontString:SetText(_text) end
end

-- 第 7 列（附加列 = 史诗钥石评分）重新上色：只换颜色，数值取 Blizzard 自己用的 overallDungeonScore
-- 不要去解析 GuildInfo 上已有的文本：色码和数字都是十六进制字符，正则很容易把数字一起吃掉
local function updateScoreColumn(memberEntry)
    if memberEntry.guildColumnIndex ~= TARGET_GUILD_COLUMN_INDEX then return end

    local _fontString = memberEntry.GuildInfo
    if not _fontString then return end

    local _memberInfo = memberEntry:GetMemberInfo()
    local _score = _memberInfo and _memberInfo.overallDungeonScore
    if not _score or _score <= 0 then return end   -- 没评分时保持 Blizzard 显示的“-”

    -- 数值用 tostring 与 Blizzard 的显示保持一致（%d 对小数 / 大数会有差异）
    local _text = string.format("|c%s%s|r", mppe.GetColorByScore(_score, SCORE_COLOR_STYLE, true), tostring(_score))
    if _fontString:GetText() ~= _text then _fontString:SetText(_text) end
end

-- 行内两列的自定义内容：第 6 列（钥石文本）+ 第 7 列（评分重新上色）
-- 两处 hook 与各可见行刷新都调它，避免漏掉某一列
local function updateRowCustomColumns(memberEntry)
    if not _installed then return end

    updateNoteColumn(memberEntry)
    updateScoreColumn(memberEntry)
end

local _blizzardNoteHeaderText   -- Blizzard 的备注列表头原文（首次覆盖前记下，供热卸载还原）

-- 写入备注列表头；顺带记下 Blizzard 原文供热卸载还原（不能重跑 LayoutColumns：它必须传 columnIDs）
local function updateNoteHeader(columnDisplay)
    if not _installed then return end
    if not isGuildKSPageShown() then return end

    for _header in columnDisplay.columnHeaders:EnumerateActive() do
        if _header:GetID() == NOTE_COLUMN_INDEX then
            local _currentText = _header:GetText()
            -- 只在拿到“非我们写的”文字时记录，避免把 HEADER_TEXT 当原文存下来
            if _currentText and _currentText ~= "" and _currentText ~= HEADER_TEXT then
                _blizzardNoteHeaderText = _currentText
            end

            _header:SetText(HEADER_TEXT)
        end
    end
end

-- 按钥石等级排序（reverse = true 降序：等级高的在前；无数据按 0 处理，排最后）
-- 返回是否真的排过；先把每人等级预算进复用表，比较函数里只查表（否则每次比较都要查缓存）
local function sortMembersByKeystone(memberList, reverse)
    local _list = memberList.sortedMemberList
    if not _list or #_list < 2 then return false end

    wipe(_sortLevelTable)
    for _index = 1, #_list do
        local _memberInfo = _list[_index]
        _sortLevelTable[_memberInfo] = getKeystoneLevel(_memberInfo)
    end

    table.sort(_list, function(lhsMemberInfo, rhsMemberInfo)
        local _lhsLevel = _sortLevelTable[lhsMemberInfo] or 0
        local _rhsLevel = _sortLevelTable[rhsMemberInfo] or 0
        if _lhsLevel == _rhsLevel then
            -- 同等级按名字，保证顺序稳定（否则每次刷新行都会抖动）
            return strcmputf8i(lhsMemberInfo.name or "", rhsMemberInfo.name or "") < 0
        end

        if reverse then return _lhsLevel > _rhsLevel end
        return _lhsLevel < _rhsLevel
    end)

    wipe(_sortLevelTable)   -- 及时释放对 memberInfo 的引用
    return true
end

-- 检查列表是否已按钥石降序（O(n) 不分配）：进页时据此跳过没必要的整表重刷
-- 只比较层数（同级内的名字顺序无所谓）
local function isSortedByKeystoneDesc(memberList)
    local _list = memberList.sortedMemberList
    if not _list or #_list < 2 then return true end

    local _prevLevel = getKeystoneLevel(_list[1])
    for _index = 2, #_list do
        local _level = getKeystoneLevel(_list[_index])
        if _level > _prevLevel then return false end
        _prevLevel = _level
    end

    return true
end

-- 点击「钥石」列表头时改为按钥石等级排序
-- 注意：Blizzard 的约定是 reverseActiveColumnSort == true 表示“降序”，且首次点击就是 true
-- 调用方（列表头点击 / SortList）随后会自己调 RefreshListDisplay，所以这里只改顺序
local function onSortByColumn(memberList, columnIndex)
    if not _installed then return end
    if columnIndex ~= NOTE_COLUMN_INDEX then return end

    -- 只作用于名单页的评分页（聊天页共用同一个 MemberList，排序信号也会传到这里）
    if not isGuildKSPageShown() then return end

    sortMembersByKeystone(memberList, memberList.reverseActiveColumnSort)
end

-- 进入评分页时自动按钥石降序排一次（等级高的在前，无数据的 0 在后）
-- 把“当前排序列”指向钥石列并设为降序：之后数据刷新走 SortList 时也会继续按钥石排
local function autoSortKSPage(memberList)
    -- 聊天页共用同一个 MemberList，绝不能在这里改它的排序
    if not isGuildKSPageShown() then return end

    memberList.activeColumnSortIndex = NOTE_COLUMN_INDEX
    memberList.reverseActiveColumnSort = true

    if sortMembersByKeystone(memberList, true) then memberList:RefreshListDisplay() end
end

-- ==================================================================
-- 钥石数据到达后的重排（去抖）
-- 数据逐条到达，每条都重排会反复触发 table.sort + 列表重建 → 合并成一次：
-- 首次 0.3s 触发、后续重新计时 0.6s，一轮最长等 SORT_MAX_WAIT 秒。
-- ==================================================================

-- 取当前视口第一条对应的 memberId（重排后据此把视图滚回原处，减少跳动）
local function getTopVisibleMemberId(memberList)
    local _scrollBox = memberList.ScrollBox
    if not _scrollBox.GetDataIndexBegin or not _scrollBox.GetDataProvider then return nil end

    local _beginIndex = _scrollBox:GetDataIndexBegin()
    if not _beginIndex or _beginIndex < 1 then return nil end

    local _provider = _scrollBox:GetDataProvider()
    local _elementData = _provider and _provider.Find and _provider:Find(_beginIndex)
    local _memberInfo = _elementData and _elementData.memberInfo
    return _memberInfo and _memberInfo.memberId
end

-- 把列表滚到指定 memberId 那一行（找不到就什么也不做）
local function scrollListToMemberId(memberList, memberId)
    if not memberId then return end

    local _scrollBox = memberList.ScrollBox
    if not _scrollBox.ScrollToElementDataByPredicate then return end

    _scrollBox:ScrollToElementDataByPredicate(function(_elementData)
        local _memberInfo = _elementData and _elementData.memberInfo
        return _memberInfo ~= nil and _memberInfo.memberId == memberId
    end)
end

-- 按当前排序重排一次；顺序真的变了才重刷列表（省掉最贵的 provider 重建，也避免列表无谓跳动）
local function resortKeystoneList(memberList)
    if not _installed then return end
    if not memberList or not isGuildKSPageShown() then return end

    -- 只在“按钥石列排序”时才需要重排：按名字 / 等级等其它列排时，钥石数据变化不影响顺序
    if memberList.activeColumnSortIndex ~= NOTE_COLUMN_INDEX then return end

    local _list = memberList.sortedMemberList
    if not _list or #_list < 2 then return end

    -- ① 备份旧顺序（只存指针，O(n)）
    wipe(_orderScratch)
    for _index = 1, #_list do _orderScratch[_index] = _list[_index] end

    -- ② 就地重排
    sortMembersByKeystone(memberList, memberList.reverseActiveColumnSort)

    -- ③ 顺序没变就直接结束
    local _changed = false
    for _index = 1, #_list do
        if _orderScratch[_index] ~= _list[_index] then
            _changed = true
            break
        end
    end
    wipe(_orderScratch)
    if not _changed then return end

    -- ④ 顺序变了：记住视口首行 → 重刷列表 → 滚回那一行
    local _topMemberId = getTopVisibleMemberId(memberList)
    memberList:RefreshListDisplay()
    scrollListToMemberId(memberList, _topMemberId)

    -- ⑤ 重刷一次可见行内容兜底（行重新绑数据，各列 / 钥石文本需要重填）
    refreshVisibleRowsNow()
end

-- 请求一次去抖重排（钥石数据到达时调用）
scheduleKeystoneSort = function()
    if not _installed then return end

    local _memberList = CommunitiesFrame and CommunitiesFrame.MemberList
    if not _memberList then return end

    -- 不在评分页 / 当前不是按钥石列排序 → 不用重排，也不用起定时器
    if not isGuildKSPageShown() then return end
    if _memberList.activeColumnSortIndex ~= NOTE_COLUMN_INDEX then return end

    local _now = GetTime()
    if not _sortBurstStart then _sortBurstStart = _now end

    -- 这一轮已经等够 SORT_MAX_WAIT：不再推迟，让已排队的定时器触发
    if _now - _sortBurstStart >= SORT_MAX_WAIT then return end

    if _sortTimer then _sortTimer:Cancel() end
    _sortTimer = C_Timer.After(_sortFirstFired and SORT_DEBOUNCE_NEXT or SORT_DEBOUNCE_FIRST, function()
        _sortTimer = nil
        _sortBurstStart = nil
        _sortFirstFired = true
        resortKeystoneList(CommunitiesFrame and CommunitiesFrame.MemberList)
    end)
end

-- ==================================================================
-- 列表筛选：改写 memberList.sortedMemberList（Blizzard 渲染的就是这张表）
-- 4 个筛选器（职业 / 最低层 / 最高层 / 副本）由公共模块 mppe.GuildKeystoneFilterBar 创建，
-- 本文件只负责把 memberInfo 翻译成（层数 / 副本 / 职业）再问筛选器。
-- ==================================================================
local _filter = nil               -- 公共筛选器实例（installCommunitiesHooks 里创建）
local _filtering = false          -- 防重入（重建列表时用）

-- 是否有任何筛选条件生效（全默认 = 不筛选）
local function hasActiveFilter()
    return _filter ~= nil and _filter:HasActive()
end

-- 筛选谓词：返回 true 表示保留该成员（成员信息 → 层数 / 副本 / 职业英文标识 后交给公共筛选器）
local function passesMemberFilter(memberInfo)
    if not _filter then return true end

    local _data = getKeystoneData(memberInfo)
    return _filter:Passes((_data and _data.level) or 0, _data and _data.mapID, mppe.GuildKeystoneCore.ClassFileByID(memberInfo.classID))
end

-- 重建可视列表：复现 Blizzard 的基础列表（是否含离线）+ 套谓词，再交给 SortList 排序与刷新
-- ignoreFilters = true 时只还原完整列表、不动筛选条件（离开评分页时用，保留记忆）
-- skipRowRefresh = true 时不再排队刷行（离开名单页时用：列表马上会被 Blizzard 重建）
local function applyMemberFilter(memberList, ignoreFilters, skipRowRefresh)
    if not memberList or not memberList.allMemberList then return end

    -- ① 基础列表：与 Blizzard 的 UpdateMemberList 保持一致
    local _base = memberList.allMemberList
    if not memberList:ShouldShowOfflinePlayers() then _base = CommunitiesUtil.GetOnlineMembers(_base) end

    -- ② 套谓词（纯内存循环，不调任何名单 API）；ignoreFilters 为 true 时跳过
    local _view = _base
    if not ignoreFilters and hasActiveFilter() then
        _view = {}
        for _index, _info in ipairs(_base) do
            if passesMemberFilter(_info) then table.insert(_view, _info) end
        end
    end

    memberList.sortedMemberList = _view
    memberList.sortedMemberLookup = CommunitiesUtil.GetMemberInfoLookup(_view)
    memberList.mppeGuildKSView = _view   -- 标记：用于判断 Blizzard 是否已用自己那份列表重建过

    memberList:SortList()            -- 排序（含钥石排序 hook）+ RefreshListDisplay

    if skipRowRefresh then return end

    -- 列表被“缩/放”之后，复用的行不会自动重填各列（会表现为钥石/评分空白）。
    -- 双保险：① 标记“下一轮可见范围变化时整行重刷”（时序天然正确）
    --         ② 再延后一帧主动刷一次（防止 ScrollBox 没有触发范围变化）
    _needFullRowRefresh = true
    refreshVisibleRowsFull()
end

local _rememberKSPage = false     -- 上次是否停在评分页（供切回名单页 / 重开窗口时恢复）

-- 4 个筛选下拉的显隐：只在「名单页的评分页」显示
-- （控件挂在 CommunitiesFrame 下，不跟着隐藏就会浮在聊天页等其它页面上）
local function refreshFilterVisibility()
    if _filter then _filter:SetShown(isGuildKSPageShown()) end
end

-- 把列表还原成完整列表（筛选条件保留，下次进页继续生效）
-- 只有真的套过筛选才重建：没有筛选时当前列表本来就是 Blizzard 那份（我们只是排了序）
local function releaseFilteredView(memberList)
    if not memberList then return end

    local _wasFiltered = hasActiveFilter()
    memberList.mppeGuildKSView = nil

    if _wasFiltered then applyMemberFilter(memberList, true, true) end
end

-- 离开评分页（切到其它附加列 / 聊天页 / 离开名单页）：清掉钥石排序 + 还原完整列表
local function leaveKSPage(memberList)
    if not memberList then return end

    -- 排序已被 Blizzard 改成别的列时不要复位，否则白多一次整表重刷
    if memberList.activeColumnSortIndex == NOTE_COLUMN_INDEX then memberList:ResetColumnSort() end

    if memberList.mppeGuildKSView then releaseFilteredView(memberList) end
end

-- 清空所有筛选条件并恢复完整列表（手动重置：/run mppe.GuildKSView_ResetFilter()）
-- 注意：离开评分页 / 关闭窗口不会再自动清空，条件会一直保留到本会话结束或手动重置
function mppe.GuildKSView_ResetFilter()
    if not _installed then return end   -- 功能未启用：什么都不做

    if _filter then _filter:Reset() end

    local _memberList = CommunitiesFrame and CommunitiesFrame.MemberList
    if _memberList and isGuildKSPageShown() then applyMemberFilter(_memberList) end
end

-- 创建 4 个筛选下拉（控件由公共模块提供；写法与 Settings.lua 的 BuildComboBoxV2 同源）
local function createFilterDropdowns(communitiesFrame)
    if _filter then return end

    _filter = mppe.GuildKeystoneFilterBar.Create{
        parent = communitiesFrame,
        namePrefix = "MPPE_GuildKSRosterFilter",
        onChange = function()
            -- 条件变化：用现有数据重建可见列表（数据不用重新请求）
            local _memberList = CommunitiesFrame and CommunitiesFrame.MemberList
            if _memberList and isGuildKSPageShown() then applyMemberFilter(_memberList) end
        end,
    }

    -- 层级提高一档：避免被同一容器下其它子帧的内衬/底纹压住
    _filter.bar:SetFrameLevel(communitiesFrame:GetFrameLevel() + 10)

    -- 整组右端贴在「页面下拉（GuildMemberListDropdown）」左侧，跟着它一起显隐
    local _anchor = communitiesFrame.GuildMemberListDropdown
    if _anchor then
        _filter.bar:SetPoint("RIGHT", _anchor, "LEFT", -mppe.GuildKeystoneFilterBar.GAP, 0)
    else
        -- 兜底：拿不到页面下拉时锚在窗体右上角下方（避免跑到屏幕中间）
        _filter.bar:SetPoint("TOPRIGHT", communitiesFrame, "TOPRIGHT", -mppe.GuildKeystoneFilterBar.GAP, -(mppe.GuildKeystoneFilterBar.HEIGHT * 2))
    end
end

refreshVisibleRows = function()
    if not _installed then return end
    if _refreshQueued then return end
    _refreshQueued = true

    C_Timer.After(0, function()
        _refreshQueued = false
        if not isGuildKSPageShown() then return end

        CommunitiesFrame.MemberList.ScrollBox:ForEachFrame(updateRowCustomColumns)
    end)
end

-- 立即刷新当前所有可见行：把行“拨正”到当前页面状态，再重填内容。
-- 只调 RefreshExpandedColumns 会空跑（它和 updateNoteColumn 都有早退条件），
-- 所以先清掉再重设 guildColumnIndex、补展开态，最后重刷各列 + 写钥石文本。
refreshVisibleRowsNow = function()
    if not _installed then return end

    local _frame = CommunitiesFrame
    if not _frame or not isGuildKSPageShown() then return end

    -- 双保险：聊天页等紧凑显示下绝不能把行撑成名单样式（两页共用同一份 MemberList）
    local _memberList = _frame.MemberList
    if _memberList.expandedDisplay ~= true then return end

    local _full = _needFullRowRefresh
    _needFullRowRefresh = false

    _memberList.ScrollBox:ForEachFrame(function(entry)
        if entry.GetMemberInfo and entry:GetMemberInfo() == nil then return end   -- 还没绑数据的行，等下一轮

        -- ① 拨正“当前附加列索引”：先清成 nil，避免 Blizzard 的 SetGuildColumnIndex 内部早退
        if entry.guildColumnIndex ~= TARGET_GUILD_COLUMN_INDEX and entry.SetGuildColumnIndex then
            entry.guildColumnIndex = nil
            entry:SetGuildColumnIndex(TARGET_GUILD_COLUMN_INDEX)
        end

        -- ② 拨正展开态：未展开时各列不会显示、RefreshExpandedColumns 也会早退
        if entry.expanded ~= true and entry.SetExpanded then entry:SetExpanded(true) end

        -- ③ 兜底整行重刷（各列 + 附加列），再补一次钥石/评分文本
        if _full and entry.RefreshExpandedColumns then entry:RefreshExpandedColumns() end
        updateRowCustomColumns(entry)
    end)
end

-- 请求一次（延后一帧的）可见行刷新；与 ScrollBox 的 OnDataRangeChanged 一起兜底
refreshVisibleRowsFull = function()
    if not _installed then return end
    if _fullRefreshQueued then return end
    _fullRefreshQueued = true

    C_Timer.After(0, function()
        _fullRefreshQueued = false
        refreshVisibleRowsNow()
    end)
end

-- 请求一次公会钥石数据（转公共模块，自带 30 秒节流）
local function requestGuildKeystones()
    mppe.GuildKeystoneCore.RequestGuild()
end

-- ==================================================================
-- 成员行 tooltip：追加「分数 / 钥石」两行
-- 暴雪的行 OnEnter 只在“有文字被截断”时才弹 tooltip，所以这里 post-hook：
-- 已弹 → 追加两行；没弹 → 我们自己补一个（TOOLTIP_SUPPLEMENT）
-- ==================================================================
local TOOLTIP_SUPPLEMENT = true    -- true = 暴雪没弹 tooltip 时我们自己补一个

-- 追加「分数 / 钥石」两行（先插一个空行隔开原生信息；分数按 raiderio 色染色，与 GuildAndPartyKS 一致）
local function appendKeystoneTooltipLines(memberInfo)
    GameTooltip_AddBlankLineToTooltip(GameTooltip)

    local _data = getKeystoneData(memberInfo)
    local _rating = _data and _data.rating

    -- 钥石缓存没有 rating 时（对方没带钥石），退回名单里的官方评分
    if not _rating or _rating <= 0 then
        _rating = memberInfo and memberInfo.overallDungeonScore
    end

    local _level = _data and _data.level
    local _mapID = _data and _data.mapID

    -- tooltip 内始终用副本原名（与 GuildAndPartyKS 一致，不用短名）
    local _dungeonName = Translate["UNKNOWN"] or "?"
    if _mapID and _mapID > 0 then
        _dungeonName = C_ChallengeMode.GetMapUIInfo(_mapID) or _dungeonName
    end

    local _keystoneText = EMPTY_TEXT
    if _level and _level > 0 then _keystoneText = string.format("%d %s", _level, _dungeonName) end

    GameTooltip:AddLine(string.format("%s: |c%s%s|r", Translate["Score"],
        mppe.GetColorByScore(_rating or 0, SCORE_COLOR_STYLE, true), _rating or EMPTY_TEXT))
    GameTooltip:AddLine(string.format("%s: |c%s%s|r", Translate["Keystone"], "FFFFFFFF", _keystoneText))
end

-- 成员行 OnEnter 之后：把「分数 / 钥石」追加到 tooltip
local function onMemberEntryEnter(memberEntry)
    if not _installed then return end
    if not isGuildKSPageShown() then return end
    if memberEntry.isInvitation then return end

    local _memberInfo = memberEntry:GetMemberInfo()
    if not _memberInfo then return end

    -- 情况 A：暴雪已经弹了 tooltip（本行有文字被截断）→ 直接追加两行
    if GameTooltip:GetOwner() == memberEntry then
        appendKeystoneTooltipLines(_memberInfo)
        GameTooltip:Show()
        return
    end

    -- 情况 B：暴雪没弹（本行文字都没被截断）→ 自己补一个精简版（名字 + 空行 + 两行）
    if not TOOLTIP_SUPPLEMENT then return end

    local _classInfo = _memberInfo.classID and C_CreatureInfo.GetClassInfo(_memberInfo.classID)
    local _classColor = _classInfo and RAID_CLASS_COLORS and RAID_CLASS_COLORS[_classInfo.classFile]
    local _nameColor = _classColor and _classColor:GenerateHexColor() or "FFCCCCCC"

    GameTooltip:SetOwner(memberEntry, "ANCHOR_RIGHT")
    -- 名字用职业色；显式补 r/g/b 是绕开静态检查器对 SetText 签名的一处误报
    GameTooltip:SetText(string.format("|c%s%s|r", _nameColor, _memberInfo.name or ""), 1, 1, 1)
    appendKeystoneTooltipLines(_memberInfo)
    GameTooltip:Show()
end

local _reconcileQueued = false    -- 同一帧内的多次信号只校正一次

-- 页面状态统一校正（页面切换 / 下拉显隐 / 窗口开关都调它）：延后一帧且幂等，
-- 避开 Blizzard 在 SetDisplayMode、下拉 OnShow 里的附加列重置与列表重建。
local function reconcilePageState()
    if not _installed then return end
    if _reconcileQueued then return end
    _reconcileQueued = true

    C_Timer.After(0, function()
        _reconcileQueued = false
        if not _installed then return end   -- 延后一帧期间可能已被热卸载

        local _frame = CommunitiesFrame
        local _memberList = _frame and _frame.MemberList
        if not _memberList then return end

        if not isRosterPageShown() then
            -- 离开名单页：记住子页选项 + 取消筛选
            -- （不还原成完整列表的话，聊天页会继续用被筛过的列表，表现为成员列表内容缺失）
            _rememberKSPage = _memberList:GetGuildColumnIndex() == TARGET_GUILD_COLUMN_INDEX
            leaveKSPage(_memberList)

            refreshFilterVisibility()
            return
        end

        if _rememberKSPage and _memberList:GetGuildColumnIndex() ~= TARGET_GUILD_COLUMN_INDEX then
            -- 恢复上次停留的子页（含评分页）；SetGuildColumnIndex 会触发 ④ hook，
            -- 于是钥石排序与筛选条件也会一起恢复
            _memberList:SetGuildColumnIndex(TARGET_GUILD_COLUMN_INDEX)
        elseif hasActiveFilter() and _memberList.sortedMemberList ~= _memberList.mppeGuildKSView then
            -- 子页没变（还在评分页），但列表可能刚被 Blizzard 重建过 → 补套一次筛选
            applyMemberFilter(_memberList)
        end

        -- 页面下拉的文字是由菜单选项的选中状态推出来的，外部改了状态要重建一次菜单，
        -- 否则会表现为“要手动点一下下拉才刷新”（Blizzard 菜单指南指定的做法）
        local _guildDropdown = _frame.GuildMemberListDropdown
        if _guildDropdown and _guildDropdown.GenerateMenu then _guildDropdown:GenerateMenu() end

        refreshFilterVisibility()
    end)
end

-- 安装公会名单相关 hook（Blizzard_Communities 随启动加载，本插件执行时已就绪）
local function installCommunitiesHooks()
    if not CommunitiesFrame or not CommunitiesFrame.MemberList then return end
    if not CommunitiesMemberListEntryMixin then return end

    -- ① 行初始化 / 滚动复用 / 排序后重新填充（只处理当前可见行）
    hooksecurefunc(CommunitiesMemberListEntryMixin, "SetMember", updateRowCustomColumns)

    -- ② 展开收起 / 切换附加列后各列会被重写
    hooksecurefunc(CommunitiesMemberListEntryMixin, "RefreshExpandedColumns", updateRowCustomColumns)

    -- ③ 表头重排时改备注列表头
    local _columnDisplay = CommunitiesFrame.MemberList.ColumnDisplay
    if _columnDisplay and _columnDisplay.LayoutColumns then
        hooksecurefunc(_columnDisplay, "LayoutColumns", updateNoteHeader)
    end

    -- ④ 切到 / 离开评分页
    hooksecurefunc(CommunitiesFrame.MemberList, "SetGuildColumnIndex", function(memberList, guildColumnIndex)
        if not _installed then return end   -- 热卸载后空转

        local _onKSPage = guildColumnIndex == TARGET_GUILD_COLUMN_INDEX

        -- 4 个筛选下拉跟着“评分页”显示/隐藏
        refreshFilterVisibility()

        if not _onKSPage then
            leaveKSPage(memberList)
            return
        end

        requestGuildKeystones()

        -- 先把“当前排序列”指向钥石列并设为降序（后续重建/排序都会顺着我们的排序钩子走）
        memberList.activeColumnSortIndex = NOTE_COLUMN_INDEX
        memberList.reverseActiveColumnSort = true

        -- 进页：只有存在筛选条件才重建列表；否则 Blizzard 那份就是完整在线名单，排一次序即可
        if hasActiveFilter() then
            applyMemberFilter(memberList, true)

            -- 再延后一帧套一次记住的筛选条件（避免行在“过滤后的列表”状态下第一次被创建）
            C_Timer.After(0, function()
                if hasActiveFilter() then applyMemberFilter(memberList) end
            end)
        elseif isSortedByKeystoneDesc(memberList) then
            -- 已经是有序的（Blizzard 打开时的重建已走过我们的排序钩子）：不再整表重刷，只补行内容
            memberList.mppeGuildKSView = nil
            refreshVisibleRowsFull()
        else
            memberList.mppeGuildKSView = nil   -- 当前列表不是“我们装的筛选视图”
            memberList:SortList()              -- 排序走钥石排序钩子 + RefreshListDisplay
            _needFullRowRefresh = true
            refreshVisibleRowsFull()
        end
    end)

    -- ⑤ 点击「钥石」列表头 → 按钥石等级排序（替代 Blizzard 对备注的排序）
    hooksecurefunc(CommunitiesFrame.MemberList, "SortByColumnIndex", onSortByColumn)

    -- ⑥ 窗口打开时：统一校正一次页面状态；关闭时记住页面
    CommunitiesFrame:HookScript("OnShow", function()
        if not _installed then return end   -- 热卸载后空转

        -- 在聊天页打开窗口时不会被强行切页：reconcilePageState 只在“名单页”才恢复子页
        reconcilePageState()

        if not isGuildKSPageShown() then return end

        requestGuildKeystones()
        autoSortKSPage(CommunitiesFrame.MemberList)
    end)
    CommunitiesFrame:HookScript("OnHide", function()
        if not _installed then return end   -- 热卸载后空转

        -- 记住“关闭时停在哪个子页”，供下次打开恢复（不能用 isGuildKSPageShown，此时窗口已隐藏）
        _rememberKSPage = CommunitiesFrame.MemberList:GetGuildColumnIndex() == TARGET_GUILD_COLUMN_INDEX
    end)

    -- ⑦ 筛选：Blizzard 用自己那份列表重建后，重新套一次谓词（带防重入 + 标记判断）
    local _memberList = CommunitiesFrame.MemberList
    hooksecurefunc(_memberList, "RefreshListDisplay", function(self)
        if not _installed then return end   -- 热卸载后空转
        if _filtering then return end
        if not isGuildKSPageShown() then return end   -- 只作用于名单页的评分页（聊天页也会走这里）
        if not hasActiveFilter() then return end
        if self.sortedMemberList == self.mppeGuildKSView then return end   -- 还是我们那份，跳过

        _filtering = true
        applyMemberFilter(self)
        _filtering = false
    end)

    -- ⑧ 4 个筛选下拉（A 职业 / B 最低层 / C 最高层 / D 副本），仅评分页显示
    createFilterDropdowns(CommunitiesFrame)
    refreshFilterVisibility()

    -- ⑨ 成员行 tooltip：追加「分数 / 钥石」两行（post-hook 暴雪的 OnEnter）
    hooksecurefunc(CommunitiesMemberListEntryMixin, "OnEnter", onMemberEntryEnter)

    -- ⑩ 页面切换统一校正（一律以显示模式判定：聊天页与名单页共用同一个 MemberList）
    --     下拉显隐也算一次信号（Blizzard 只在名单页显示它），用于兜底
    if CommunitiesFrame.GuildMemberListDropdown then
        CommunitiesFrame.GuildMemberListDropdown:HookScript("OnShow", reconcilePageState)
        CommunitiesFrame.GuildMemberListDropdown:HookScript("OnHide", reconcilePageState)
    end

    -- 切页信号：CommunitiesFrame 的 DisplayModeChanged 事件（此时各子帧切换已就位）
    -- 事件名先取出来判类型，绝不把 nil 丢给 RegisterCallback（会报错并中断本文件后续代码）
    local _displayModeEvent
    if type(CommunitiesFrameMixin) == "table" and type(CommunitiesFrameMixin.Event) == "table" then
        _displayModeEvent = CommunitiesFrameMixin.Event.DisplayModeChanged
    end

    if type(_displayModeEvent) == "string" and CommunitiesFrame.RegisterCallback then
        CommunitiesFrame:RegisterCallback(_displayModeEvent, reconcilePageState, nil)
    elseif type(_memberList.OnCommunitiesDisplayModeChanged) == "function" then
        -- 兜底：直接 hook MemberList 的实例方法（它就是上面那个事件在名单列表上的回调）
        hooksecurefunc(_memberList, "OnCommunitiesDisplayModeChanged", reconcilePageState)
    end

    -- ⑪ 可见行内容刷新：挂在 ScrollBox 的“可见数据范围变化”上（筛选 / 排序 / 滚动都会触发，
    -- 此刻行已绑好数据；用 C_Timer 主动刷反而会刷到“还没绑数据”的行）
    -- 事件名从 ScrollBoxListMixin.Event 取：BaseScrollBoxEvents 在插件环境是 nil
    local _dataRangeEvent
    if type(ScrollBoxListMixin) == "table" and type(ScrollBoxListMixin.Event) == "table" then
        _dataRangeEvent = ScrollBoxListMixin.Event.OnDataRangeChanged
    end

    if type(_dataRangeEvent) == "string" then
        _memberList.ScrollBox:RegisterCallback(_dataRangeEvent, refreshVisibleRowsNow)
    else
        print("|cffff5555MPPE|r 未找到 ScrollBox 的 OnDataRangeChanged 事件名，可见行刷新降级为被动刷新")
    end
end

-- ==================================================================
-- 安装（一次性）：hook / 筛选器控件 / 数据订阅
-- · WoW 的 hooksecurefunc 装上后无法卸载，所以钩子只装一次，热卸载靠 _installed 空转
-- · 首次启用时才真正挂钩子；若当时 Communities 还没就绪，下次启用（或 /reload）再试
-- ==================================================================
local function installGuildMemberKeystoneFeature()
    if _hooksInstalled then return end

    -- 前置条件：Blizzard 的 Communities 相关全局必须已就绪
    if not (CommunitiesFrame and CommunitiesFrame.MemberList and CommunitiesMemberListEntryMixin) then return end

    _hooksInstalled = true

    -- ① hook 与筛选器控件
    installCommunitiesHooks()

    -- ② 订阅公共数据中枢：钥石数据变化 → 刷一次可见行 + 排一次去抖重排
    --    （接收器由公共模块统一注册，与公会钥石窗口共用同一份缓存，窗口不开也能收）
    mppe.GuildKeystoneCore.Subscribe(function()
        refreshVisibleRows()
        scheduleKeystoneSort()
    end)
end

-- 还原备注列表头文本（热卸载时把我们写的“钥石”换回 Blizzard 自己的文字）
-- 不能调 columnDisplay:LayoutColumns()：它需要传 columnIDs，无参会直接报错
local function restoreNoteHeader()
    if not _blizzardNoteHeaderText then return end

    local _memberList = CommunitiesFrame and CommunitiesFrame.MemberList
    local _columnDisplay = _memberList and _memberList.ColumnDisplay
    if not (_columnDisplay and _columnDisplay.columnHeaders) then return end

    for _header in _columnDisplay.columnHeaders:EnumerateActive() do
        if _header:GetID() == NOTE_COLUMN_INDEX then _header:SetText(_blizzardNoteHeaderText) end
    end
end

-- ==================================================================
-- 热加载 / 热卸载：设置项勾选后立即生效（由 Settings.lua 的 item.onChange 调用）
--   enabled = true ：（首次）装好钩子/控件/订阅，并让功能生效
--   enabled = false：关掉开关（入口全部空转）+ 退出评分页态 + 隐藏控件 + 还原表头
-- ==================================================================
function mppe.GuildMemberKeystone_SetEnabled(enabled)
    enabled = enabled == true
    if enabled == _installed then return end

    local _memberList = CommunitiesFrame and CommunitiesFrame.MemberList

    if enabled then
        installGuildMemberKeystoneFeature()
        if not _hooksInstalled then
            print("|cffff5555MPPE|r 名单钥石列：Blizzard 名单模块尚未就绪，本次未启用（可用 /reload 兜底）")
            return
        end

        _installed = true   -- 必须在后面的排序/筛选之前置位，否则钩子回调会自己空转

        -- 正好停在评分页时：立刻补上排序与筛选
        if _memberList and isGuildKSPageShown() then
            requestGuildKeystones()
            autoSortKSPage(_memberList)

            if hasActiveFilter() then
                applyMemberFilter(_memberList)
            else
                refreshVisibleRowsFull()   -- 无筛选条件：至少把可见行的钥石/分数文本补上
            end
        end

        refreshFilterVisibility()
        return
    end

    -- 卸载：先关开关（让后续钩子回调空转），再还原页面与控件
    _installed = false

    if _memberList then
        leaveKSPage(_memberList)                     -- 清掉钥石排序 + 还原完整列表
        if _memberList.RefreshListDisplay then _memberList:RefreshListDisplay() end   -- 重刷行内容，去掉我们写的文本/染色
    end

    if _filter then _filter:SetShown(false) end
    restoreNoteHeader()
end

-- 加载时按设置项同步一次；SavedVariables 延迟初始化时由延后一帧的兜底再判一次
local function syncFeatureWithSetting()
    if not MythicPlusPageExtensionDB then return end

    mppe.GuildMemberKeystone_SetEnabled(MythicPlusPageExtensionDB.GuildMemberKeystone_Show == true)
end

syncFeatureWithSetting()
C_Timer.After(0, syncFeatureWithSetting)
