---@diagnostic disable: deprecated
-- =================================================================
-- Debug.lua
-- MPPE 调试工具（独立文件）
--   用法：/mppe debug 打开调试窗体（再按一次关闭）；/mppe debug 2 直接观察 2 号队友
--   功能1：PartyDB 数据树形查看器（可按数据结构层级展开/折叠，检查队友数据是否正常）
--   功能2：对指定队友执行一次 INSP 观察，列出各装备槽与装等明细（排查装等计算错误）
-- =================================================================
local ADDON_NAME, mppe = ...

-- 调试窗体尺寸常量
local FrameWidth = 540
local FrameHeight = 430
local RowHeight = 18
local NodeHeaderHeight = 20
local DebugScrollWidth = FrameWidth - 40

-- 装备槽位中文名（槽位索引 1-19；槽位4=衬衫，装等计算中跳过）
local DebugSlotNames = {
    [1] = "头部",   [2] = "颈部",   [3] = "肩部",   [4] = "衬衫",   [5] = "胸部",
    [6] = "腰部",   [7] = "腿部",   [8] = "脚部",   [9] = "腕部",   [10] = "手部",
    [11] = "戒指1", [12] = "戒指2", [13] = "饰品1", [14] = "饰品2", [15] = "背部",
    [16] = "主手",  [17] = "副手",  [18] = "远程",  [19] = "战袍",
}

-- 物品品质颜色（装备名染色）
local DebugQualityColors = {
    [0] = "ff9d9d9d", [1] = "ffffffff", [2] = "ff1eff00", [3] = "ff0070dd",
    [4] = "ffa335ee", [5] = "ffff8000", [6] = "ffe5cc80", [7] = "ffe6cc80",
}

-- PartyDB 记录预期字段（补全缺失字段用；缺失显示 "Null"）
local DbFieldList = {
    "name", "realm", "fullName", "NameRealm", "inParty",
    "class", "specId", "iLv",
    "iLvSrc", "iLvUpdated", "classSrc", "classUpdated", "specSrc", "specUpdated",
    "ksId", "ksLv", "rating", "ksSrc", "ksUpdated",
    "runs", "score", "bestSrc", "bestUpdated",
    "updated",
}

-- 调试模块状态
mppe.Debug = mppe.Debug or {}
mppe.Debug.selectedMember = nil   -- 下拉框选中的队友序号
mppe.Debug.inspectTarget = nil    -- 观察目标 { unit, guid, name, index }

-- 控件引用（懒初始化后填充）
local DebugFrame, DbPanel, InspPanel, AssetPanel, TabDB, TabInsp, TabAsset
local DbScrollFrame, DbScrollChild, InspScrollFrame, InspScrollChild, InspStatusText
local MemberDropdown
local AssetFilterInput                          -- 素材筛选输入框
local AssetScrollFrame, AssetScrollChild        -- 素材网格滚动区
local AssetStatusText                           -- 底部状态文本
local AssetAll = {}                             -- 全部 Atlas 名（首次构建时缓存）
local AssetList = {}                            -- 当前筛选后的 atlas 名数组
local AssetListCount = 0
local AssetCells = {}                           -- 网格单元格复用池（虚拟化）
local AssetCellSize = 72                        -- 单元格尺寸
local AssetCellPitch = 78                       -- 单元格间距（含边距）
local AssetFilter = ""                          -- 当前筛选关键字（小写）
local getAssetCell, renderAssetGrid, applyAssetFilter -- 前向声明（showPanel/getAssetCell 相互引用）
local FrameInitialized = false
local Inspecting = false
local InspectTimeout = nil

-- 树节点状态
local DbTreeRoot = nil       -- 根节点
local renderDbList           -- 前向声明（createHeaderRow 点击回调中引用）
-- 观察结果状态
local InspRows = {}          -- 当前观察结果行数据
local InspRowButtons = {}    -- 当前创建的结果行按钮

-- =================================================================
-- 通用小工具
-- =================================================================

-- 返回标量值显示用的颜色码
local function valueColor(value)
    if type(value) == "number" then return "ffd7ba7d" end
    if type(value) == "string" then return "ff7fff00" end
    if type(value) == "boolean" then return "ff69c4ff" end
    return "ffffffff"
end

-- 创建一行可点击的文本按钮（tooltipLink 非空时悬停显示物品提示，右键插入聊天框）
local function createTextRow(parent, yOffset, text, onClick, tooltipLink)
    local _row = CreateFrame("Button", nil, parent, "BackdropTemplate")
    _row:SetSize(parent:GetWidth() - 8, RowHeight)
    _row:SetPoint("TOPLEFT", parent, "TOPLEFT", 4, -yOffset)
    _row:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        bgColor = { 0, 0, 0, 0 },
        edgeColor = { 0, 0, 0, 0 },
    })
    if tooltipLink then
        _row:SetScript("OnEnter", function(self)
            self:SetBackdropColor(1, 1, 1, 0.10)
            if not GameTooltip:IsForbidden() then
                GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
                GameTooltip:SetHyperlink(tooltipLink)
                GameTooltip:Show()
            end
        end)
        _row:SetScript("OnLeave", function(self)
            self:SetBackdropColor(0, 0, 0, 0)
            if not GameTooltip:IsForbidden() then GameTooltip:Hide() end
        end)
    else
        _row:SetScript("OnEnter", function(self) self:SetBackdropColor(1, 1, 1, 0.06) end)
        _row:SetScript("OnLeave", function(self) self:SetBackdropColor(0, 0, 0, 0) end)
    end
    _row:SetScript("OnClick", function(self, button)
        if button == "RightButton" and tooltipLink and ChatEdit_InsertLink then
            ChatEdit_InsertLink(tooltipLink)
        elseif onClick then
            onClick(self, button)
        end
    end)
    local _text = _row:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    _text:SetPoint("LEFT", 4, 0)
    _text:SetJustifyH("LEFT")
    _text:SetText(text)
    _row.Text = _text
    return _row
