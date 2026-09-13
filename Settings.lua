local ADDON_NAME, mppe = ...
local Translate = mppe.Translate

-- 检查数据库是否已加载
local function IsDBLoaded() return MythicPlusPageExtensionDB ~= nil end
-- 延迟初始化标志
local settingsInitialized = false

local mppe_sFrame = CreateFrame("Frame", "MPPE_MythicPlusPageExtension_SettingFrame", InterfaceOptionsFramePanelContainer)
mppe_sFrame.name = "MPPE"
mppe_sFrame:Hide()

local mppe_sTitle = mppe_sFrame:CreateFontString(nil, "ARTWORK", "GameFontNormal")
mppe_sTitle:SetPoint("TOPLEFT", 0, -15)
mppe_sTitle:SetText(Translate['Mythic Plus Page Extension']..(mppe.Translator and " ("..mppe.Translator..")" or ""))
mppe_sTitle:SetFont(STANDARD_TEXT_FONT, 18, "OUTLINE")

local line_sTop = mppe_sFrame:CreateTexture(nil, "ARTWORK")
line_sTop:SetSize(550, 1)
line_sTop:SetAtlas("spec-dividerline", false)
line_sTop:SetPoint("TOP", mppe_sFrame, "TOP", -15, -40)

local line_sBottom = mppe_sFrame:CreateTexture(nil, "ARTWORK")
line_sBottom:SetSize(550, 1)
line_sBottom:SetAtlas("spec-dividerline", false)
line_sBottom:SetPoint("BOTTOM", mppe_sFrame, "BOTTOM", -15, 65)

local mppe_sFooter = mppe_sFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
mppe_sFooter:SetPoint("RIGHT", mppe_sFrame, "RIGHT", -10, 0)
mppe_sFooter:SetPoint("BOTTOM", mppe_sFrame, "BOTTOM", 0, 10)
mppe_sFooter:SetJustifyH("RIGHT")
mppe_sFooter:SetText("|c00ffff63MythicPlusPageExtension By CN2714\nReferences: AngryKeystones KeystoneLoot BugSack\nWA:uPxmk1k-L WA:ud2YBS4WC WA:lxA3Tr2Fr (and DeepSeek)|r")

--==================================================================
-- 创建标签页容器
local settings_Tabs = CreateFrame("Frame", "MPPE_SettingsTabs", mppe_sFrame)
settings_Tabs:SetPoint("TOP", line_sTop, "BOTTOM", 0, -5)
settings_Tabs:SetPoint("BOTTOM", line_sBottom, "TOP", 0, 5)
settings_Tabs:SetWidth(550)

-- 标签页系统变量
settings_Tabs.tabs = {}
settings_Tabs.currentTab = 1

-- 标签页按钮容器
settings_Tabs.tabButtons = CreateFrame("Frame", "MPPE_TabButtons", settings_Tabs)
settings_Tabs.tabButtons:SetHeight(30)
settings_Tabs.tabButtons:SetPoint("TOP", 10, 0)
settings_Tabs.tabButtons:SetWidth(550)

-- 标签页内容容器
settings_Tabs.content = CreateFrame("Frame", "MPPE_TabContent", settings_Tabs)
settings_Tabs.content:SetPoint("TOP", settings_Tabs.tabButtons, "BOTTOM", 0, 7)
settings_Tabs.content:SetPoint("BOTTOM", 0, 0)
settings_Tabs.content:SetWidth(550)

-- 创建边框纹理
settings_Tabs.content.borderTop = settings_Tabs.content:CreateTexture(nil, "BORDER")
settings_Tabs.content.borderTop:SetHeight(2)
settings_Tabs.content.borderTop:SetPoint("TOPLEFT", 0, 0)
settings_Tabs.content.borderTop:SetPoint("TOPRIGHT", 0, 0)
settings_Tabs.content.borderTop:SetColorTexture(0.3, 0.3, 0.3, 1)

settings_Tabs.content.borderBottom = settings_Tabs.content:CreateTexture(nil, "BORDER")
settings_Tabs.content.borderBottom:SetHeight(2)
settings_Tabs.content.borderBottom:SetPoint("BOTTOMLEFT", 0, -2)
settings_Tabs.content.borderBottom:SetPoint("BOTTOMRIGHT", 0, -2)
settings_Tabs.content.borderBottom:SetColorTexture(0.3, 0.3, 0.3, 1)

settings_Tabs.content.borderLeft = settings_Tabs.content:CreateTexture(nil, "BORDER")
settings_Tabs.content.borderLeft:SetWidth(2)
settings_Tabs.content.borderLeft:SetPoint("TOPLEFT", 0, 0)
settings_Tabs.content.borderLeft:SetPoint("BOTTOMLEFT", 0, 0)
settings_Tabs.content.borderLeft:SetColorTexture(0.3, 0.3, 0.3, 1)

settings_Tabs.content.borderRight = settings_Tabs.content:CreateTexture(nil, "BORDER")
settings_Tabs.content.borderRight:SetWidth(2)
settings_Tabs.content.borderRight:SetPoint("TOPRIGHT", 0, 0)
settings_Tabs.content.borderRight:SetPoint("BOTTOMRIGHT", 0, 0)
settings_Tabs.content.borderRight:SetColorTexture(0.3, 0.3, 0.3, 1)

