local ADDON_NAME, mppe = ...

-- ==================================================================
-- 【公会钥石】公共筛选器行：4 个下拉（A 职业多选 / B 最低钥石层 / C 最高钥石层 / D 副本多选）
-- 由 GuildAndPartyKS.lua（公会钥石窗口）与 GuildMemberKeystone.lua（公会名单评分页）共用：
--   每个宿主 Create() 一个独立实例（筛选条件互不影响），宿主只需要：
--     ① 把 instance.bar 摆到想要的锚点（内部 4 个下拉已按固定宽度 / 间距排好，整组宽 = GuildFilterBar.WIDTH）
--     ② 在 onChange 回调里重建自己的列表
-- 常用接口（冒号调用）：
--   filter:Passes(level, mapID, classFile)   -- 筛选谓词
--   filter:HasActive() / filter:NeedsClass() / filter:Refresh() / filter:Reset() / filter:SetShown(bool)
-- 职责边界：本模块只管“公会”钥石筛选；队伍钥石属于 Party* 系列
-- ==================================================================
mppe.GuildKeystoneFilterBar = mppe.GuildKeystoneFilterBar or {}
local GuildFilterBar = mppe.GuildKeystoneFilterBar     -- 本模块自身的短别名（Guild = 公会）

local Translate = mppe.Translate
-- 下拉标题（走本地化表；Translate 的 __index 会回退到 key 本身，所以英文端也能显示）
local CLASS_LABEL = Translate["Class"]      -- A：职业
local DUNGEON_LABEL = Translate["Dun"]     -- D：副本

-- ---------- 尺寸 / 间距 / 选项范围（两个宿主共用同一套）----------
local FILTER_GAP = 5              -- 相邻筛选器之间的间距
local RANGE_GAP = 2               -- B/C 之间「-」连接符两侧的间距（比 FILTER_GAP 小，让「最低-最高」更像一个整体）
local DROPDOWN_HEIGHT = 25        -- 下拉按钮高度（模板原生 25）
local CLASS_WIDTH = 90            -- A：职业
local LEVEL_WIDTH = 45            -- B / C：最低、最高钥石层
local RANGE_SEPARATOR_WIDTH = 6   -- B/C 之间的「-」占位宽度
local MAP_WIDTH = 80              -- D：副本
-- 整组宽度：容器按此宽度创建，内部依次向右排（宿主只需摆容器，两者相等才是“整组对齐”）
local TOTAL_WIDTH = CLASS_WIDTH + FILTER_GAP + LEVEL_WIDTH + RANGE_GAP
    + RANGE_SEPARATOR_WIDTH + RANGE_GAP + LEVEL_WIDTH + FILTER_GAP + MAP_WIDTH

local LEVEL_RANGE_MAX = 29        -- B/C 下拉填充范围 0-29（30 个数字，刚好 3 列 × 10 行）
local LEVEL_GRID_COLUMNS = 3      -- B/C 的菜单列数
local LEVEL_MIN_DEFAULT = 0       -- B 默认值（0 = 不限制下限）
local LEVEL_MAX_DEFAULT = 29      -- C 默认值（29 = 不限制上限，即默认不按层数过滤）

-- 供宿主定位容器用（整组宽度 / 高度 / 相邻间距 / 默认值）
GuildFilterBar.WIDTH = TOTAL_WIDTH
GuildFilterBar.HEIGHT = DROPDOWN_HEIGHT
GuildFilterBar.GAP = FILTER_GAP
GuildFilterBar.LEVEL_RANGE_MAX = LEVEL_RANGE_MAX
GuildFilterBar.LEVEL_MIN_DEFAULT = LEVEL_MIN_DEFAULT
GuildFilterBar.LEVEL_MAX_DEFAULT = LEVEL_MAX_DEFAULT

-- 统计哈希表键数量（表很小，直接数）
local function countKeys(tbl)
    local _count = 0
    for _ in pairs(tbl) do _count = _count + 1 end
    return _count