end

-- =================================================================
-- 功能1：PartyDB 树形查看器
-- =================================================================

-- 递归构建树节点（visited 集合防止循环引用）
local function buildTree(key, value, depth, visited)
    local _node = {
        key = tostring(key),
        value = value,
        depth = depth,
        isLeaf = type(value) ~= "table",
        expanded = false,
        children = nil,
        cycle = false,
    }
    if type(value) == "table" then
        if visited[value] then
            _node.cycle = true
        else
            visited[value] = true
            _node.children = {}
            for _k, _v in pairs(value) do
                table.insert(_node.children, buildTree(_k, _v, depth + 1, visited))
            end
            visited[value] = nil  -- 允许同一引用出现在不同分支
            table.sort(_node.children, function(_a, _b)
                if type(_a.value) == "number" and type(_b.value) == "number" then
                    return _a.value < _b.value
                end
                return _a.key < _b.key
            end)
        end
    end
    return _node
end

-- 按固定字段清单重排并补全角色记录的子节点（缺失字段补 "Null" 叶子）
local function fillMissingFields(recordNode)
    if not recordNode or not recordNode.children then return end
    local _byKey = {}
    for _, _child in ipairs(recordNode.children) do
        _byKey[_child.key] = _child
    end
    local _newChildren = {}
    for _, _field in ipairs(DbFieldList) do
        local _child = _byKey[_field]
        if _child then
            table.insert(_newChildren, _child)
        else
            table.insert(_newChildren, {
                key = _field, value = nil, depth = recordNode.depth + 1,
                isLeaf = true, expanded = false, children = nil, cycle = false, isNull = true,
            })
        end
    end
    -- 追加清单外出现的字段（保证不丢失新增字段）
    for _, _child in ipairs(recordNode.children) do
        local _bFound = false
        for _, _field in ipairs(DbFieldList) do
            if _field == _child.key then _bFound = true break end
        end
        if not _bFound then table.insert(_newChildren, _child) end
    end
    recordNode.children = _newChildren
end