-- 创建标签按钮的函数
function settings_Tabs:CreateTab(tabName, tabContentFrame)
    local tabID = #self.tabs + 1
    
    -- 创建标签按钮
    local tabButton = CreateFrame("Button", "MPPE_TabButton"..tabID, self.tabButtons)
    tabButton:SetSize(150, 25)  -- 初始尺寸，创建全部标签后由 LayoutTabButtons 均分重排
    
    -- 设置位置
    if tabID == 1 then
        tabButton:SetPoint("TOPLEFT", 10, 0)
    else
        tabButton:SetPoint("LEFT", self.tabs[tabID-1].button, "RIGHT", 3, 0)
    end
    
    -- 创建背景纹理
    tabButton.bg = tabButton:CreateTexture(nil, "BACKGROUND")
    tabButton.bg:SetAllPoints()
    tabButton.bg:SetColorTexture(0.3, 0.3, 0.3, 1)

    -- 创建选中状态纹理
    tabButton.selected = tabButton:CreateTexture(nil, "ARTWORK")
    tabButton.selected:SetAllPoints()
    tabButton.selected:SetColorTexture(0.1, 0.4, 0.8, 0.6)
    tabButton.selected:Hide()
    
    -- 创建高亮纹理
    tabButton.highlight = tabButton:CreateTexture(nil, "HIGHLIGHT")
    tabButton.highlight:SetAllPoints()
    tabButton.highlight:SetColorTexture(1, 1, 1, 0.2)
    
    -- 创建文本
    tabButton.text = tabButton:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    tabButton.text:SetPoint("CENTER")
    tabButton.text:SetText(tabName)
    
    -- 点击事件
    tabButton:SetScript("OnClick", function()
        settings_Tabs:SetTab(tabID)
    end)
    
    -- 鼠标悬停效果
    tabButton:SetScript("OnEnter", function(self)
        self.bg:SetColorTexture(0.4, 0.4, 0.6, 1)
    end)
    
    tabButton:SetScript("OnLeave", function(self)
        if settings_Tabs.currentTab ~= tabID then
            self.bg:SetColorTexture(0.3, 0.3, 0.3, 1)
        else
            self.bg:SetColorTexture(0.1, 0.4, 0.8, 0.6)
        end
    end)
    
    -- 创建内容框架作为滚动框架
    local contentFrame = CreateFrame("ScrollFrame", "MPPE_ContentFrame_"..tabID, self.content, "ScrollFrameTemplate")
    contentFrame:SetPoint("TOPLEFT", self.content, "TOPLEFT", 2, -5)  -- 调整位置，留出一点间距
    contentFrame:SetPoint("BOTTOMRIGHT", self.content, "BOTTOMRIGHT", -22, 0)
    contentFrame:Hide()

    if tabContentFrame then
        tabContentFrame:SetParent(contentFrame)
        contentFrame:SetScrollChild(tabContentFrame)
    end
    -- 存储标签信息
    self.tabs[tabID] = {
        button = tabButton,
        content = contentFrame,
        name = tabName
    }
    
    return tabID
end

-- 切换标签页
function settings_Tabs:SetTab(tabID)
    if not self.tabs[tabID] then return end
    
    -- 隐藏当前标签内容并重置样式
    if self.currentTab and self.tabs[self.currentTab] then
        self.tabs[self.currentTab].content:Hide()
        self.tabs[self.currentTab].button.selected:Hide()
        self.tabs[self.currentTab].button.bg:SetColorTexture(0.3, 0.3, 0.3, 1)
    end
    
    -- 显示新标签内容并设置选中样式
    self.tabs[tabID].content:Show()
    self.tabs[tabID].button.selected:Show()
    self.tabs[tabID].button.bg:SetColorTexture(0.1, 0.4, 0.8, 0.6)
    
    -- 更新当前标签
    self.currentTab = tabID
end