end

-- 自建底贴图：替代模板自带的那张失效 Background（实测模板的 Background 在本环境整块不绘制）
local function refreshDropdownBackground(dropdown)
    local _background = dropdown.mppeOwnBackground
    if not _background then return end

    -- 状态图集（普通/悬停/按下/菜单打开/禁用）由模板的 GetBackgroundAtlas 给出
    local _atlas = dropdown.GetBackgroundAtlas and dropdown:GetBackgroundAtlas() or "common-dropdown-c-button"
    _background:SetAtlas(_atlas, TextureKitConstants.UseAtlasSize)
end

-- 给下拉装上自建底贴图（幂等，可重复调用）
local function setupDropdownBackground(dropdown)
    if dropdown.mppeOwnBackground then
        refreshDropdownBackground(dropdown)
        return
    end

    -- 只关掉模板那张失效的底，不动别的
    if dropdown.Background then dropdown.Background:SetAlpha(0) end

    local _background = dropdown:CreateTexture(nil, "BACKGROUND")
    _background:SetPoint("TOPLEFT", -7, 7)      -- 与模板锚点一致：四周各外扩 7px
    _background:SetPoint("BOTTOMRIGHT", 7, -7)
    dropdown.mppeOwnBackground = _background

    refreshDropdownBackground(dropdown)

    -- 按钮状态一变就换状态图集（模板原本由 OnButtonStateChanged 做这件事）
    dropdown:HookScript("OnEnter", refreshDropdownBackground)
    dropdown:HookScript("OnLeave", refreshDropdownBackground)
    dropdown:HookScript("OnMouseDown", refreshDropdownBackground)
    dropdown:HookScript("OnMouseUp", refreshDropdownBackground)
    dropdown:HookScript("OnShow", refreshDropdownBackground)
end

