--[[
    pluginlauncher.koplugin / main.lua

    Hamburger menu:  More Tools → Plugin Launcher → Launch / Settings
    Quick action:    plugin_key = "pluginlauncher", plugin_method = "open"

    Launch  → full-screen page listing your chosen plugins
    Settings → add / remove / reorder via native sub-menus (no TouchMenu)
--]]

local DataStorage    = require("datastorage")
local InfoMessage    = require("ui/widget/infomessage")
local InputContainer = require("ui/widget/container/inputcontainer")
local LuaSettings    = require("luasettings")
local Menu           = require("ui/widget/menu")
local UIManager      = require("ui/uimanager")
local lfs            = require("libs/libkoreader-lfs")
local logger         = require("logger")
local _              = require("gettext")

local PluginLauncher = InputContainer:extend{
    name        = "pluginlauncher",
    fullname    = "Plugin Launcher",
    is_doc_only = false,
}

-- ── Config ─────────────────────────────────────────────────────────────────

local SETTINGS_FILE = DataStorage:getSettingsDir() .. "/pluginlauncher.lua"

function PluginLauncher:cfg()
    if not self._cfg then
        self._cfg = LuaSettings:open(SETTINGS_FILE)
    end
    return self._cfg
end

function PluginLauncher:getList()
    return self:cfg():readSetting("plugins") or {}
end

function PluginLauncher:saveList(list)
    self:cfg():saveSetting("plugins", list)
    self:cfg():flush()
end

-- ── Plugin discovery ───────────────────────────────────────────────────────

function PluginLauncher:_scanPlugins()
    local found, seen = {}, {}
    local dirs = {
        "plugins",
        DataStorage:getDataDir() .. "/plugins",
    }
    for _, dir in ipairs(dirs) do
        if lfs.attributes(dir, "mode") == "directory" then
            for entry in lfs.dir(dir) do
                -- Skip anything starting with a dot (handles ., .., ._xxx)
                if entry:sub(1, 1) ~= "." and entry:match("%.koplugin$") then
                    local pname = entry:gsub("%.koplugin$", "")
                    if pname ~= "pluginlauncher" and not seen[pname] then
                        seen[pname] = true
                        local fullname = pname
                        local metafile = dir .. "/" .. entry .. "/_meta.lua"
                        local ok, meta = pcall(dofile, metafile)
                        if ok and type(meta) == "table" and meta.fullname then
                            fullname = meta.fullname
                        end
                        table.insert(found, { name = pname, fullname = fullname })
                    end
                end
            end
        end
    end
    table.sort(found, function(a, b)
        return a.fullname:lower() < b.fullname:lower()
    end)
    return found
end

-- ── Plugin launch ──────────────────────────────────────────────────────────

function PluginLauncher:_launch(plugin_name)
    -- Close the launcher page before opening anything
    if self._launcher_page then
        UIManager:close(self._launcher_page)
        self._launcher_page = nil
    end

    local p = self.ui[plugin_name]
    if not p then
        UIManager:show(InfoMessage:new{
            text    = plugin_name .. " is not loaded",
            timeout = 2,
        })
        return
    end

    -- Most reliable: call the same callback the hamburger menu uses.
    -- Every plugin that has a UI entry point exposes it via addToMainMenu.
    if type(p.addToMainMenu) == "function" then
        local menu_items = {}
        local ok, err = pcall(p.addToMainMenu, p, menu_items)
        if ok then
            for _, item in pairs(menu_items) do
                if type(item) == "table" and type(item.callback) == "function" then
                    pcall(item.callback)
                    return
                end
            end
        else
            logger.warn("PluginLauncher: addToMainMenu failed for " .. plugin_name .. ": " .. tostring(err))
        end
    end

    -- Fallback: try common method names
    for _, method in ipairs{ "startGame", "start", "onShowMenu", "showMenu", "show", "launch" } do
        if type(p[method]) == "function" then
            pcall(p[method], p)
            return
        end
    end

    UIManager:show(InfoMessage:new{
        text    = "Could not launch: " .. plugin_name,
        timeout = 2,
    })
end

-- ── Full-screen launcher page (called by quick action) ─────────────────────