--==================================================================
settings_Tabs.SettingsList = {
    {-- Score&Teleport
        tabName = "Score&Teleport",
        tabList = {
            {
                db = "ScoreNTeleport_Enable",
                name = "Enable",
                type = "CheckBox", 
                indent = 0,
                value = {
                    default = true,
                }
            },
            {
                name = "↑Disabling this feature requires a UI reload (/reload) to take effect.",
                type = "Label", 
                indent = 0,
                lines = 1
            },
            {
                db = "ScoreNTeleport_TryClearOther",
                name = "Try to clear other non-native content on dungeon icon(excluding this addon).",
                type = "CheckBox", 
                indent = 1,
                value = {
                    default = true,
                }
            },
            {
                db = "ScoreNTeleport_ScoreColorStyle",
                name = "Score Text Color Style",
                type = "ComboBoxV2", 
                indent = 1,
                value = {
                    default = "highestlv",
                    list = {["highestlv"] = "Match Highest Level", ["raiderio"] = "RaiderIO Style", ["standard"] = "Standard Style"}
                }
            },
            {
                db = "ScoreNTeleport_EnableTeleport",
                name = "Enable click-to-use teleport(separate toggle to avoid conflict with other addons; does not affect other functions).",
                type = "CheckBox", 
                indent = 1,
                value = {
                    default = true,
                }
            },
            {
                db = "ScoreNTeleport_SendTeleportInfo",
                name = "Send a message to the party channel after using teleport.",
                type = "CheckBox", 
                indent = 1,
                value = {
                    default = true,
                }
            },
            {
                db = "ScoreNTeleport_STI_CastStatus",
                name = "Send message when",
                type = "ComboBoxV2", 
                indent = 2,
                value = {
                    default = "castsucceeded",
                    list = {["caststart"] = "Teleport Start", ["castsucceeded"] = "Teleport Complete"}
                }
            },
            {
                db = "ScoreNTeleport_UseOldStyle",
                name = "Use Original Style (WA:ud2YBS4WC)",
                type = "CheckBox", 
                indent = 1,
                value = {
                    default = false,
                }
            },
            {
                db = "ScoreNTeleport_DunShortName_FontSize",
                name = "Dungeon Shortname Font Size",
                type = "SliderV2", 
                indent = 1,
                value = {
                    default = 13,
                    min = 5,
                    max = 25,
                    step = 0.1
                }
            },
            {
                db = "ScoreNTeleport_DunShortName_PerLine",
                name = "The number of characters per line of the Dungeon Shortname",
                type = "SliderV2", 
                indent = 1,
                value = {
                    default = 7,
                    min = 1,
                    max = 25,
                    step = 1
                }
            },
            {
                db = "ScoreNTeleport_DunLevel_FontSize",
                name = "Dungeon Highest Level Font Size",
                type = "SliderV2", 
                indent = 1,
                value = {
                    default = 22,
                    min = 5,
                    max = 25,
                    step = 0.1
                }
            },
            {
                db = "ScoreNTeleport_DunScore_FontSize",
                name = "Dungeon Highest Score Font Size",
                type = "SliderV2", 
                indent = 1,
                value = {
                    default = 22,
                    min = 5,
                    max = 25,
                    step = 0.1
                }
            },
        }
    },
    {-- PartyInfo
        tabName = "PartyInfo",
        tabList = {
            {
                db = "PartyKeyStone_Enable",
                name = "Enable",
                type = "CheckBox", 
                indent = 0,
                value = {
                    default = true,
                }
            },
            {
                db = "PartyInfo_ItemLevel",
                name = "Show Item Level",
                type = "CheckBox", 
                indent = 1,
                value = {
                    default = true,
                }
            },
            {
                db = "PartyKeyStone_ScoreColorStyle",
                name = "Score Text Color Style",
                type = "ComboBoxV2", 
                indent = 1,
                value = {
                    default = "raiderio",
                    list = {["raiderio"] = "RaiderIO Style", ["standard"] = "Standard Style"}
                }
            },
            {
                db = "PartyInfo_Width",
                name = "PartyInfo Width",
                type = "SliderV2", 
                indent = 1,
                value = {
                    default = 265,
                    min = 250,
                    max = 350,
                    step = 1
                }
            },
            {
                db = "PartyKeyStone_xOffset",
                name = "X Offset",
                type = "SliderV2", 
                indent = 1,
                value = {
                    default = 0.0,
                    min = -200.0,
                    max = 200.0,
                    step = 0.1
                }
            },
            {
                db = "PartyKeyStone_yOffset",
                name = "Y Offset",
                type = "SliderV2", 
                indent = 1,
                value = {
                    default = 0.0,
                    min = -200.0,
                    max = 200.0,
                    step = 0.1
                }
            }
        }
    },
    {-- Weekly Report
        tabName = "WeeklyReport",
        tabList = {
            {
                db = "WeeklyReport_Enable",
                name = "Enable",
                type = "CheckBox", 
                indent = 0,
                value = {
                    default = true,
                }
            },
            {
                db = "WeeklyReport_ShowScrollBar",
                name = "Show Scroll Bar",
                type = "CheckBox", 
                indent = 1,
                value = {
                    default = true,
                }
            },
            {
                db = "WeeklyReport_FrameStyle",
                name = "Weekly Report Style",
                type = "ComboBoxV2", 
                indent = 1,
                value = {
                    default = "accordion",
                    --list = {["accordion"] = "Accordion Style", ["standard"] = "Standard Style"}
                    list = {["standard"] = "Standard Style"}
                    ,multiSelect = false
                }
            },
            {
                db = "WeeklyReport_HideRaiderIOFrame",
                name = "Hide RaiderIO Frame When Mythic+ Page Opens.",
                type = "CheckBox", 
                indent = 1,
                value = {
                    default = true,
                }
            },
            {
                db = "WeeklyReport_ShowWeeklyTOP8",
                name = "Show Weekly Top8 Report",
                type = "CheckBox", 
                indent = 1,
                value = {
                    default = true,
                }
            },
            {
                db = "WeeklyReport_FontSize",
                name = "Weekly Report Font Size",
                type = "SliderV2", 
                indent = 1,
                value = {
                    default = 15,
                    min = 5,
                    max = 25,
                    step = 0.1
                }
            },
            {
                db = "WeeklyReport_FrameWidth",
                name = "Weekly Report Frame Width",
                type = "SliderV2", 
                indent = 1,
                value = {
                    default = 400,
                    min = 300,
                    max = 800,
                    step = 1
                }
            },
            {
                db = "WeeklyReport_FrameHeightCorrection",
                name = "Weekly Report Frame Height Correction(Fix misalignment and height discrepancies caused by UI scaling.)",
                type = "SliderV2", 
                indent = 1,
                value = {
                    default = 0,
                    min = -2.00,
                    max = 2.00,
                    step = 0.01
                }
            },
        }
    },
    {-- Extras
        tabName = "Extras",
        tabList = {
            {
                db = "ToastQuickHide_Enable", --EventToastManagerFrame
                name = "Quickly hide event notifications in dungeons, such as Respawn Point Unlocked",
                type = "CheckBox", 
                indent = 0,
                value = {
                    default = false,
                },
                -- 勾选时热启用/停用对应扩展（走统一加载管理，无需 /reload）
                onChange = function(_checked)
                    if mppe.SetExtensionEnabled then mppe.SetExtensionEnabled("ToastQuickHide", _checked) end
                end,
            },
            {
                db = "GuildAndPartyKS_Enable",
                name = "Enable guild and party keystones information (/mkeys)",
                type = "CheckBox", 
                indent = 0,
                value = {
                    default = false,
                }
            },
            {
                db = "GuildAndPartyKS_SlashKey",
                name = "↑ Allow /key command to summon",
                type = "CheckBox", 
                indent = 1,
                value = {
                    default = false,
                }
            },
            {
                db = "GuildAndPartyKS_ShowParty",
                name = "↑ Show party",
                type = "CheckBox", 
                indent = 1,
                value = {
                    default = false,
                }
            },
            {
                db = "GuildAndPartyKS_ShortDunName",
                name = "↑ Short dungeon names",
                type = "CheckBox", 
                indent = 1,
                value = {
                    default = false,
                }
            },
            {
                db = "GuildAndPartyKS_PMContent",
                name = "↑ PM Content(keystone = %s)",
                type = "TextBox", 
                indent = 1,
                value = {
                    default = Translate["Can I run your %s?"],
                }
            },
            {
                db = "GuildMemberKeystone_Show",
                name = "On Guild Member List, Show Guild Member\'s Keystone Info",
                type = "CheckBox", 
                indent = 0,
                value = {
                    default = false,
                },
                onChange = function(enabled)
                    if mppe.GuildMemberKeystone_SetEnabled then mppe.GuildMemberKeystone_SetEnabled(enabled) end
                end
            },
            {
                name = "↑Experiments: This feature is still in testing, and it is known that repeatedly opening and closing the guild member list will greatly increase this addon's memory usage. This is not a memory leak: it is because this feature \"pollutes\" the guild list, causing the game to attribute the guild UI's memory usage to this addon.",
                type = "Label", 
                indent = 0,
                lines = 4
            },
        }
    }
}
--==================================================================
-- 设置页布局常量
local SETTINGS_PAGE_WIDTH = 500   -- 设置页宽度
local SETTINGS_COLUMN_WIDTH = 400 -- 标题列基准宽度
local SETTINGS_OVERHANG_WIDTH = 600 -- 说明文字/勾选框标题的加宽基准（沿用旧布局，避免视觉回归）