-- 创建一个筛选器行实例（opts: parent 必填 / namePrefix / onChange / levelMinDefault / levelMaxDefault）
function GuildFilterBar.Create(opts)
    if type(opts) ~= "table" or not opts.parent then return nil end

    local _parent = opts.parent
    local _namePrefix = opts.namePrefix or "MPPE_GuildKSFilter"
    local _onChange = opts.onChange

    -- ---------- 每个实例独立的状态 ----------
    local _classFilter = {}           -- [classFile] = true（空 = 不限）
    local _classFilterCount = 0
    local _mapFilter = {}             -- [mapID] = true（空 = 不限）
    local _mapFilterCount = 0
    local _levelMin = opts.levelMinDefault or LEVEL_MIN_DEFAULT
    local _levelMax = opts.levelMaxDefault or LEVEL_MAX_DEFAULT

    local _dropdownList = {}          -- 4 个下拉（顺序 A/B/C/D）
    local _instance = {}

    -- 容器：内部控件按固定宽度 / 间距排好，宿主只用摆这个容器的位置
    local _bar = CreateFrame("Frame", _namePrefix.."Bar", _parent)
    _bar:SetSize(TOTAL_WIDTH, DROPDOWN_HEIGHT)
    _instance.bar = _bar
    _instance.dropdowns = _dropdownList

    -- 刷新 4 个下拉的显示文本（SetSelectionText 只在 Update 时重算）
    function _instance:Refresh()
        for _index = 1, #_dropdownList do
            _dropdownList[_index]:Update()
        end
    end

    -- 条件变化：先刷新下拉文本，再通知宿主重建列表
    local function notifyChanged()
        _instance:Refresh()
        if _onChange then _onChange() end
    end

    -- 是否有任何筛选条件生效（全默认 = 不筛选）
    function _instance:HasActive()
        return _classFilterCount > 0 or _mapFilterCount > 0
            or _levelMin > LEVEL_MIN_DEFAULT or _levelMax < LEVEL_MAX_DEFAULT
    end

    -- 是否需要职业信息（为 true 时宿主才需要把行数据的职业转成 classFile，省掉无谓开销）
    function _instance:NeedsClass()
        return _classFilterCount > 0
    end

    -- 筛选谓词：返回 true 表示保留该成员（level = 钥石层数，mapID = 副本，classFile = 职业英文标识）
    function _instance:Passes(level, mapID, classFile)
        -- A 职业：一个都没勾选 = 不限制；职业取不到时按“不匹配”过滤掉
        if _classFilterCount > 0 and not _classFilter[classFile] then return false end

        -- B/C 层数区间
        local _level = level or 0
        if _level < _levelMin or _level > _levelMax then return false end

        -- D 副本：一个都没选 = 不限制
        if _mapFilterCount > 0 and not _mapFilter[mapID] then return false end

        return true
    end

    -- 清空所有筛选条件（并通知宿主重建列表）
    function _instance:Reset()
        wipe(_classFilter)
        wipe(_mapFilter)
        _classFilterCount = 0
        _mapFilterCount = 0
        _levelMin = opts.levelMinDefault or LEVEL_MIN_DEFAULT
        _levelMax = opts.levelMaxDefault or LEVEL_MAX_DEFAULT

        notifyChanged()
    end

    -- 整组显隐（宿主按页面条件调用）
    -- 注意：必须切容器本身 —— 容器里除了 4 个下拉，还有 B/C 之间的「-」连接符（它是容器的子帧），
    --       只逐个 SetShown 下拉会让这个「-」在非评分页单独留在屏幕上
    function _instance:SetShown(shown)
        _bar:SetShown(shown)
        for _index = 1, #_dropdownList do
            _dropdownList[_index]:SetShown(shown)
        end
    end

    -- 通用：新建下拉按钮；anchorFrame 为 nil 表示组内第一个（贴容器左端，其余依次向右排）
    local function createDropdown(name, width, anchorFrame, gap)
        local _gap = gap or FILTER_GAP
        local _dropdown = CreateFrame("DropdownButton", name, _bar, "WowStyle2DropdownTemplate")
        _dropdown:SetSize(width, DROPDOWN_HEIGHT)
        if anchorFrame then
            _dropdown:SetPoint("LEFT", anchorFrame, "RIGHT", _gap, 0)
        else
            _dropdown:SetPoint("LEFT", _bar, "LEFT", 0, 0)
        end

        -- 自建底贴图（模板自带的 Background 在本环境会整块不绘制）
        setupDropdownBackground(_dropdown)
        -- 层级提高一档：避免被同一容器下其它子帧的底纹压住
        _dropdown:SetFrameLevel(_bar:GetFrameLevel() + 5)
        return _dropdown
    end

    -- 通用：「全部」子选项 —— 未全选时一键全选，已全选时一键清空（A 职业 / D 副本共用）
    -- options: 选项表；filterTable: 对应筛选表；syncCountFunc: 重算计数器
    local function addSelectAllOption(rootDescription, options, filterTable, syncCountFunc)
        -- 只数 options 里存在的键，避免脏数据干扰判断
        local function countSelected()
            local _count = 0
            for _index = 1, #options do
                if filterTable[options[_index].value] then _count = _count + 1 end
            end
            return _count
        end

        local function isAllSelected() return countSelected() >= #options end

        local function toggleAll()
            if isAllSelected() then
                wipe(filterTable)          -- 已全选 → 全部取消
            else
                for _index = 1, #options do
                    filterTable[options[_index].value] = true
                end
            end

            syncCountFunc()
            notifyChanged()
        end

        rootDescription:CreateCheckbox("全部", isAllSelected, toggleAll)
        rootDescription:CreateDivider()
    end

    -- 副本选项：每次打开菜单时现算（mppe.CurrentSeasonDungeon 未就绪时回退 C_ChallengeMode.GetMapTable）
    local function buildMapOptions()
        local _mapIDs = mppe.CurrentSeasonDungeon
        if not _mapIDs or #_mapIDs == 0 then
            -- 注意：GetMapTable 返回的就是数组（不是多返回值），不要用 {} 再包一层
            _mapIDs = C_ChallengeMode.GetMapTable() or {}
        end

        local _options, _seen = {}, {}
        for _index = 1, #_mapIDs do
            local _mapID = _mapIDs[_index]
            if type(_mapID) == "number" and _mapID > 0 and not _seen[_mapID] then
                _seen[_mapID] = true
                _options[#_options + 1] = { value = _mapID, text = mppe.GuildKeystoneCore.DungeonFullName(_mapID) }
            end
        end
        return _options
    end

    -- ---------- A：职业（多选，填充全部职业；筛选键用职业英文标识 classFile）----------
    local _classOptions = {}
    for _classIndex = 1, GetNumClasses() do
        local _className, _classFile = GetClassInfo(_classIndex)
        if _classFile and _className then
            local _color = RAID_CLASS_COLORS and RAID_CLASS_COLORS[_classFile]
            _classOptions[#_classOptions + 1] = {
                value = _classFile,
                text = _color and _color:WrapTextInColorCode(_className) or _className,
            }
        end
    end

    local _classDropdown = createDropdown(_namePrefix.."_Class", CLASS_WIDTH)
    _classDropdown:SetDefaultText(CLASS_LABEL)
    _classDropdown:SetSelectionText(function()
        return _classFilterCount > 0 and string.format("%s(%d)", CLASS_LABEL, _classFilterCount) or CLASS_LABEL
    end)
    _classDropdown:SetupMenu(function(dropdown, rootDescription)
        -- 单列：职业 13 项 +「全部」共 14 项，用 2 列会让「全部」和一个职业同行，观感差
        rootDescription:SetGridMode(MenuConstants.VerticalGridDirection, 1)

        -- 「全部」：未全选一键全选，已全选一键清空
        addSelectAllOption(rootDescription, _classOptions, _classFilter, function() _classFilterCount = countKeys(_classFilter) end)
        for _index = 1, #_classOptions do
            local _option = _classOptions[_index]
            local function isChecked() return _classFilter[_option.value] == true end
            local function setChecked(data)
                if _classFilter[data.value] then
                    _classFilter[data.value] = nil
                else
                    _classFilter[data.value] = true
                end
                _classFilterCount = countKeys(_classFilter)
                notifyChanged()
            end
            rootDescription:CreateCheckbox(_option.text, isChecked, setChecked, _option)
        end
    end)

    -- ---------- B：最低钥石层数（0-29，与 C 联动；按钮直接显示数字）----------
    local _levelOptions = {}
    for _level = 0, LEVEL_RANGE_MAX do
        _levelOptions[#_levelOptions + 1] = { value = _level, text = tostring(_level) }
    end

    local _levelMinDropdown = createDropdown(_namePrefix.."_LevelMin", LEVEL_WIDTH, _classDropdown)
    _levelMinDropdown:SetDefaultText(tostring(_levelMin))
    _levelMinDropdown:SetSelectionText(function() return tostring(_levelMin) end)
    _levelMinDropdown:SetupMenu(function(dropdown, rootDescription)
        -- 3 列 × 10 行（VerticalGridDirection 是列优先：先向下填满一列再换列）
        rootDescription:SetGridMode(MenuConstants.VerticalGridDirection, LEVEL_GRID_COLUMNS)
        for _index = 1, #_levelOptions do
            local _option = _levelOptions[_index]
            local function isSelected(data) return _levelMin == data.value end
            local function setSelected(data)
                _levelMin = data.value
                -- 联动：下限高于上限时把上限顶上去
                if _levelMin > _levelMax then _levelMax = _levelMin end
                notifyChanged()
            end
            rootDescription:CreateHighlightRadio(_option.text, isSelected, setSelected, _option)
        end
    end)

    -- B/C 之间的区间连接符「-」：跟在 B 右侧，表示 B 是最小值、C 是最大值
    local _rangeSeparator = CreateFrame("Frame", nil, _bar)
    _rangeSeparator:SetSize(RANGE_SEPARATOR_WIDTH, DROPDOWN_HEIGHT)
    _rangeSeparator:SetPoint("LEFT", _levelMinDropdown, "RIGHT", RANGE_GAP, 0)

    local _rangeText = _rangeSeparator:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    _rangeText:SetPoint("CENTER")
    _rangeText:SetText("-")

    -- ---------- C：最高钥石层数（0-29，与 B 联动；按钮直接显示数字）----------
    local _levelMaxDropdown = createDropdown(_namePrefix.."_LevelMax", LEVEL_WIDTH, _rangeSeparator, RANGE_GAP)
    _levelMaxDropdown:SetDefaultText(tostring(_levelMax))
    _levelMaxDropdown:SetSelectionText(function() return tostring(_levelMax) end)
    _levelMaxDropdown:SetupMenu(function(dropdown, rootDescription)
        -- 3 列 × 10 行（与 B 一致，保证 0-9 / 10-19 / 20-29 整齐排列）
        rootDescription:SetGridMode(MenuConstants.VerticalGridDirection, LEVEL_GRID_COLUMNS)
        for _index = 1, #_levelOptions do
            local _option = _levelOptions[_index]
            local function isSelected(data) return _levelMax == data.value end
            local function setSelected(data)
                _levelMax = data.value
                -- 联动：上限低于下限时把下限拉上来
                if _levelMax < _levelMin then _levelMin = _levelMax end
                notifyChanged()
            end
            rootDescription:CreateHighlightRadio(_option.text, isSelected, setSelected, _option)
        end
    end)

    -- ---------- D：副本（多选，完整副本名）----------
    local _mapDropdown = createDropdown(_namePrefix.."_Map", MAP_WIDTH, _levelMaxDropdown)
    _mapDropdown:SetDefaultText(DUNGEON_LABEL)
    _mapDropdown:SetSelectionText(function()
        return _mapFilterCount > 0 and string.format("%s(%d)", DUNGEON_LABEL, _mapFilterCount) or DUNGEON_LABEL
    end)
    _mapDropdown:SetupMenu(function(dropdown, rootDescription)
        rootDescription:SetGridMode(MenuConstants.VerticalGridDirection)

        local _mapOptions = buildMapOptions()   -- 打开菜单时现算，保证拿到当前赛季副本

        -- 「全部」：未全选一键全选，已全选一键清空
        addSelectAllOption(rootDescription, _mapOptions, _mapFilter, function() _mapFilterCount = countKeys(_mapFilter) end)
        for _index = 1, #_mapOptions do
            local _option = _mapOptions[_index]
            local function isChecked() return _mapFilter[_option.value] == true end
            local function setChecked(data)
                if _mapFilter[data.value] then
                    _mapFilter[data.value] = nil
                else
                    _mapFilter[data.value] = true
                end
                _mapFilterCount = countKeys(_mapFilter)
                notifyChanged()
            end
            rootDescription:CreateCheckbox(_option.text, isChecked, setChecked, _option)
        end
    end)

    -- 顺序 A / B / C / D（组内从左到右，整组由宿主摆放容器位置）
    _dropdownList[1] = _classDropdown
    _dropdownList[2] = _levelMinDropdown
    _dropdownList[3] = _levelMaxDropdown
    _dropdownList[4] = _mapDropdown

    _instance:Refresh()

    -- 延迟再刷新一次自建底：错开加载瞬间（图集资源 / 按钮状态就绪后再贴一次）
    C_Timer.After(0, function()
        for _index = 1, #_dropdownList do
            refreshDropdownBackground(_dropdownList[_index])
        end
    end)

    return _instance
end
