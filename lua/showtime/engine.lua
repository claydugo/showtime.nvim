local M = {}

local ns = vim.api.nvim_create_namespace("showtime")

--- Per-language scope boundary node types (exact match).
--- User-provided scope_nodes in config are deep-merged on top of these.
local BUILTIN_SCOPE_NODES = {
    lua = {
        chunk = true,
        function_declaration = true,
        function_definition = true,
        do_block = true,
    },
    python = {
        module = true,
        function_definition = true,
        class_definition = true,
        lambda = true,
    },
    javascript = {
        program = true,
        function_declaration = true,
        function_expression = true,
        arrow_function = true,
        class_declaration = true,
        class_expression = true,
        method_definition = true,
    },
    typescript = {
        program = true,
        function_declaration = true,
        function_expression = true,
        arrow_function = true,
        class_declaration = true,
        class_expression = true,
        method_definition = true,
    },
    tsx = {
        program = true,
        function_declaration = true,
        function_expression = true,
        arrow_function = true,
        class_declaration = true,
        class_expression = true,
        method_definition = true,
        jsx_element = true,
    },
    go = {
        source_file = true,
        function_declaration = true,
        method_declaration = true,
        func_literal = true,
    },
    rust = {
        source_file = true,
        function_item = true,
        closure_expression = true,
        impl_item = true,
        trait_item = true,
        mod_item = true,
    },
    c = {
        translation_unit = true,
        function_definition = true,
    },
    cpp = {
        translation_unit = true,
        function_definition = true,
        class_specifier = true,
        namespace_definition = true,
    },
    ruby = {
        program = true,
        method = true,
        singleton_method = true,
        class = true,
        module = true,
        block = true,
        do_block = true,
        lambda = true,
    },
}

--- Node types that must never be treated as scopes (generic fallback safety net).
local SCOPE_EXCLUDE = {
    function_call = true,
    method_call = true,
    call_expression = true,
    class_pattern = true,
    class_heritage = true,
    method_parameters = true,
    function_parameters = true,
}

--- Conservative substring patterns for unknown languages.
local GENERIC_SCOPE_PATTERNS = {
    "_definition",
    "_declaration",
    "source_file",
    "program",
    "module",
    "chunk",
}

--- Identifier node type substrings. A node qualifies if its type contains
--- one of these AND it has zero children (leaf node).
local IDENTIFIER_PATTERNS = { "identifier", "name" }

---@class showtime.Cache
---@field bufnr number
---@field changedtick number
---@field node_text string
---@field node_type string
---@field cursor_row number
---@field cursor_col number
---@field scope_sr number
---@field scope_sc number
---@field scope_er number
---@field scope_ec number
---@field top number
---@field bot number

--- Per-window cache, keyed by winid.
---@type table<number, showtime.Cache>
local cache = {}

--- Per-buffer tracking of whether extmarks are active.
---@type table<number, boolean>
local active = {}

--- Effective scope node tables (builtins merged with user config).
---@type table<string, table<string, boolean>>
local effective_scope_nodes = vim.deepcopy(BUILTIN_SCOPE_NODES)

--- Rebuild effective scope tables from builtins + user config.
--- Called once from setup(), not on the hot path.
---@param user_scope_nodes table<string, table<string, boolean>>?
function M._rebuild_scope_nodes(user_scope_nodes)
    if user_scope_nodes then
        effective_scope_nodes = vim.tbl_deep_extend("force", vim.deepcopy(BUILTIN_SCOPE_NODES), user_scope_nodes)
    else
        effective_scope_nodes = vim.deepcopy(BUILTIN_SCOPE_NODES)
    end
end

--- Clear highlights for a buffer if it has active extmarks.
---@param bufnr number
local function clear_if_active(bufnr)
    if active[bufnr] then
        M.clear(bufnr)
    end
end

--- Check whether a treesitter node represents an identifier.
---@param node TSNode
---@return boolean
local function is_identifier(node)
    if node:child_count() > 0 then
        return false
    end
    local ntype = node:type()
    for _, pat in ipairs(IDENTIFIER_PATTERNS) do
        if ntype:find(pat, 1, true) then
            return true
        end
    end
    return false
end

--- Walk up the tree to find the nearest scope boundary.
--- Falls back to the tree root.
---@param node TSNode
---@param lang string Treesitter language name
---@return TSNode
local function find_scope(node, lang)
    local scope_set = effective_scope_nodes[lang]
    local root = node
    local current = node:parent()
    while current do
        root = current
        local ntype = current:type()
        if scope_set then
            if scope_set[ntype] then
                return current
            end
        else
            -- Generic fallback for unknown languages.
            if not SCOPE_EXCLUDE[ntype] then
                for _, pat in ipairs(GENERIC_SCOPE_PATTERNS) do
                    if ntype:find(pat, 1, true) then
                        return current
                    end
                end
            end
        end
        current = current:parent()
    end
    return root