-- 从数据库读取设置项的值；类型不符时回退到配置默认值
local function GetDBValue(item, expectedType, fallback)
    local _value = MythicPlusPageExtensionDB[item.db]
    if type(_value) ~= expectedType then
        _value = (type(item.value.default) == expectedType) and item.value.default or fallback
    end
    return _value
end

-- 解析下拉框最终选中键：数据库值 -> 配置默认值 -> 列表第一项
local function ResolveComboKey(item)
    if not item.value.list then return nil end
    local _dbValue = MythicPlusPageExtensionDB[item.db]
    if _dbValue and item.value.list[_dbValue] then return _dbValue end
    local _default = item.value.default
    if _default and item.value.list[_default] then return _default end
    return next(item.value.list)
end

-- 创建通用的设置项标题文本（parent 为标签页，top 为相对顶部的偏移量）
local function CreateItemTitle(parent, text, leftmargin, top, width, layer)
    local _title = parent:CreateFontString(nil, layer or "ARTWORK", "GameFontHighlightSmall")
    _title:SetPoint("TOPLEFT", leftmargin, top)
    _title:SetText(text)
    _title:SetHeight(32)
    _title:SetWidth(width)
    _title:SetJustifyH("LEFT")
    _title:SetJustifyV("MIDDLE")
    return _title
end

