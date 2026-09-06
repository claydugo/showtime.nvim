local M = {}

---@class showtime.Config
---@field delay number Milliseconds before highlighting (0 = immediate)
---@field hl_group string Highlight group name for references
---@field max_matches number Safety cap on extmarks per cycle
---@field min_matches number Minimum references required to highlight
---@field exclude_languages string[] Treesitter language names to skip
---@field exclude_buftypes string[] Buffer types to skip
---@field scope_nodes table<string, table<string, boolean>>? Per-language scope node overrides
---@field _lang_set table<string, boolean> Internal set for O(1) language lookup
---@field _bt_set table<string, boolean> Internal set for O(1) buftype lookup

---@type showtime.Config
local DEFAULTS = {
    delay = 0,
    hl_group = "ShowtimeReference",
    max_matches = 500,
    min_matches = 2,
    exclude_languages = {},
    exclude_buftypes = { "nofile", "terminal", "prompt" },
}

--- Build a hash set from an array of strings.
---@param list string[]
---@return table<string, boolean>
local function to_set(list)
    local s = {}
    for _, v in ipairs(list) do
        s[v] = true
    end
    return s
end

--- Attach derived set fields to the options table.
local function rebuild_sets()
    M.options._lang_set = to_set(M.options.exclude_languages)
    M.options._bt_set = to_set(M.options.exclude_buftypes)
end

---@type showtime.Config
M.options = vim.deepcopy(DEFAULTS)
M.revision = 0
rebuild_sets()

--- Merge user options into config with validation.
---@param user_options showtime.Config?
function M.setup(user_options)
    user_options = vim.deepcopy(user_options or {})

    -- Type validation: warn and bail on failure, keeping previous config.
    local ok, err = pcall(function()
        vim.validate("options", user_options, "table")
        vim.validate("delay", user_options.delay, "number", true)
        vim.validate("hl_group", user_options.hl_group, "string", true)
        vim.validate("max_matches", user_options.max_matches, "number", true)
        vim.validate("min_matches", user_options.min_matches, "number", true)
        vim.validate("exclude_languages", user_options.exclude_languages, "table", true)
        vim.validate("exclude_buftypes", user_options.exclude_buftypes, "table", true)
        vim.validate("scope_nodes", user_options.scope_nodes, "table", true)
        if user_options.scope_nodes then
            for lang, nodes in pairs(user_options.scope_nodes) do
                vim.validate("scope_nodes[" .. tostring(lang) .. "]", nodes, "table")
                for node_type, val in pairs(nodes) do
                    vim.validate("scope_nodes[" .. tostring(lang) .. "][" .. tostring(node_type) .. "]", val, "boolean")
                end
            end
        end
    end)
    if not ok then
        vim.notify("showtime.setup(): " .. tostring(err), vim.log.levels.WARN)
        return false
    end

    -- Warn and strip unknown keys (likely typos).
    --- Known config keys come from defaults. The optional scope_nodes key
    --- has no default value and requires an explicit check when
    --- iterating user options.
    for k in pairs(user_options) do
        if DEFAULTS[k] == nil and k ~= "scope_nodes" then
            vim.notify("showtime.setup(): unknown option '" .. k .. "' (ignored)", vim.log.levels.WARN)
            user_options[k] = nil
        end
    end

    -- Semantic validation: warn and clamp invalid values.
    if user_options.delay and user_options.delay < 0 then
        vim.notify("showtime.setup(): delay must be >= 0, clamping to 0", vim.log.levels.WARN)
        user_options.delay = 0
    end
    if user_options.max_matches and user_options.max_matches <= 0 then
        vim.notify("showtime.setup(): max_matches must be > 0, clamping to 1", vim.log.levels.WARN)
        user_options.max_matches = 1
    end
    if user_options.min_matches and user_options.min_matches < 1 then
        vim.notify("showtime.setup(): min_matches must be >= 1, clamping to 1", vim.log.levels.WARN)
        user_options.min_matches = 1
    end
    if user_options.hl_group and user_options.hl_group == "" then
        vim.notify("showtime.setup(): hl_group must not be empty, using default", vim.log.levels.WARN)
        user_options.hl_group = nil
    end

    -- Merge from clean defaults.
    local options = vim.tbl_extend("force", vim.deepcopy(DEFAULTS), user_options)
    for key in pairs(M.options) do
        M.options[key] = nil
    end
    for key, value in pairs(options) do
        M.options[key] = value
    end

    rebuild_sets()
    M.revision = M.revision + 1
    return true
end

return M