end

--- Iterative DFS over scope descendants. Collects matching nodes that
--- overlap the visible viewport. Prunes entire subtrees outside viewport.
---@param scope TSNode
---@param text string
---@param ntype string
---@param bufnr number
---@param top number 0-indexed first visible line
---@param bot number 0-indexed last visible line
---@param max number
---@return number[][] List of {start_row, start_col, end_row, end_col}
local function find_matches(scope, text, ntype, bufnr, top, bot, max)
    local matches = {}
    local stack = { scope }

    while #stack > 0 do
        local current = stack[#stack]
        stack[#stack] = nil

        local sr, _, er, _ = current:range()

        -- Prune subtrees entirely outside the viewport.
        if er >= top and sr <= bot then
            if current:child_count() == 0 then
                -- Leaf node: check if it matches.
                if current:type() == ntype and vim.treesitter.get_node_text(current, bufnr) == text then
                    local r1, c1, r2, c2 = current:range()
                    matches[#matches + 1] = { r1, c1, r2, c2 }
                    if #matches >= max then
                        return matches
                    end
                end
            else
                -- Push children in reverse order (LIFO -> first child processed first).
                local count = current:child_count()
                for i = count - 1, 0, -1 do
                    stack[#stack + 1] = current:child(i)
                end
            end
        end
    end

    return matches
end

--- Resolve the identifier under the cursor and its enclosing scope, parsing the
--- whole buffer. Navigation needs matches outside the viewport, so unlike the
--- highlight path this does not prune to visible lines.
---@param bufnr number
---@param winid number
---@return TSNode? scope
---@return string? node_text
---@return string? node_type
---@return number? cursor_row 0-indexed start row of the cursor's identifier
---@return number? cursor_col 0-indexed start col of the cursor's identifier
local function resolve_identifier(bufnr, winid)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or not parser then
        return nil
    end
    parser:parse(true)

    local cursor = vim.api.nvim_win_get_cursor(winid)
    local node = vim.treesitter.get_node({
        bufnr = bufnr,
        pos = { cursor[1] - 1, cursor[2] },
        ignore_injections = false,
    })
    if not node or not is_identifier(node) then
        return nil
    end

    local node_text = vim.treesitter.get_node_text(node, bufnr)
    if not node_text or node_text == "" then
        return nil
    end

    local cursor_row, cursor_col = node:range()
    local lang = parser:language_for_range({ cursor_row, cursor_col, cursor_row, cursor_col }):lang()
    return find_scope(node, lang), node_text, node:type(), cursor_row, cursor_col
end

--- Collect every reference to the identifier under the cursor within its scope,
--- across the whole buffer (not just the viewport). Used for navigation, not the
--- highlight hot path. The cursor's own occurrence is included.
---@param bufnr number
---@param winid number
---@return number[][]? matches Document-ordered {start_row, start_col, end_row, end_col}, 0-indexed
---@return number? cursor_index 1-based index of the cursor's own occurrence
function M.references(bufnr, winid)
    local scope, node_text, node_type, cursor_row, cursor_col = resolve_identifier(bufnr, winid)
    if not scope then
        return nil
    end

    local last_line = vim.api.nvim_buf_line_count(bufnr) - 1
    local matches = find_matches(scope, node_text, node_type, bufnr, 0, last_line, math.huge)
    table.sort(matches, function(a, b)
        if a[1] ~= b[1] then
            return a[1] < b[1]
        end
        return a[2] < b[2]
    end)

    local cursor_index
    for i, m in ipairs(matches) do
        if m[1] == cursor_row and m[2] == cursor_col then
            cursor_index = i
            break
        end
    end

    return matches, cursor_index
end

--- Update highlights for the current cursor position.
---@param bufnr number
---@param winid number? Window to use for viewport/cache (default: current window)
function M.update(bufnr, winid)
    winid = winid or vim.api.nvim_get_current_win()

    -- Extmarks are buffer-global. If this isn't the focused window, drawing
    -- would clobber highlights derived from the focused window's cursor. Skip
    -- silently: the cache for `winid` was already invalidated by the caller
    -- (e.g., WinScrolled), so re-focusing the window forces a fresh compute.
    if winid ~= vim.api.nvim_get_current_win() then
        return
    end

    if vim.b[bufnr].showtime_disabled then
        clear_if_active(bufnr)
        return
    end

    local showtime = require("showtime")
    if not showtime.enabled then
        clear_if_active(bufnr)
        return
    end

    local config = showtime.config

    local bt = vim.bo[bufnr].buftype
    if config._bt_set[bt] then
        clear_if_active(bufnr)
        return
    end

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or not parser then
        clear_if_active(bufnr)
        return
    end

    -- Root language exclusion: skip parsing entirely for excluded languages.
    -- Injection-level exclusion happens later after get_node resolves the tree.
    if config._lang_set[parser:lang()] then
        clear_if_active(bufnr)
        return
    end

    -- Viewport bounds and cursor position for the target window.
    local cursor = vim.api.nvim_win_get_cursor(winid) -- {1-indexed row, 0-indexed col}
    local cursor_pos = { cursor[1] - 1, cursor[2] } -- 0-indexed for treesitter
    local top = vim.api.nvim_win_call(winid, function()
        return vim.fn.line("w0") - 1
    end)
    local bot = vim.api.nvim_win_call(winid, function()
        return vim.fn.line("w$") - 1
    end)
    parser:parse({ top, bot })

    -- get_node() with explicit pos so deferred updates resolve the correct
    -- identifier for the target window, not whatever window is current.
    -- ignore_injections = false lets us get nodes from injected language trees
    -- (e.g., Lua inside a markdown code fence).
    local node = vim.treesitter.get_node({
        bufnr = bufnr,
        pos = cursor_pos,
        ignore_injections = false,
    })
    if not node then
        clear_if_active(bufnr)
        return
    end

    if not is_identifier(node) then
        clear_if_active(bufnr)
        return
    end

    local node_text = vim.treesitter.get_node_text(node, bufnr)
    if not node_text or node_text == "" then
        clear_if_active(bufnr)
        return
    end
    local node_type = node:type()
    local cursor_row, cursor_col = node:range()

    -- Resolve the active language from the node's range, not the root parser.
    -- Inside injected regions (e.g., Lua in markdown), parser:lang() returns
    -- the host language while the node belongs to the injection's LanguageTree.
    local lang = parser:language_for_range({ cursor_row, cursor_col, cursor_row, cursor_col }):lang()

    -- Language exclusion based on the active tree's language.
    if config._lang_set[lang] then
        clear_if_active(bufnr)
        return
    end

    local scope = find_scope(node, lang)
    local sr, sc, er, ec = scope:range()

    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local c = cache[winid]
    if
        c
        and c.bufnr == bufnr
        and c.changedtick == tick
        and c.node_text == node_text
        and c.node_type == node_type
        and c.cursor_row == cursor_row
        and c.cursor_col == cursor_col
        and c.scope_sr == sr
        and c.scope_sc == sc
        and c.scope_er == er
        and c.scope_ec == ec
        and c.top == top
        and c.bot == bot
    then
        return
    end

    cache[winid] = {
        bufnr = bufnr,
        changedtick = tick,
        node_text = node_text,
        node_type = node_type,
        cursor_row = cursor_row,
        cursor_col = cursor_col,
        scope_sr = sr,
        scope_sc = sc,
        scope_er = er,
        scope_ec = ec,
        top = top,
        bot = bot,
    }

    local matches = find_matches(scope, node_text, node_type, bufnr, top, bot, config.max_matches)

    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

    if #matches < config.min_matches then
        active[bufnr] = nil
        return
    end

    local hl_group = config.hl_group

    for _, m in ipairs(matches) do
        local is_cursor = m[1] == cursor_row and m[2] == cursor_col
        if not is_cursor then
            vim.api.nvim_buf_set_extmark(bufnr, ns, m[1], m[2], {
                end_row = m[3],
                end_col = m[4],
                hl_group = hl_group,
                priority = 110,
                strict = false,
            })
        end
    end

    active[bufnr] = true
end

--- Clear highlights and reset cache for a buffer.
---@param bufnr number
function M.clear(bufnr)
    vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
    for winid, entry in pairs(cache) do
        if entry.bufnr == bufnr then
            cache[winid] = nil
        end
    end
    active[bufnr] = nil
end

--- Clear highlights across all loaded buffers.
function M.clear_all()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_loaded(bufnr) then
            vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        end
    end
    cache = {}
    active = {}
end

--- Invalidate cache for a specific window or all windows.
---@param winid number? Window ID (nil = invalidate all)
function M.invalidate_cache(winid)
    if winid then
        cache[winid] = nil
    else
        cache = {}
    end
end

--- Clean up state for a closed window.
---@param winid number
function M.cleanup_window(winid)
    cache[winid] = nil
end

--- Clean up state for a deleted buffer.
---@param bufnr number
function M.cleanup_buffer(bufnr)
    M.clear(bufnr)
end

return M