-- 创建滑块的步进按钮（+/-），点击使滑块增减 delta
local function CreateStepButton(parent, slider, dbKey, delta, atlas)
    local _suffix = delta > 0 and "Plus" or "Minus"
    local _btn = CreateFrame("Button", "MPPE_Setting_"..dbKey.."_".._suffix, parent)
    _btn:SetSize(10, 10)
    if delta > 0 then
        _btn:SetPoint("LEFT", slider, "RIGHT", 1, 0)
    else
        _btn:SetPoint("RIGHT", slider, "LEFT", -1, 0)
    end
    _btn.Icon = _btn:CreateTexture(nil, "OVERLAY")
    _btn.Icon:SetAllPoints()
    _btn.Icon:SetAtlas(atlas)
    _btn:SetScript("OnEnter", function(self) self.Icon:SetVertexColor(1, 0.5, 0) end)
    _btn:SetScript("OnLeave", function(self) self.Icon:SetVertexColor(1, 1, 1) end)
    _btn:SetScript("OnClick", function() slider:SetValue(slider:GetValue() + delta) end)
    return _btn
end

-- 构建"说明文字"设置项
local function BuildLabel(parent, item, itemName, leftmargin, tabHeight)
    local _label = parent:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    _label:SetText(itemName)
    _label:SetPoint("TOPLEFT", parent, "TOPLEFT", leftmargin, -tabHeight)
    _label:SetSize(SETTINGS_OVERHANG_WIDTH - 12, (item.lines and item.lines or 1) * 15)
    _label:SetJustifyH("LEFT")
    _label:SetJustifyV("TOP")
    return tabHeight + _label:GetHeight() + 10
end

-- 构建"勾选框"设置项
local function BuildCheckBox(parent, item, itemName, leftmargin, tabHeight)
    local _title = CreateItemTitle(parent, itemName, leftmargin + 24, -tabHeight - 5, SETTINGS_OVERHANG_WIDTH - 36, "OVERLAY")
    local _checkBox = CreateFrame("CheckButton", "MPPE_Setting_"..item.db, parent, "ChatConfigCheckButtonTemplate")
    _checkBox:SetSize(24, 24)
    _checkBox:SetPoint("RIGHT", _title, "LEFT", 0, 0)
    _checkBox:SetChecked(GetDBValue(item, "boolean", false))
    _checkBox:SetScript("OnClick", function(self)
        MythicPlusPageExtensionDB[item.db] = self:GetChecked()
        -- 支持设置项级联回调（如 Toast 快速隐藏的热注册）
        if item.onChange then item.onChange(self:GetChecked()) end
    end)
    return tabHeight + _checkBox:GetHeight() + 10 + 12
end

