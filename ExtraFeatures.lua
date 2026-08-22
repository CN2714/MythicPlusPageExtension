local ADDON_NAME, mppe = ...
local Translate = mppe.Translate

-- =================================================================
-- 扩展功能统一加载管理器：各扩展通过 mppe.RegisterExtension 注册启用/停用回调，
-- 由 ADDON_LOADED 统一按 DB 开关初始化；设置面板可通过 mppe.SetExtensionEnabled 热切换（无需 /reload）
-- =================================================================
local ExtraFeatures = {} -- [扩展key] = { dbKey, label, onEnable, onDisable }

-- 注册一个扩展功能（key 唯一；cfg.dbKey 为 DB 开关字段；onEnable/onDisable 为启用/停用回调）
function mppe.RegisterExtension(key, cfg)
    if not key or not cfg or type(cfg) ~= "table" then return end
    ExtraFeatures[key] = cfg
end

-- 按开关启用/停用某扩展（设置面板 onChange 调用，支持热切换）
function mppe.SetExtensionEnabled(key, enable)
    local _cfg = ExtraFeatures[key]
    if not _cfg then return end
    if enable and _cfg.onEnable then
        _cfg.onEnable()
    elseif not enable and _cfg.onDisable then
        _cfg.onDisable()
    end
end

-- 主文件 ADDON_LOADED 完成 DB 默认值填充后，统一按 DB 开关初始化所有已注册扩展
local _initFrame = CreateFrame("Frame")
_initFrame:RegisterEvent("ADDON_LOADED")
_initFrame:SetScript("OnEvent", function(self, _event, _addonName)
    if _addonName ~= ADDON_NAME then return end
    self:UnregisterEvent("ADDON_LOADED")
    for _key, _cfg in pairs(ExtraFeatures) do
        local _bOn = _cfg.dbKey and MythicPlusPageExtensionDB and MythicPlusPageExtensionDB[_cfg.dbKey]
        if _bOn then
            if _cfg.onEnable then _cfg.onEnable() end
            -- if _cfg.label then print(_cfg.label .. " " .. (Translate["Enabled"] or "Enabled")) end
        elseif _cfg.onDisable then
            _cfg.onDisable()
        end
    end
end)

-- =================================================================
-- 扩展1：Toast 快速隐藏（副本内 0.5 秒后自动隐藏“事件通知”，如“解锁重生点”)
-- =================================================================
local _toastHooked = false
local function _hideToast()
    if EventToastManagerFrame:IsShown() and IsInInstance() then
        C_Timer.After(0.5, function() EventToastManagerFrame:Hide() end)
    end
end

mppe.RegisterExtension("ToastQuickHide", {
    dbKey = "ToastQuickHide_Enable",
    label = Translate["ToastQuickHide_Enable"],
    onEnable = function()
        if not _toastHooked then
            EventToastManagerFrame:HookScript("OnShow", _hideToast)
            _toastHooked = true
        end
    end,
    onDisable = function()
        if _toastHooked then
            EventToastManagerFrame:UnhookScript("OnShow", _hideToast)
            _toastHooked = false
        end
    end,
})