-- 生成树节点行文本（叶子显示值，容器显示子项数；层级由嵌套边框容器体现）
local function nodeRowText(node)
    local _marker = "   "
    if not node.isLeaf then
        _marker = node.expanded and "- " or "+ "
    end
    local _line = _marker .. node.key
    if node.isNull then
        _line = _line .. " = |cffff4444Null|r"
    elseif node.isLeaf then
        _line = _line .. " = |c" .. valueColor(node.value) .. tostring(node.value) .. "|r"
    elseif node.cycle then
        _line = _line .. " = |cffff4444（循环引用）|r"
    else
        _line = _line .. string.format(" |cff888888{%d 项}|r", #node.children)
    end
    return _line
end

-- 渲染一条叶子字段（纯文本，无边框）
local function renderLeafLine(container, node, cursorY, extraIndent)
    local _text = container:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    _text:SetPoint("TOPLEFT", container, "TOPLEFT", 12 + extraIndent * 10, -cursorY)
    _text:SetJustifyH("LEFT")
    _text:SetText(nodeRowText(node))
    return RowHeight
end

-- 创建可展开节点的头部行（点击切换展开/折叠）
local function createHeaderRow(parent, node, xOffset, yOffset)
    local _header = CreateFrame("Button", nil, parent, "BackdropTemplate")
    _header:SetPoint("TOPLEFT", parent, "TOPLEFT", xOffset, yOffset)
    _header:SetPoint("RIGHT", parent, "RIGHT", -xOffset, 0)
    _header:SetHeight(NodeHeaderHeight)
    _header:SetScript("OnClick", function()
        node.expanded = not node.expanded
        renderDbList()
    end)
    local _headerText = _header:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    _headerText:SetPoint("LEFT", 4, 0)
    _headerText:SetJustifyH("LEFT")
    _headerText:SetText(nodeRowText(node))
    return _header
end

-- 渲染一个可展开节点（depth<=1 的根/角色画边框容器；更深层表用无边框缩进行）
-- 返回该节点占用的总高度
local function renderGroupNode(container, node, cursorY, extraIndent)
    -- 深层表：无边框，头部行 + 子项直接排在当前容器内
    if node.depth > 1 then
        createHeaderRow(container, node, 10 + extraIndent * 10, -cursorY)
        local _cursor = cursorY + NodeHeaderHeight
        local _innerH = NodeHeaderHeight
        if node.expanded and node.children then
            for _, _child in ipairs(node.children) do
                local _h
                if _child.isLeaf then
                    _h = renderLeafLine(container, _child, _cursor, extraIndent + 1)
                else
                    _h = renderGroupNode(container, _child, _cursor, extraIndent + 1)
                end
                _cursor = _cursor + _h
                _innerH = _innerH + _h
            end
        end
        return _innerH
    end

    -- 根/角色：纯布局容器（无任何边框），头部在块顶，子项排布其内
    local _block = CreateFrame("Frame", nil, container)
    _block:SetPoint("TOPLEFT", container, "TOPLEFT", 6, -cursorY)
    _block:SetPoint("RIGHT", container, "RIGHT", -6, 0)
    createHeaderRow(_block, node, 6, 0)

    local _cursor = NodeHeaderHeight
    local _innerH = 0
    if node.expanded and node.children then
        for _, _child in ipairs(node.children) do
            local _h
            if _child.isLeaf then
                _h = renderLeafLine(_block, _child, _cursor, extraIndent + 1)
            else
                _h = renderGroupNode(_block, _child, _cursor, extraIndent + 1)
            end
            _cursor = _cursor + _h
            _innerH = _innerH + _h
        end
    end

    local _totalH = NodeHeaderHeight + _innerH + 8
    _block:SetHeight(_totalH)
    return _totalH
end

-- 渲染 PartyDB 树（不显示最外层 PartyDB 容器，直接从角色名称级开始；角色为边框容器，字段为无边框文本行）
renderDbList = function()
    if not DbScrollChild or not DbTreeRoot then return end
    -- 清空滚动内容（嵌套子帧随根帧一并回收）
    for _, _child in ipairs({ DbScrollChild:GetChildren() }) do
        _child:SetParent(nil)
        _child:Hide()
    end
    local _oldScroll = DbScrollFrame:GetVerticalScroll()
    -- 直接渲染根的子节点（每个角色一个边框容器），跳过最外层 PartyDB 容器
    local _totalH = 0
    local _cursor = 0
    for _, _char in ipairs(DbTreeRoot.children or {}) do
        local _h = renderGroupNode(DbScrollChild, _char, _cursor, 0)
        _cursor = _cursor + _h
        _totalH = _totalH + _h
    end
    DbScrollChild:SetHeight(_totalH + 10)
    DbScrollFrame:UpdateScrollChildRect()
    DbScrollFrame:SetVerticalScroll(_oldScroll)
end

-- 重新读取 mppe.PartyDB 并重建树（默认不展开；为角色记录补全缺失字段为 "Null"）
local function refreshDbTree()
    DbTreeRoot = buildTree("PartyDB", mppe.PartyDB, 0, {})
    for _, _char in ipairs(DbTreeRoot.children or {}) do
        fillMissingFields(_char)
    end
    renderDbList()
end

-- =================================================================
-- 功能2：INSP 观察工具
-- =================================================================

-- 设置观察状态文本（颜色 RGB）
local function setInspStatus(text, color)
    if not InspStatusText then return end
    if color then
        InspStatusText:SetTextColor(color[1], color[2], color[3])
    else
        InspStatusText:SetTextColor(1, 1, 1)
    end
    InspStatusText:SetText(text or "")
end

-- 渲染观察结果行到滚动区（悬停显示物品提示，右键插入聊天框）
local function renderInspResult()
    if not InspScrollChild then return end
    for _, _btn in ipairs(InspRowButtons) do
        _btn:SetParent(nil)
        _btn:Hide()
    end
    InspRowButtons = {}
    for _index, _rowData in ipairs(InspRows) do
        local _current = _rowData  -- 每轮新建局部，避免闭包共享循环变量
        local _row = createTextRow(InspScrollChild, (_index - 1) * RowHeight, _current.text, function(self, button)
            if button == "RightButton" and _current.link and ChatEdit_InsertLink then
                ChatEdit_InsertLink(_current.link)
            end
        end, _current.link)
        table.insert(InspRowButtons, _row)
    end
    InspScrollChild:SetHeight(#InspRows * RowHeight + 8)
    InspScrollFrame:UpdateScrollChildRect()
end

-- 读取观察目标的装备槽与装等，构建结果行
local function buildInspectResult(unit)
    local _target = mppe.Debug.inspectTarget
    local _name = UnitName(unit) or (_target and _target.name) or unit
    local _rows = {}
    local _total = 0
    local _count = 0
    local _twoHanded = true

    -- 逐槽读取（跳过槽位4=衬衫，与 PartySyncService 装等计算逻辑一致）
    for _slot = 1, 17 do
        if _slot ~= 4 then
            local _link = GetInventoryItemLink(unit, _slot)
            local _row = { slot = _slot, empty = not _link }
            if _link then
                local _itemName, _, _quality, _iLv, _, _, _, _, _, _, _, _classID, _subClassID = C_Item.GetItemInfo(_link)
                _row.name = _itemName or "（物品信息未缓存）"
                _row.quality = _quality or 1
                _row.iLv = _iLv or 0
                _row.link = _link
                -- 单手武器判断（与 PartySyncService 一致；9=战刃(DH)，13=拳套(Unarmed/Fist)）
                if _classID == 2 then
                    local _oneHanded = { [0] = true, [4] = true, [7] = true, [9] = true, [13] = true, [15] = true, [19] = true }
                    if _oneHanded[_subClassID] then _twoHanded = false end
                end
                _total = _total + (_iLv or 0)
                _count = _count + 1
            elseif _slot == 17 and _twoHanded == false then
                -- 单手武器副手空槽补一个装等位
                _count = _count + 1
                _row.iLv = 0
            end
            table.insert(_rows, _row)
        end
    end

    local _avg = 0
    if _count > 0 then _avg = mppe.MathRound(_total / _count, 0) end
    -- 参考值：插件同步算法 / 官方观察接口（C_PaperDollInfo 缺失时回退 0）
    local _syncAvg = (mppe.PartySync and mppe.PartySync:GetInspectItemLevel(unit)) or 0
    local _blizzAvg = 0
    if C_PaperDollInfo and C_PaperDollInfo.GetInspectItemLevel then
        _blizzAvg = C_PaperDollInfo.GetInspectItemLevel(unit) or 0
    end
    local _specId = GetInspectSpecialization(unit) or 0
    local _class = select(2, UnitClass(unit))

    -- 组装结果行（汇总行 + 装备槽明细行）
    InspRows = {}
    table.insert(InspRows, {
        text = string.format("|cffffffff%s（%s %d）|r", _name, _class or "未知", _specId),
    })
    table.insert(InspRows, {
        text = string.format("|cff00c8ff平均装等：%d（槽位 %d）|r  |cffffd200插件同步：%d|r  |cffff8040官方值：%d|r", _avg, _count, _syncAvg, _blizzAvg),
    })
    table.insert(InspRows, { text = "--------------------------------" })
    for _, _r in ipairs(_rows) do
        local _slotName = DebugSlotNames[_r.slot] or ("槽位" .. _r.slot)
        if _r.empty then
            table.insert(InspRows, { text = string.format("|cff9d9d9d[%s] （空）|r", _slotName) })
        else
            local _color = DebugQualityColors[_r.quality] or "ffffffff"
            table.insert(InspRows, {
                text = string.format("[%s] |c%s%s|r  装等 |cffffd200%d|r", _slotName, _color, _r.name, _r.iLv),
                link = _r.link,
            })
        end
    end

    mppe.Debug.inspectTarget = nil
    setInspStatus(string.format("观察完成：%s（右键物品行可插入聊天框）", _name), { 0.3, 1, 0.5 })
    renderInspResult()
end

-- 处理 INSPECT_READY：校验 GUID 后读取装备明细
local function handleInspectReady(guid)
    local _target = mppe.Debug.inspectTarget
    if not _target or not Inspecting then return end
    if guid ~= _target.guid then return end
    Inspecting = false
    if InspectTimeout then InspectTimeout:Cancel() InspectTimeout = nil end

    -- 重新定位单位（队伍可能变动导致原 unit 失效）
    local _unit = _target.unit
    if not UnitExists(_unit) or UnitGUID(_unit) ~= _target.guid then
        for _i = 1, GetNumSubgroupMembers() do
            local _pu = "party" .. _i
            if UnitGUID(_pu) == _target.guid then
                _unit = _pu
                break
            end
        end
    end
    if not UnitExists(_unit) then
        mppe.Debug.inspectTarget = nil
        setInspStatus("目标已离开队伍，无法读取装备", { 1, 0.4, 0.4 })
        return
    end
    buildInspectResult(_unit)
end

-- =================================================================
-- 窗体创建（懒初始化，首次打开时执行）
-- =================================================================

-- 创建标签页按钮
local function createTabButton(parent, text, anchorX, anchorY)
    local _btn = CreateFrame("Button", nil, parent, "BackdropTemplate")
    _btn:SetSize(118, 22)
    _btn:SetPoint("TOPLEFT", parent, "TOPLEFT", anchorX, anchorY)
    _btn:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        bgColor = { 0.15, 0.15, 0.15, 0.8 },
        edgeColor = { 0.6, 0.6, 0.6, 1 },
    })
    local _text = _btn:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    _text:SetPoint("CENTER")
    _text:SetText(text)
    _btn.Text = _text
    return _btn