-- 构建"滑块"设置项
local function BuildSlider(parent, item, itemName, leftmargin, tabHeight)
    local _title = CreateItemTitle(parent, itemName, leftmargin, -tabHeight - 5, SETTINGS_COLUMN_WIDTH - leftmargin)
    local _slider = CreateFrame("Slider", "MPPE_Setting_"..item.db, parent, "OptionsSliderTemplate")
    _slider:SetSize(180, 17)
    _slider:SetPoint("LEFT", _title, "RIGHT", 15, 0)
    _slider:SetMinMaxValues(item.value.min or 0, item.value.max or 100)
    _slider.Low:SetText(item.value.min or 0)
    _slider.High:SetText(item.value.max or 100)

    if type(item.value.step) ~= "number" or item.value.step <= 0 then item.value.step = 1 end
    _slider:SetValueStep(item.value.step)
    local _str = tostring(mppe.MathRound(item.value.step, 3))
    local _dec = _str:match("%.(%d+)")
    local _decimalPlace = _dec and math.min(#_dec, 3) or 0

    _slider:SetValue(GetDBValue(item, "number", 50))
    _slider.Text:SetText(mppe.MathRound(_slider:GetValue(), _decimalPlace))
    _slider:SetScript("OnValueChanged", function(self, value)
        self.Text:SetText(mppe.MathRound(value, _decimalPlace))
        MythicPlusPageExtensionDB[item.db] = mppe.MathRound(value, _decimalPlace)
    end)

    CreateStepButton(parent, _slider, item.db, item.value.step, "common-icon-plus")
    CreateStepButton(parent, _slider, item.db, -item.value.step, "common-icon-minus")
    return tabHeight + _title:GetHeight() + 20
end

-- 构建"滑块"设置项 V2（使用现代 MinimalSliderWithSteppersTemplate，自带 +/- 步进按钮）
local function BuildSliderV2(parent, item, itemName, leftmargin, tabHeight)
    local _title = CreateItemTitle(parent, itemName, leftmargin, -tabHeight - 5, SETTINGS_COLUMN_WIDTH - leftmargin)
    local _slider = CreateFrame("Slider", "MPPE_Setting_"..item.db.."_V2", parent, "MinimalSliderWithSteppersTemplate")
    _slider:SetSize(220, 40)
    _slider:SetPoint("LEFT", _title, "RIGHT", 0, 0)

    -- 模板为容器形态（Frame + 子 Slider）时取子 Slider 作为真正的滑条，否则直接用自身
    local _real = _slider.Slider or _slider
    _real:SetMinMaxValues(item.value.min or 0, item.value.max or 100)
    if type(item.value.step) ~= "number" or item.value.step <= 0 then item.value.step = 1 end
    _real:SetValueStep(item.value.step)
    _real:SetObeyStepOnDrag(true)

    local _str = tostring(mppe.MathRound(item.value.step, 3))
    local _dec = _str:match("%.(%d+)")
    local _decimalPlace = _dec and math.min(#_dec, 3) or 0

    -- 显示最小/最大值标签（模板 MinText/MaxText 默认隐藏，需 Show）
    if _slider.MinText then _slider.MinText:SetText(item.value.min or 0) _slider.MinText:Show() end
    if _slider.MaxText then _slider.MaxText:SetText(item.value.max or 100) _slider.MaxText:Show() end

    -- 当前数值显示在滑条上方（模板 TopText 默认隐藏，与 BuildSlider 的 Text 一致显示在顶部）
    local _valueLabel = _slider.TopText
    _real:SetValue(GetDBValue(item, "number", 50))
    if _valueLabel then
        _valueLabel:SetText(mppe.MathRound(_real:GetValue(), _decimalPlace))
        _valueLabel:Show()
    end
    _real:SetScript("OnValueChanged", function(self, value)
        if _valueLabel then _valueLabel:SetText(mppe.MathRound(value, _decimalPlace)) end
        MythicPlusPageExtensionDB[item.db] = mppe.MathRound(value, _decimalPlace)
        if item.onChange then item.onChange(mppe.MathRound(value, _decimalPlace)) end
    end)
    return tabHeight + _title:GetHeight() + 20
end

-- 构建"下拉框"设置项
local function BuildComboBox(parent, item, itemName, leftmargin, tabHeight)
    local _title = CreateItemTitle(parent, itemName, leftmargin, -tabHeight, SETTINGS_COLUMN_WIDTH - leftmargin)
    local _comboBox = CreateFrame("Frame", "MPPE_Setting_"..item.db, parent, "UIDropDownMenuTemplate")
    _comboBox:SetSize(165, 32)
    _comboBox:SetPoint("LEFT", _title, "RIGHT", -5, 0)
    UIDropDownMenu_SetWidth(_comboBox, 175)

    -- 下拉菜单初始化（UIDropDownMenu 会传入多余参数，忽略即可）
    local function initializeDropDown()
        local _info = UIDropDownMenu_CreateInfo()
        local _currentValue = MythicPlusPageExtensionDB[item.db]
        for _key, _displayText in pairs(item.value.list or {}) do
            _info.text = "  "..(Translate[_displayText] or _key)
            _info.value = _key
            _info.checked = (_currentValue == _key)
            _info.func = function(button)
                UIDropDownMenu_SetSelectedValue(_comboBox, button.value)
                UIDropDownMenu_SetText(_comboBox, button:GetText())
                MythicPlusPageExtensionDB[item.db] = button.value
                CloseDropDownMenus()
            end
            UIDropDownMenu_AddButton(_info)
        end
    end
    UIDropDownMenu_Initialize(_comboBox, initializeDropDown)

    -- 应用最终选中键（修复：旧代码 ipairs 在首个 nil 处中断，导致默认值被跳过的 bug）
    local _finalKey = ResolveComboKey(item)
    if _finalKey then
        UIDropDownMenu_SetText(_comboBox, Translate[item.value.list[_finalKey]] or item.value.list[_finalKey])
        UIDropDownMenu_SetSelectedValue(_comboBox, _finalKey)
        MythicPlusPageExtensionDB[item.db] = _finalKey
    else
        UIDropDownMenu_SetText(_comboBox, "- WRONG -")
    end
    return tabHeight + _title:GetHeight() + 10
end

-- 构建"下拉框"设置项 V3（完全自实现，不依赖 Settings 全局方法；仅用 Menu 框架通用 API 还原原生设置下拉观感）
local function BuildComboBoxV2(parent, item, itemName, leftmargin, tabHeight)
    local _title = CreateItemTitle(parent, itemName, leftmargin, -tabHeight, SETTINGS_COLUMN_WIDTH - leftmargin)
    -- 原生设置下拉使用 WowStyle2DropdownTemplate（common-dropdown-c-button 深色按钮，悬停显示箭头）
    local _comboBox = CreateFrame("DropdownButton", "MPPE_Setting_"..item.db.."_V3", parent, "WowStyle2DropdownTemplate")
    _comboBox:SetSize(205, 24)
    _comboBox:SetPoint("LEFT", _title, "RIGHT", 5, 0)

    local _isMulti = item.value.multiSelect == true
    local _list = item.value.list or {}

    -- 自实现的选项数据容器（等价于 Settings.CreateControlTextContainer）
    -- 每条：{ value, label, text, controlType = "Radio"/"Checkbox" }
    local _optionsData = {}
    local _keys = {}
    for _k in pairs(_list) do _keys[#_keys + 1] = _k end
    table.sort(_keys)
    for _index, _key in ipairs(_keys) do
        local _label = Translate[_list[_key]] or _list[_key]
        _optionsData[#_optionsData + 1] = {
            value = _isMulti and _index or _key, -- 多选用稳定索引（位掩码），单选用原始 key
            label = _label,
            text = _label,
            controlType = _isMulti and "Checkbox" or "Radio",
        }
    end

    -- 自实现菜单生成器（等价于 Settings.CreateDropdownOptionInserter，直接调用 Menu 框架 API）
    _comboBox:SetupMenu(function(dropdown, rootDescription)
        rootDescription:SetGridMode(MenuConstants.VerticalGridDirection)
        for _, _option in ipairs(_optionsData) do
            if _option.controlType == "Radio" then
                -- 单选：原生设置用 CreateHighlightRadio（高亮菜单项，匹配 WowStyle2 观感）
                local function isSelected(_data)
                    return MythicPlusPageExtensionDB[item.db] == _data.value
                end
                local function setSelected(_data)
                    MythicPlusPageExtensionDB[item.db] = _data.value
                    if item.onChange then item.onChange(_data.value) end
                end
                local _desc = rootDescription:CreateHighlightRadio(_option.label, isSelected, setSelected, _option, _option.onEnter)
                MenuUtil.SetElementText(_desc, _option.text)
            else
                -- 多选：DB 存位掩码，bit.lshift(1, value-1) 对应一个选项
                local _bit = bit.lshift(1, _option.value - 1)
                local function isChecked()
                    local _mask = MythicPlusPageExtensionDB[item.db]
                    return type(_mask) == "number" and bit.band(_mask, _bit) ~= 0
                end
                local function setChecked()
                    local _mask = type(MythicPlusPageExtensionDB[item.db]) == "number" and MythicPlusPageExtensionDB[item.db] or 0
                    local _newMask = isChecked() and bit.band(_mask, bit.bnot(_bit)) or bit.bor(_mask, _bit)
                    MythicPlusPageExtensionDB[item.db] = _newMask
                    if item.onChange then item.onChange(_newMask) end
                end
                local _desc = rootDescription:CreateCheckbox(_option.label, isChecked, setChecked, _option)
                MenuUtil.SetElementText(_desc, _option.text)
            end
        end
    end)

    -- 应用最终选中键（复用旧逻辑：DB 值 -> 默认值 -> 列表第一项）
    local _finalKey = ResolveComboKey(item)
    if _isMulti then
        -- 多选：DB 必须是数字位掩码，无选中时显示 "None"
        if type(MythicPlusPageExtensionDB[item.db]) ~= "number" then MythicPlusPageExtensionDB[item.db] = 0 end
        _comboBox:SetDefaultText("None")
    elseif _finalKey then
        _comboBox:SetDefaultText(Translate[_list[_finalKey]] or _list[_finalKey])
        MythicPlusPageExtensionDB[item.db] = _finalKey
    else
        _comboBox:SetDefaultText("- WRONG -")
    end

    return tabHeight + _title:GetHeight() + 10
end

-- 构建"文本输入"设置项
local function BuildTextBox(parent, item, itemName, leftmargin, tabHeight)
    local _title = CreateItemTitle(parent, itemName, leftmargin, -tabHeight, SETTINGS_COLUMN_WIDTH - leftmargin)
    local _textBox = CreateFrame("EditBox", "MPPE_Setting_"..item.db, parent, "InputBoxTemplate")
    _textBox:SetSize(185, 32)
    _textBox:SetAutoFocus(false)
    _textBox:SetPoint("LEFT", _title, "RIGHT", 15, 0)
    -- 非字符串视为未设置，回退到配置默认值（避免 DB 历史空串导致默认值不生效）
    local _textValue = MythicPlusPageExtensionDB[item.db]
    if type(_textValue) ~= "string" then _textValue = item.value.default or "" end
    _textBox:SetText(_textValue)
    _textBox:SetScript("OnTextChanged", function(self)
        MythicPlusPageExtensionDB[item.db] = self:GetText()
    end)
    -- 回车后取消编辑焦点（DB 已在 OnTextChanged 中实时保存，无需在此重复提交）
    _textBox:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    return tabHeight + _title:GetHeight() + 20
end

-- 设置项构建器分发表：控件类型 -> 构建函数
local widgetBuilders = {
    Label = BuildLabel,
    CheckBox = BuildCheckBox,
    Slider = BuildSlider,
    SliderV2 = BuildSliderV2,
    ComboBoxV2 = BuildComboBox,
    ComboBoxV2 = BuildComboBoxV2,
    ComboBoxV3 = BuildComboBoxV3,
    TextBox = BuildTextBox,
}

-- 按容器宽度均分标签按钮宽度（预留新增 tab 的空间，防止溢出）
local function LayoutTabButtons()
    local _count = #settings_Tabs.tabs
    if _count == 0 then return end
    local _avail = (settings_Tabs.tabButtons:GetWidth() or 550) - 20 - (_count - 1) * 3
    if _avail < 50 then _avail = 50 end
    local _width = math.floor(_avail / _count)
    for _i = 1, _count do
        settings_Tabs.tabs[_i].button:SetWidth(_width)
    end
end

-- 创建标签页内容（遍历 SettingsList 构建各标签页）
function settings_Tabs:CreateTabContext()
    for _tabIndex, _tabCfg in ipairs(settings_Tabs.SettingsList) do
        local _tabName = Translate[_tabCfg.tabName] or ("TabPage_"..tostring(_tabIndex))
        local _tabPage = CreateFrame("Frame", "MPPE_SettingsTabPage_"..tostring(_tabIndex))
        _tabPage:SetWidth(SETTINGS_PAGE_WIDTH)

        local _tabHeight = 5
        for _itemIndex, _item in ipairs(_tabCfg.tabList) do
            local _itemName = Translate[_item.name] or _item.name or "Item_"..tostring(_itemIndex)
            local _leftmargin = 5 + (type(_item.indent) == "number" and _item.indent or 0) * 20
            local _builder = widgetBuilders[_item.type]
            if _builder then
                _tabHeight = _builder(_tabPage, _item, _itemName, _leftmargin, _tabHeight)
            end
        end
        _tabPage:SetHeight(_tabHeight)
        settings_Tabs:CreateTab(_tabName, _tabPage)
    end
    LayoutTabButtons()
end

--==================================================================
-- 初始化设置函数
local _initTimes = 0
local _retrying = false -- 是否已有重试链在调度中（避免 OnShow 与 C_Timer 双入口并发轮询）
local function InitializeSettings()
    if _retrying then return end
    if _initTimes > 500 then
        print(string.format("|cffff0000MPPE Settings: %s|r", Translate['SavedVariables failed to load. Critical plugin error! Please check for updates!']))
        return
    end
    if not IsDBLoaded() then
        if _initTimes % 100 == 0 then
            print(string.format("|cffff0000MPPE Settings: |r%s", Translate['SavedVariables not loaded, initializing lazily.']))
        end
        _initTimes = _initTimes + 1
        _retrying = true
        C_Timer.After(0.1, function()
            _retrying = false
            InitializeSettings()
        end)
        return
    end
    if not settingsInitialized then
        settings_Tabs:CreateTabContext()
        settings_Tabs:SetTab(1)
        settingsInitialized = true
    end

    -- 旧版SavedVariables数据迁移表：oldKey -> newKey
    local DB_MIGRATIONS = {
        DunNameSize = "ScoreNTeleport_DunShortName_FontSize",
        DunNamePerLine = "ScoreNTeleport_DunShortName_PerLine",
        DunLevelSize = "ScoreNTeleport_DunLevel_FontSize",
        DunScoreSize = "ScoreNTeleport_DunScore_FontSize",
        HideRaiderIOFrame = "WeeklyReport_HideRaiderIOFrame",
        WeeklyReportSize = "WeeklyReport_FontSize",
        WeeklyReportWidth = "WeeklyReport_FrameWidth",
        ScoreNTeleport_STI_CastStatu = "ScoreNTeleport_STI_CastStatus", -- 修正拼写迁移
    }
    for _oldKey, _newKey in pairs(DB_MIGRATIONS) do
        if MythicPlusPageExtensionDB[_oldKey] then
            MythicPlusPageExtensionDB[_newKey] = MythicPlusPageExtensionDB[_oldKey]
            MythicPlusPageExtensionDB[_oldKey] = nil
        end
    end
    -- HideMainFrame 语义特殊：旧版"隐藏主框架"等价于关闭周报
    if MythicPlusPageExtensionDB.HideMainFrame then
        MythicPlusPageExtensionDB.WeeklyReport_Enable = false
        MythicPlusPageExtensionDB.HideMainFrame = nil
    end
end

mppe_sFrame:SetScript("OnShow", function(self)
    line_sTop:SetSize(mppe_sFrame:GetWidth()-15,1)
    line_sBottom:SetSize(line_sTop:GetSize())
    settings_Tabs.tabButtons:SetWidth(mppe_sFrame:GetWidth())
    settings_Tabs:SetWidth(mppe_sFrame:GetWidth())
    settings_Tabs.content:SetWidth(settings_Tabs:GetWidth() - 20)

    if not settingsInitialized then InitializeSettings() end
    LayoutTabButtons()
end)

C_Timer.After(1, function()
    if not settingsInitialized then InitializeSettings() end
end)
--==================================================================
local category = Settings.RegisterCanvasLayoutCategory(mppe_sFrame, "MPPE");
Settings.RegisterAddOnCategory(category)

function mppe.SettingsShow() 
    if UnitAffectingCombat("player") then
        print(string.format("%s%s","[MPPE]", Translate['Settings cannot be opened by command in combat.']))
        return
    end
    Settings.OpenToCategory(category.ID) 
end

-- 斜杠命令：/mppe 显示设置；/mkeys 切换钥石窗口；/mkeys test 测试模式；/mkeys debug 调试（rawset 避免分析器误报重复定义）
rawset(SlashCmdList, "MPPE", function(msg)
    Settings.OpenToCategory(category.ID)
end)
SLASH_MPPE1 = "/mppe"

-- GuildAndPartyKS 扩展的斜杠命令：/mkeys 切换钥石窗口；/mkeys test 测试模式；/mkeys debug 调试
rawset(SlashCmdList, "MKEYS", function(msg)
    -- 子命令解析已收敛到 GuildAndPartyKS_Open 内，此处仅透传命令参数
    mppe.GuildAndPartyKS_Open(msg)
end)
SLASH_MKEYS1 = "/mkeys"
rawset(SlashCmdList, "KEY", function(msg)
    if not (MythicPlusPageExtensionDB and MythicPlusPageExtensionDB.GuildAndPartyKS_SlashKey) then
        return
    end
    mppe.GuildAndPartyKS_Open(msg)
end)
SLASH_KEY1 = "/key"