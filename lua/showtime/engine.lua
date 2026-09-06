local M = {}

local config = require("showtime.config")

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
---@field scope TSNode
---@field position number[]
---@field ranges number[][]
---@field key string
---@field lang string
---@field matches number[][]

--- Per-window cache, keyed by winid.
---@type table<number, showtime.Cache>
local cache = {}

--- Per-window results prepared for the decoration provider.
---@type table<number, showtime.Cache>
local active = {}
local navigation_cache = {}
local requests = {}
local redraw_pending = false
local redraw_windows = {}

local function redraw(winid)
    redraw_windows[winid] = true
    if redraw_pending then
        return
    end
    redraw_pending = true
    vim.schedule(function()
        redraw_pending = false
        for window in pairs(redraw_windows) do
            if vim.api.nvim_win_is_valid(window) then
                vim.api.nvim__redraw({ win = window, valid = false })
            end
        end
        redraw_windows = {}
        vim.api.nvim__redraw({ flush = true })
    end)
end

local function visible_ranges(top, bot)
    local ranges = {}
    local row = top
    while row <= bot do
        local fold_end = vim.fn.foldclosedend(row + 1)
        if fold_end == -1 then
            local range = ranges[#ranges]
            if range and range[2] == row then
                range[2] = row + 1
            else
                ranges[#ranges + 1] = { row, row + 1 }
            end
            row = row + 1
        else
            row = fold_end
        end
    end
    return ranges
end

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
    for _, entry in pairs(active) do
        if entry.bufnr == bufnr then
            M.clear(bufnr)
            return
        end
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

--- Query scope descendants for matching leaves within the requested ranges.
--- Closed folds do not contribute matches to the highlight budget.
---@param scope TSNode
---@param text string
---@param ntype string
---@param bufnr number
---@param ranges number[][] Visible ranges with exclusive end rows
---@param lang string Treesitter language name
---@param max number
---@return number[][] List of {start_row, start_col, end_row, end_col}
local function find_matches(scope, text, ntype, bufnr, ranges, lang, max)
    local matches = {}
    local query = vim.treesitter.query.parse(lang, "(" .. ntype .. ") @reference")

    -- Limit each query to an unfolded range of the viewport.
    for _, range in ipairs(ranges) do
        for _, current in query:iter_captures(scope, bufnr, range[1], range[2]) do
            -- Leaf node: check if it matches.
            if current:child_count() == 0 and vim.treesitter.get_node_text(current, bufnr) == text then
                local r1, c1, r2, c2 = current:range()
                matches[#matches + 1] = { r1, c1, r2, c2 }
                if #matches >= max then
                    return matches
                end
            end
        end
    end

    -- Query captures preserve document order across ascending visible ranges.
    return matches
end

--- Resolve the identifier under the cursor and its enclosing scope from a
--- parsed language tree. Navigation can collect matches outside the viewport;
--- highlighting limits collection to unfolded viewport ranges.
---@param bufnr number
---@param winid number
---@return showtime.Cache? context
local function resolve_identifier(bufnr, winid, parser)
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local node = parser:named_node_for_range({ cursor[1] - 1, cursor[2], cursor[1] - 1, cursor[2] }, {
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
    local scope = find_scope(node, lang)
    local sr, sc, er, ec = scope:range()
    return {
        bufnr = bufnr,
        position = cursor,
        scope = scope,
        node_text = node_text,
        node_type = node:type(),
        cursor_row = cursor_row,
        cursor_col = cursor_col,
        lang = lang,
        key = table.concat({ lang, node:type(), node_text, sr, sc, er, ec }, "\0"),
    }
end

--- Collect every reference to the identifier under the cursor within its scope,
--- across the whole buffer (not just the viewport). Used for navigation, not the
--- highlight hot path. The cursor's own occurrence is included.
---@param bufnr number
---@param winid number
---@return number[][]? matches Document-ordered {start_row, start_col, end_row, end_col}, 0-indexed
---@return number? cursor_index 1-based index of the cursor's own occurrence
function M.references(bufnr, winid)
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or not parser then
        return nil
    end
    local cursor = vim.api.nvim_win_get_cursor(winid)
    parser:parse({ cursor[1] - 1, cursor[1] })
    local context = resolve_identifier(bufnr, winid, parser)
    if not context then
        return nil
    end

    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local previous = navigation_cache[bufnr]
    local matches
    if
        previous
        and previous.changedtick == tick
        and previous.revision == config.revision
        and previous.key == context.key
    then
        matches = previous.matches
    else
        local last_line = vim.api.nvim_buf_line_count(bufnr)
        matches = find_matches(
            context.scope,
            context.node_text,
            context.node_type,
            bufnr,
            { { 0, last_line } },
            context.lang,
            math.huge
        )
        context.changedtick = tick
        context.revision = config.revision
        context.matches = matches
        navigation_cache[bufnr] = context
    end

    local cursor_index
    for i, m in ipairs(matches) do
        if m[1] == context.cursor_row and m[2] == context.cursor_col then
            cursor_index = i
            break
        end
    end

    return matches, cursor_index
end

--- Update highlights for the current cursor position.
---@param bufnr number
---@param winid number? Window to use for viewport/cache (default: current window)
function M.update(bufnr, winid, options, is_current, on_view_changed)
    winid = winid or vim.api.nvim_get_current_win()
    options = options or config.options

    -- Only the focused window requests highlighting. The decoration provider
    -- confines drawing to that window, including buffers shown in multiple
    -- windows. Deferred results also verify focus before entering the cache.
    -- Window entry schedules a fresh update for the newly focused window.
    if winid ~= vim.api.nvim_get_current_win() then
        return
    end

    if
        not vim.api.nvim_buf_is_loaded(bufnr)
        or not vim.api.nvim_win_is_valid(winid)
        or vim.api.nvim_win_get_buf(winid) ~= bufnr
    then
        return
    end

    if vim.b[bufnr].showtime_disabled or vim.api.nvim_get_mode().mode:match("^[iRt]") then
        clear_if_active(bufnr)
        return
    end

    local bt = vim.bo[bufnr].buftype
    if options._bt_set[bt] then
        clear_if_active(bufnr)
        return
    end

    -- Viewport bounds and cursor position for the target window.
    local cursor = vim.api.nvim_win_get_cursor(winid) -- {1-indexed row, 0-indexed col}
    local cursor_pos = { cursor[1] - 1, cursor[2] } -- 0-indexed for treesitter
    local top = vim.fn.line("w0") - 1
    local bot = vim.fn.line("w$") - 1
    local ranges = visible_ranges(top, bot)

    local tick = vim.api.nvim_buf_get_changedtick(bufnr)
    local revision = config.revision
    local filetype = vim.bo[bufnr].filetype
    local c = cache[winid]
    if
        c
        and c.bufnr == bufnr
        and c.changedtick == tick
        and c.revision == revision
        and c.filetype == filetype
        and vim.deep_equal(c.position, cursor)
        and vim.deep_equal(c.ranges, ranges)
    then
        c.refresh_pending = nil
        return
    end

    local ok, parser = pcall(vim.treesitter.get_parser, bufnr)
    if not ok or not parser then
        clear_if_active(bufnr)
        return
    end

    -- Root language exclusion: skip parsing entirely for excluded languages.
    -- Injection-level exclusion follows resolution of the cursor's language tree.
    if options._lang_set[parser:lang()] then
        clear_if_active(bufnr)
        return
    end

    local request = { bufnr = bufnr }
    requests[winid] = request
    parser:parse({ cursor_pos[1], cursor_pos[1] + 1 }, function(failure, trees)
        if
            requests[winid] ~= request
            or (is_current and not is_current())
            or not vim.api.nvim_buf_is_loaded(bufnr)
            or not vim.api.nvim_win_is_valid(winid)
            or vim.api.nvim_get_current_win() ~= winid
            or vim.api.nvim_win_get_buf(winid) ~= bufnr
            or vim.api.nvim_buf_get_changedtick(bufnr) ~= tick
            or config.revision ~= revision
            or vim.bo[bufnr].filetype ~= filetype
            or options._bt_set[vim.bo[bufnr].buftype]
            or vim.b[bufnr].showtime_disabled
            or vim.api.nvim_get_mode().mode:match("^[iRt]")
            or not vim.deep_equal(vim.api.nvim_win_get_cursor(winid), cursor)
        then
            return
        end
        if
            vim.fn.line("w0") - 1 ~= top
            or vim.fn.line("w$") - 1 ~= bot
            or not vim.deep_equal(visible_ranges(top, bot), ranges)
        then
            if on_view_changed then
                on_view_changed()
            end
            return
        end
        if failure or not trees then
            M.clear(bufnr)
            return
        end

        -- Resolve the explicit cursor position after parsing its language tree.
        -- Deferred updates only proceed while that position remains current.
        -- Injected regions use their own grammar and enclosing syntax scope.
        -- This also supports Lua identifiers inside Markdown code fences.
        local context = resolve_identifier(bufnr, winid, parser)
        if not context then
            M.clear(bufnr)
            return
        end

        -- Resolve the active language from the identifier's range. The root
        -- parser describes the host language, while the identifier can belong
        -- to an injected language tree with different scope boundaries.
        local lang = context.lang

        -- Language exclusion based on the active tree's language.
        if options._lang_set[lang] then
            M.clear(bufnr)
            return
        end

        local matches
        if
            c
            and c.bufnr == bufnr
            and c.changedtick == tick
            and c.revision == revision
            and c.filetype == filetype
            and c.key == context.key
            and vim.deep_equal(c.ranges, ranges)
        then
            matches = c.matches
        else
            matches = find_matches(
                context.scope,
                context.node_text,
                context.node_type,
                bufnr,
                ranges,
                lang,
                math.max(options.max_matches + 1, options.min_matches)
            )
        end
        context.changedtick = tick
        context.revision = revision
        context.filetype = filetype
        context.ranges = ranges
        context.matches = matches
        context.hl_group = options.hl_group
        context.max_matches = options.max_matches
        context.on_view_changed = on_view_changed
        cache[winid] = context
        active[winid] = #matches >= options.min_matches and context or nil
        redraw(winid)
    end)
end

--- Clear highlights and reset cache for a buffer.
---@param bufnr number
function M.clear(bufnr)
    for winid, entry in pairs(active) do
        if entry.bufnr == bufnr then
            redraw(winid)
            active[winid] = nil
        end
    end
    for winid, entry in pairs(cache) do
        if entry.bufnr == bufnr then
            cache[winid] = nil
            active[winid] = nil
        end
    end
    for winid, request in pairs(requests) do
        if request.bufnr == bufnr then
            requests[winid] = nil
        end
    end
    navigation_cache[bufnr] = nil
end

--- Clear highlights across all loaded buffers.
function M.clear_all()
    for winid in pairs(active) do
        redraw(winid)
    end
    cache = {}
    active = {}
    requests = {}
    navigation_cache = {}
end

--- Invalidate cache for a specific window or all windows.
---@param winid number? Window ID (nil = invalidate all)
function M.invalidate_cache(winid)
    if winid then
        cache[winid] = nil
        requests[winid] = nil
    else
        cache = {}
        requests = {}
    end
end

--- Clean up state for a closed window.
---@param winid number
function M.cleanup_window(winid)
    cache[winid] = nil
    active[winid] = nil
    requests[winid] = nil
    redraw(winid)
end

--- Clean up state for a deleted buffer.
---@param bufnr number
function M.cleanup_buffer(bufnr)
    M.clear(bufnr)
end

vim.api.nvim_set_decoration_provider(ns, {
    on_win = function(_, winid, bufnr)
        local context = cache[winid]
        if
            not context
            or winid ~= vim.api.nvim_get_current_win()
            or context.bufnr ~= bufnr
            or context.changedtick ~= vim.api.nvim_buf_get_changedtick(bufnr)
            or context.revision ~= config.revision
            or context.filetype ~= vim.bo[bufnr].filetype
            or config.options._bt_set[vim.bo[bufnr].buftype]
            or vim.b[bufnr].showtime_disabled
            or vim.api.nvim_get_mode().mode:match("^[iRt]")
        then
            return false
        end
        if not vim.deep_equal(context.ranges, visible_ranges(vim.fn.line("w0") - 1, vim.fn.line("w$") - 1)) then
            if context.on_view_changed and not context.refresh_pending then
                context.refresh_pending = true
                vim.schedule(function()
                    if cache[winid] == context then
                        context.on_view_changed()
                    end
                end)
            end
            return false
        end
        if not active[winid] then
            return false
        end
        local count = 0
        for _, m in ipairs(context.matches) do
            local is_cursor = m[1] == context.cursor_row and m[2] == context.cursor_col
            if not is_cursor then
                vim.api.nvim_buf_set_extmark(bufnr, ns, m[1], m[2], {
                    end_row = m[3],
                    end_col = m[4],
                    hl_group = context.hl_group,
                    priority = 110,
                    ephemeral = true,
                })
                count = count + 1
                if count >= context.max_matches then
                    break
                end
            end
        end
        return false
    end,
})

return M