end

-- 切换标签页高亮（activeBtn 高亮，其余变暗）
local function setActiveTab(activeBtn, ...)
    for _, _btn in ipairs({ ... }) do
        if _btn == activeBtn then
            _btn:SetBackdropColor(0.25, 0.35, 0.55, 0.9)
            _btn.Text:SetTextColor(1, 1, 1)
        else
            _btn:SetBackdropColor(0.12, 0.12, 0.12, 0.7)
            _btn.Text:SetTextColor(0.7, 0.7, 0.7)
        end
    end
end

-- 切换显示面板
local function showPanel(which)
    if which == "db" then
        DbPanel:Show()
        InspPanel:Hide()
        AssetPanel:Hide()
        setActiveTab(TabDB, TabInsp, TabAsset)
        refreshDbTree()
    elseif which == "insp" then
        DbPanel:Hide()
        InspPanel:Show()
        AssetPanel:Hide()
        setActiveTab(TabInsp, TabDB, TabAsset)
    else
        DbPanel:Hide()
        InspPanel:Hide()
        AssetPanel:Show()
        setActiveTab(TabAsset, TabDB, TabInsp)
        renderAssetGrid()
    end
end

-- 获取/创建池化的素材网格单元格（悬停用 GameTooltip 显示素材的 ID 等信息）
getAssetCell = function(slot)
    local _cell = AssetCells[slot]
    if _cell then return _cell end
    _cell = CreateFrame("Button", nil, AssetScrollChild, "BackdropTemplate")
    _cell:SetSize(AssetCellSize, AssetCellSize)
    _cell:SetBackdrop({
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        bgColor = { 0, 0, 0, 0.35 },
        edgeColor = { 0.3, 0.3, 0.3, 1 },
    })
    _cell.Tex = _cell:CreateTexture(nil, "ARTWORK")
    _cell.Tex:SetPoint("TOPLEFT", _cell, "TOPLEFT", 2, -2)
    _cell.Tex:SetPoint("BOTTOMRIGHT", _cell, "BOTTOMRIGHT", -2, 2)
    -- 悬停：显示素材名称 / 元素ID(FileID) / AtlasID / 尺寸 / 贴图路径
    _cell:SetScript("OnEnter", function(self)
        self:SetBackdropColor(1, 1, 1, 0.18)
        local _name = self.atlasName
        if not _name then return end
        local _info = C_Texture.GetAtlasInfo(_name)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(_name, 1, 1, 1)
        if _info then
            GameTooltip:AddLine(string.format("元素ID(FileID)：%d", C_Texture.GetAtlasElementID(_name) or 0))
            GameTooltip:AddLine(string.format("AtlasID：%d", C_Texture.GetAtlasID(_name) or 0))
            GameTooltip:AddLine(string.format("尺寸：%dx%d", _info.width or 0, _info.height or 0))
            if _info.file then GameTooltip:AddLine(string.format("父贴图 FileID：%d", _info.file)) end
            if _info.filename then GameTooltip:AddLine(string.format("贴图：%s", _info.filename)) end
        end
        GameTooltip:Show()
    end)
    _cell:SetScript("OnLeave", function(self)
        self:SetBackdropColor(0, 0, 0, 0.35)
        GameTooltip:Hide()
    end)
    -- 左键：把素材名填入筛选框，便于继续定位/筛选
    _cell:SetScript("OnClick", function(self)
        if self.atlasName and AssetFilterInput then
            AssetFilterInput:SetText(self.atlasName)
            applyAssetFilter()
        end
    end)
    AssetCells[slot] = _cell
    return _cell