function PluginLauncher:open()
    local list = self:getList()
    if #list == 0 then
        UIManager:show(InfoMessage:new{
            text    = "No plugins configured.\nGo to: More Tools > Plugin Launcher > Settings",
            timeout = 3,
        })
        return
    end

    local item_table = {}
    for _, entry in ipairs(list) do
        local pname     = entry.name
        local pfullname = entry.fullname or entry.name
        table.insert(item_table, {
            text     = pfullname,
            callback = function()
                self:_launch(pname)
            end,
        })
    end

    self._launcher_page = Menu:new{
        title          = "Games & Apps",
        full_screen    = true,
        item_table     = item_table,
        close_callback = function()
            self._launcher_page = nil
        end,
    }
    UIManager:show(self._launcher_page)
end

-- ── Init & hamburger menu ──────────────────────────────────────────────────

function PluginLauncher:init()
    self.ui.menu:registerToMainMenu(self)
end

function PluginLauncher:addToMainMenu(menu_items)
    menu_items.pluginlauncher = {
        text         = "Plugin Launcher",
        sorting_hint = "more_tools",
        sub_item_table = {
            {
                text     = "Launch",
                callback = function() self:open() end,
            },
            {
                text                = "Settings",
                sub_item_table_func = function()
                    return self:_buildSettingsMenu()
                end,
            },
        },
    }
end

-- ── Settings ───────────────────────────────────────────────────────────────

function PluginLauncher:_buildSettingsMenu()
    local list  = self:getList()
    local items = {}

    if #list == 0 then
        table.insert(items, {
            text         = "(no plugins added yet — tap Add plugin below)",
            enabled_func = function() return false end,
            callback     = function() end,
        })
    end

    for i, entry in ipairs(list) do
        local idx = i
        table.insert(items, {
            text          = entry.fullname or entry.name,
            -- Tap: nothing (visual only)
            callback      = function() end,
            -- Hold: remove
            hold_callback = function()
                local l = self:getList()
                table.remove(l, idx)
                self:saveList(l)
                UIManager:show(InfoMessage:new{
                    text    = (entry.fullname or entry.name) .. " removed",
                    timeout = 2,
                })
            end,
        })
    end

    table.insert(items, {
        text         = "---",
        enabled_func = function() return false end,
        callback     = function() end,
    })
    table.insert(items, {
        text                = "Add plugin...",
        sub_item_table_func = function() return self:_buildAddMenu() end,
    })
    if #list > 1 then
        table.insert(items, {
            text                = "Reorder...",
            sub_item_table_func = function() return self:_buildReorderMenu() end,
        })
    end

    return items
end

function PluginLauncher:_buildAddMenu()
    local all     = self:_scanPlugins()
    local list    = self:getList()
    local already = {}
    for _, e in ipairs(list) do already[e.name] = true end

    local items = {}
    for _, p in ipairs(all) do
        local pname, pfullname = p.name, p.fullname
        if already[pname] then
            table.insert(items, {
                text         = pfullname .. " (added)",
                enabled_func = function() return false end,
                callback     = function() end,
            })
        else
            table.insert(items, {
                text     = pfullname,
                callback = function()
                    local l = self:getList()
                    table.insert(l, { name = pname, fullname = pfullname })
                    self:saveList(l)
                    UIManager:show(InfoMessage:new{
                        text    = pfullname .. " added",
                        timeout = 2,
                    })
                end,
            })
        end
    end

    if #items == 0 then
        table.insert(items, {
            text         = "(no plugins found)",
            enabled_func = function() return false end,
            callback     = function() end,
        })
    end
    return items
end

function PluginLauncher:_buildReorderMenu()
    local list  = self:getList()
    local items = {}
    for i, entry in ipairs(list) do
        local idx = i
        local sub = {}
        if idx > 1 then
            table.insert(sub, {
                text     = "Move up",
                callback = function()
                    local l = self:getList()
                    l[idx], l[idx - 1] = l[idx - 1], l[idx]
                    self:saveList(l)
                end,
            })
        end
        if idx < #list then
            table.insert(sub, {
                text     = "Move down",
                callback = function()
                    local l = self:getList()
                    l[idx], l[idx + 1] = l[idx + 1], l[idx]
                    self:saveList(l)
                end,
            })
        end
        table.insert(items, {
            text           = entry.fullname or entry.name,
            sub_item_table = sub,
        })
    end
    return items
end

return PluginLauncher