end

-- 虚拟化渲染网格：只创建/摆放视口内的单元格，滚动或拖动滚动条时重建可见区
renderAssetGrid = function()
    if not AssetScrollFrame or not AssetScrollChild then return end
    local _cols = math.max(1, math.floor((AssetScrollFrame:GetWidth() or 400) / AssetCellPitch))
    local _rows = math.ceil((AssetScrollFrame:GetHeight() or 300) / AssetCellPitch)
    local _poolNeeded = _cols * (_rows + 1)

    -- 确保复用池足够（只在不足时新建）
    for _i = #AssetCells + 1, _poolNeeded do getAssetCell(_i) end

    -- 内容总高度 = 总行数 * 行距
    local _totalRows = math.max(1, math.ceil(AssetListCount / _cols))
    AssetScrollChild:SetHeight(_totalRows * AssetCellPitch + 10)
    AssetScrollFrame:UpdateScrollChildRect()

    -- 计算可见起始行，摆放池内格子
    local _topRow = math.max(0, math.floor(AssetScrollFrame:GetVerticalScroll() / AssetCellPitch))
    for _slot = 1, _poolNeeded do
        local _cell = AssetCells[_slot]
        local _row = _topRow + math.floor((_slot - 1) / _cols)
        local _col = (_slot - 1) % _cols
        local _item = _row * _cols + _col + 1
        if _item <= AssetListCount then
            local _name = AssetList[_item]
            _cell:Show()
            _cell.atlasName = _name
            _cell.Tex:SetAtlas(_name)
            _cell:ClearAllPoints()
            _cell:SetPoint("TOPLEFT", AssetScrollChild, "TOPLEFT", 4 + _col * AssetCellPitch, -(_row * AssetCellPitch))
        else
            _cell:Hide()
        end
    end

    if AssetStatusText then
        AssetStatusText:SetText(string.format("共 %d 个素材，每行 %d 个。悬停查看 ID 等信息，左键填入筛选框。", AssetListCount, _cols))
    end
end

-- 根据筛选框关键字重建素材列表（关键字为空则显示全部）
applyAssetFilter = function()
    if not AssetFilterInput then return end
    AssetFilter = strlower(strtrim(AssetFilterInput:GetText() or ""))
    AssetList = {}
    if AssetFilter == "" then
        AssetList = AssetAll
    else
        for _, _name in ipairs(AssetAll) do
            if strfind(strlower(_name), AssetFilter, 1, true) then
                AssetList[#AssetList + 1] = _name
            end
        end
    end
    AssetListCount = #AssetList
    AssetScrollFrame:SetVerticalScroll(0)
    renderAssetGrid()
end

-- 下拉框初始化：列出当前队伍成员
local function initializeDropdown()
    if not MemberDropdown then return end
    local _info = UIDropDownMenu_CreateInfo()
    for _i = 1, GetNumSubgroupMembers() do
        local _unit = "party" .. _i
        local _name, _realm = UnitFullName(_unit)
        if _name then
            _info = UIDropDownMenu_CreateInfo()
            _info.text = string.format("%d. %s", _i, _name)
            _info.value = _i
            _info.func = function(button)
                local _memberIndex = button.value  -- 通过按钮取值，避免闭包捕获循环变量
                mppe.Debug.selectedMember = _memberIndex
                UIDropDownMenu_SetSelectedValue(MemberDropdown, _memberIndex)
                UIDropDownMenu_SetText(MemberDropdown, button:GetText())
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(_info)
        end
    end
end

-- 创建调试主窗体
local function initDebugFrame()
    if FrameInitialized then return end
    FrameInitialized = true

    -- 主窗体（SettingsFrameTemplate 自带关闭按钮与边框）
    DebugFrame = CreateFrame("Frame", "MPPE_DebugFrame", UIParent, "SettingsFrameTemplate")
    DebugFrame:SetSize(FrameWidth, FrameHeight)
    DebugFrame:SetPoint("CENTER")
    DebugFrame:SetMovable(true)
    DebugFrame:SetResizable(true)
    DebugFrame:SetResizeBounds(360, 280, 1100, 900)
    DebugFrame:EnableMouse(true)
    DebugFrame:RegisterForDrag("LeftButton")
    DebugFrame:SetScript("OnDragStart", function(self) self:StartMoving() end)
    DebugFrame:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    DebugFrame:SetClampedToScreen(true)
    DebugFrame:Hide()

    if DebugFrame.ClosePanelButton then
        DebugFrame.ClosePanelButton:SetScript("OnClick", function() mppe.Debug_Close() end)
    end

    -- 标题
    DebugFrame.title = DebugFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    DebugFrame.title:SetPoint("TOP", DebugFrame, 0, -5)
    DebugFrame.title:SetText("MPPE Debug（/mppe debug）")

    -- 标签页
    TabDB = createTabButton(DebugFrame, "PartyDB", 10, -28)
    TabInsp = createTabButton(DebugFrame, "INSP 观察", 138, -28)
    TabAsset = createTabButton(DebugFrame, "素材浏览", 266, -28)
    TabDB:SetScript("OnClick", function() showPanel("db") end)
    TabInsp:SetScript("OnClick", function() showPanel("insp") end)
    TabAsset:SetScript("OnClick", function() showPanel("asset") end)

    -- 内容面板（无白边框，透明边缘）
    local _backdrop = {
        edgeFile = "Interface\\Buttons\\WHITE8x8",
        edgeSize = 1,
        bgColor = { 0, 0, 0, 0.5 },
        edgeColor = { 0, 0, 0, 0 },
    }
    DbPanel = CreateFrame("Frame", "MPPE_DebugDB_Panel", DebugFrame, "BackdropTemplate")
    DbPanel:SetPoint("TOPLEFT", DebugFrame, "TOPLEFT", 10, -56)
    DbPanel:SetPoint("BOTTOMRIGHT", DebugFrame, "BOTTOMRIGHT", -10, 10)
    DbPanel:SetBackdrop(_backdrop)

    InspPanel = CreateFrame("Frame", "MPPE_DebugInsp_Panel", DebugFrame, "BackdropTemplate")
    InspPanel:SetPoint("TOPLEFT", DbPanel, "TOPLEFT")
    InspPanel:SetPoint("BOTTOMRIGHT", DbPanel, "BOTTOMRIGHT")
    InspPanel:SetBackdrop(_backdrop)

    AssetPanel = CreateFrame("Frame", "MPPE_DebugAsset_Panel", DebugFrame, "BackdropTemplate")
    AssetPanel:SetPoint("TOPLEFT", DbPanel, "TOPLEFT")
    AssetPanel:SetPoint("BOTTOMRIGHT", DbPanel, "BOTTOMRIGHT")
    AssetPanel:SetBackdrop(_backdrop)

    -- ==================================================
    -- DB 面板：标题 + 刷新按钮 + 滚动树
    -- ==================================================
    local _dbHeader = DbPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    _dbHeader:SetPoint("TOPLEFT", DbPanel, "TOPLEFT", 8, -6)
    _dbHeader:SetText("PartyDB 数据树（mppe.PartyDB）")

    local _dbRefresh = CreateFrame("Button", nil, DbPanel, "UIPanelButtonTemplate")
    _dbRefresh:SetSize(56, 22)
    _dbRefresh:SetPoint("TOPRIGHT", DbPanel, "TOPRIGHT", -8, -4)
    _dbRefresh:SetText("刷新")
    _dbRefresh:SetScript("OnClick", function() refreshDbTree() end)

    DbScrollFrame = CreateFrame("ScrollFrame", "MPPE_DebugDB_Scroll", DbPanel, "ScrollFrameTemplate")
    DbScrollFrame:SetPoint("TOPLEFT", DbPanel, "TOPLEFT", 6, -30)
    DbScrollFrame:SetPoint("BOTTOMRIGHT", DbPanel, "BOTTOMRIGHT", -6, 6)
    DbScrollFrame:EnableMouseWheel(true)
    -- 隐藏滚动条（保留滚轮滚动）
    DbScrollFrame.ScrollBar:SetHideIfUnscrollable(false)
    DbScrollFrame.ScrollBar:Hide()
    DbScrollFrame.ScrollBar:HookScript("OnShow", function(self) self:Hide() end)

    DbScrollChild = CreateFrame("Frame", "MPPE_DebugDB_ScrollChild", DbScrollFrame)
    DbScrollFrame:SetScrollChild(DbScrollChild)
    DbScrollChild:SetWidth(DebugScrollWidth)

    -- ==================================================
    -- INSP 面板：成员下拉框 + 观察按钮 + 滚动结果
    -- ==================================================
    MemberDropdown = CreateFrame("Frame", "MPPE_DebugInsp_MemberDrop", InspPanel, "UIDropDownMenuTemplate")
    MemberDropdown:SetSize(170, 32)
    MemberDropdown:SetPoint("TOPLEFT", InspPanel, "TOPLEFT", 8, -6)
    UIDropDownMenu_SetWidth(MemberDropdown, 170)
    UIDropDownMenu_Initialize(MemberDropdown, initializeDropdown)
    UIDropDownMenu_SetText(MemberDropdown, "选择队友")

    local _inspectBtn = CreateFrame("Button", nil, InspPanel, "UIPanelButtonTemplate")
    _inspectBtn:SetSize(96, 22)
    _inspectBtn:SetPoint("LEFT", MemberDropdown, "RIGHT", 8, 0)
    _inspectBtn:SetText("开始观察")
    _inspectBtn:SetScript("OnClick", function()
        mppe.Debug_StartInspect(mppe.Debug.selectedMember)
    end)

    local _refreshBtn = CreateFrame("Button", nil, InspPanel, "UIPanelButtonTemplate")
    _refreshBtn:SetSize(56, 22)
    _refreshBtn:SetPoint("LEFT", _inspectBtn, "RIGHT", 8, 0)
    _refreshBtn:SetText("刷新")
    _refreshBtn:SetScript("OnClick", function()
        UIDropDownMenu_Initialize(MemberDropdown, initializeDropdown)
        UIDropDownMenu_SetText(MemberDropdown, "选择队友")
        mppe.Debug.selectedMember = nil
        setInspStatus("下拉列表已刷新", nil)
    end)

    InspStatusText = InspPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    InspStatusText:SetPoint("TOPLEFT", InspPanel, "TOPLEFT", 8, -32)
    InspStatusText:SetText("")

    InspScrollFrame = CreateFrame("ScrollFrame", "MPPE_DebugInsp_Scroll", InspPanel, "ScrollFrameTemplate")
    InspScrollFrame:SetPoint("TOPLEFT", InspPanel, "TOPLEFT", 6, -54)
    InspScrollFrame:SetPoint("BOTTOMRIGHT", InspPanel, "BOTTOMRIGHT", -6, 6)
    InspScrollFrame:EnableMouseWheel(true)
    -- 隐藏滚动条（保留滚轮滚动）
    InspScrollFrame.ScrollBar:SetHideIfUnscrollable(false)
    InspScrollFrame.ScrollBar:Hide()
    InspScrollFrame.ScrollBar:HookScript("OnShow", function(self) self:Hide() end)

    InspScrollChild = CreateFrame("Frame", "MPPE_DebugInsp_ScrollChild", InspScrollFrame)
    InspScrollFrame:SetScrollChild(InspScrollChild)
    InspScrollChild:SetWidth(DebugScrollWidth)

    -- ==================================================
    -- 素材浏览面板：遍历全部 Atlas 素材的虚拟化网格画廊
    -- ==================================================
    -- 首次构建时缓存全部 Atlas 名（一次性枚举）
    AssetAll = C_Texture.GetAtlasElements() or {}
    local _assetHeader = AssetPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    _assetHeader:SetPoint("TOPLEFT", AssetPanel, "TOPLEFT", 8, -6)
    _assetHeader:SetText(string.format("游戏内图片素材浏览（共 %d 个 Atlas）", #AssetAll))

    AssetFilterInput = CreateFrame("EditBox", "MPPE_DebugAsset_Filter", AssetPanel, "InputBoxTemplate")
    AssetFilterInput:SetAutoFocus(false)
    AssetFilterInput:SetHeight(24)
    AssetFilterInput:SetPoint("TOPLEFT", AssetPanel, "TOPLEFT", 8, -28)
    AssetFilterInput:SetPoint("RIGHT", AssetPanel, "RIGHT", -70, 0)
    AssetFilterInput:SetScript("OnEnterPressed", function(self) self:ClearFocus() applyAssetFilter() end)
    AssetFilterInput:SetScript("OnTextChanged", function(self) applyAssetFilter() end)

    local _assetFilterBtn = CreateFrame("Button", nil, AssetPanel, "UIPanelButtonTemplate")
    _assetFilterBtn:SetSize(56, 22)
    _assetFilterBtn:SetPoint("TOPRIGHT", AssetPanel, "TOPRIGHT", -8, -28)
    _assetFilterBtn:SetText("筛选")
    _assetFilterBtn:SetScript("OnClick", function() applyAssetFilter() end)

    AssetScrollFrame = CreateFrame("ScrollFrame", "MPPE_DebugAsset_Scroll", AssetPanel, "ScrollFrameTemplate")
    AssetScrollFrame:SetPoint("TOPLEFT", AssetPanel, "TOPLEFT", 6, -56)
    AssetScrollFrame:SetPoint("BOTTOMRIGHT", AssetPanel, "BOTTOMRIGHT", -6, -22)
    AssetScrollFrame:EnableMouseWheel(true)
    -- 滚动/拖滚动条时重建可见区（HookScript 保留模板自带的滚动条联动）
    AssetScrollFrame:HookScript("OnVerticalScroll", function(self, offset) renderAssetGrid() end)

    AssetScrollChild = CreateFrame("Frame", "MPPE_DebugAsset_ScrollChild", AssetScrollFrame)
    AssetScrollFrame:SetScrollChild(AssetScrollChild)
    AssetScrollChild:SetWidth(DebugScrollWidth)

    AssetStatusText = AssetPanel:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    AssetStatusText:SetPoint("BOTTOMLEFT", AssetPanel, "BOTTOMLEFT", 8, 6)
    AssetStatusText:SetPoint("BOTTOMRIGHT", AssetPanel, "BOTTOMRIGHT", -8, 6)
    AssetStatusText:SetHeight(14)
    AssetStatusText:SetJustifyH("LEFT")
    AssetStatusText:SetJustifyV("BOTTOM")
    AssetStatusText:SetText("加载中...")

    applyAssetFilter()

    -- 窗体尺寸变化：滚动内容宽度自适应并重绘
    DebugFrame:SetScript("OnSizeChanged", function(self)
        local _w = self:GetWidth()
        if DbScrollChild then DbScrollChild:SetWidth(_w - 40) end
        if InspScrollChild then InspScrollChild:SetWidth(_w - 40) end
        if AssetScrollChild then AssetScrollChild:SetWidth(_w - 40) end
        renderDbList()
        renderInspResult()
        renderAssetGrid()
    end)

    -- 右下角调整大小手柄
    local _grip = CreateFrame("Frame", "MPPE_DebugResizeGrip", DebugFrame)
    _grip:SetSize(14, 14)
    _grip:SetPoint("BOTTOMRIGHT", DebugFrame, "BOTTOMRIGHT", -1, 1)
    _grip:EnableMouse(true)
    _grip:RegisterForDrag("LeftButton")
    _grip:SetScript("OnMouseDown", function(self, button)
        if button == "LeftButton" then
            self:GetParent():StartSizing("BOTTOMRIGHT")
        end
    end)
    _grip:SetScript("OnMouseUp", function(self)
        self:GetParent():StopMovingOrSizing()
    end)
    _grip:SetScript("OnDragStop", function(self)
        self:GetParent():StopMovingOrSizing()
    end)
    local _gripTex = _grip:CreateTexture(nil, "OVERLAY")
    _gripTex:SetAllPoints()
    _gripTex:SetTexture("Interface\\ChatFrame\\UI-ChatIM-SizeGrabber-Up")
    _gripTex:SetVertexColor(1, 1, 0.6)
    _grip:SetScript("OnEnter", function()
        _gripTex:SetBlendMode("ADD")
        _gripTex:SetVertexColor(1, 1, 1)
    end)
    _grip:SetScript("OnLeave", function()
        _gripTex:SetBlendMode("BLEND")
        _gripTex:SetVertexColor(1, 1, 0.6)
    end)
end

-- =================================================================
-- 公开 API
-- =================================================================

-- 打开调试窗体
function mppe.Debug_Open()
    if UnitAffectingCombat("player") then
        print("[MPPE] 战斗中无法打开调试窗体。")
        return
    end
    initDebugFrame()
    DebugFrame:Show()
    showPanel("db")
end

-- 关闭调试窗体（同时停止未完成的观察）
function mppe.Debug_Close()
    if not FrameInitialized then return end
    if Inspecting then
        Inspecting = false
        if InspectTimeout then InspectTimeout:Cancel() InspectTimeout = nil end
        mppe.Debug.inspectTarget = nil
    end
    DebugFrame:Hide()
end

-- 切换调试窗体显隐
function mppe.Debug_Toggle()
    if FrameInitialized and DebugFrame:IsShown() then
        mppe.Debug_Close()
    else
        mppe.Debug_Open()
    end
end

-- 对指定队友执行一次 INSP 观察（memberIndex：队友序号 1-5）
function mppe.Debug_StartInspect(memberIndex)
    if not FrameInitialized then initDebugFrame() end
    showPanel("insp")
    if UnitAffectingCombat("player") then
        setInspStatus("战斗中无法进行观察", { 1, 0.4, 0.4 })
        return
    end
    local _index = tonumber(memberIndex)
    if not _index or _index < 1 or _index > GetNumSubgroupMembers() then
        setInspStatus("请先在列表中选择队友", { 1, 0.7, 0.3 })
        return
    end
    local _unit = "party" .. _index
    if not UnitExists(_unit) then
        setInspStatus("队友 " .. _index .. " 不在队伍中", { 1, 0.4, 0.4 })
        return
    end

    local _guid = UnitGUID(_unit)
    local _name = UnitName(_unit)
    mppe.Debug.inspectTarget = { unit = _unit, guid = _guid, name = _name, index = _index }
    Inspecting = true
    setInspStatus(string.format("正在观察 %s ...", _name or _unit), { 1, 1, 0.5 })
    InspRows = {}
    renderInspResult()
    NotifyInspect(_unit)

    -- 超时保护：3 秒未收到 INSPECT_READY 则判定失败
    if InspectTimeout then InspectTimeout:Cancel() end
    InspectTimeout = C_Timer.After(3, function()
        if Inspecting then
            Inspecting = false
            mppe.Debug.inspectTarget = nil
            setInspStatus("观察超时（未收到 INSPECT_READY）", { 1, 0.4, 0.4 })
        end
    end)
end

-- =================================================================
-- INSPECT_READY 事件监听（文件加载即注册，独立于插件观察调度器）
-- =================================================================
local InspEventFrame = CreateFrame("Frame")
InspEventFrame:RegisterEvent("INSPECT_READY")
InspEventFrame:SetScript("OnEvent", function(self, event, guid)
    handleInspectReady(guid)
end)

-- =================================================================
-- 斜杠命令包装：/mppe debug [队友序号]（Debug.lua 在 Settings.lua 之后加载）
-- =================================================================
local _origMPPECmd = SlashCmdList.MPPE
rawset(SlashCmdList, "MPPE", function(msg)
    local _args = { strsplit(" ", strtrim(msg or "")) }
    local _command = strlower(_args[1] or "")
    if _command == "debug" then
        local _member = tonumber(_args[2] or "")
        if _member then
            -- /mppe debug 2：直接打开并对 2 号队友执行观察
            mppe.Debug_Open()
            mppe.Debug_StartInspect(_member)
        else
            mppe.Debug_Toggle()
        end
    elseif _origMPPECmd then
        _origMPPECmd(msg)
    end
end)
