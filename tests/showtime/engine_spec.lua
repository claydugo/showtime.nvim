local provider
local original_provider = vim.api.nvim_set_decoration_provider
vim.api.nvim_set_decoration_provider = function(namespace, callbacks)
    provider = callbacks
    original_provider(namespace, callbacks)
end
local engine = require("showtime.engine")
vim.api.nvim_set_decoration_provider = original_provider
local showtime = require("showtime")

local ns = vim.api.nvim_create_namespace("showtime")

--- Set up a buffer with the given lines and filetype, focused in the current window.
---@param lines string[]
---@param ft string?
---@return number bufnr
---@return number winid
local function open_buffer(lines, ft)
    ft = ft or "lua"
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = ft
    -- Scratch buffers default to buftype=nofile, which the plugin excludes.
    -- Reset to a regular buffer so engine.update doesn't bail.
    vim.bo[bufnr].buftype = ""
    vim.api.nvim_set_current_buf(bufnr)
    -- Force parser attach so engine.update doesn't bail on first call.
    local ok = pcall(vim.treesitter.get_parser, bufnr, ft)
    assert(ok, "no treesitter parser for filetype: " .. ft)
    return bufnr, vim.api.nvim_get_current_win()
end

local function extmark_count(bufnr, winid)
    local marks = {}
    local original = vim.api.nvim_buf_set_extmark
    vim.api.nvim_buf_set_extmark = function(buffer, namespace, row, column, options)
        if buffer == bufnr and namespace == ns then
            assert.is_true(options.ephemeral)
            marks[#marks + 1] = { row, column, options }
        end
        return 0
    end
    local ok, failure = pcall(provider.on_win, "win", winid or vim.api.nvim_get_current_win(), bufnr)
    vim.api.nvim_buf_set_extmark = original
    assert(ok, failure)
    return #marks, marks
end

--- Find (1-indexed row, 0-indexed col) of the first occurrence of `needle` on the given line.
local function find_col(bufnr, lnum, needle)
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    local s = line:find(needle, 1, true)
    assert(s, "needle not found on line: " .. tostring(line))
    return lnum, s - 1
end

describe("showtime.engine", function()
    before_each(function()
        showtime.setup()
        showtime.enabled = true
    end)

    after_each(function()
        engine.clear_all()
    end)

    it("highlights matching identifiers in the same scope", function()
        local bufnr, winid = open_buffer({
            "local function foo()",
            "    local x = 1",
            "    return x + x",
            "end",
        })
        local row, col = find_col(bufnr, 2, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        -- Three occurrences of x; cursor is on one → 2 extmarks.
        assert.are.equal(2, extmark_count(bufnr))
    end)

    it("places no highlight when only the cursor occurrence exists (min_matches=2)", function()
        local bufnr, winid = open_buffer({
            "local solo = 1",
            "return 0",
        })
        local row, col = find_col(bufnr, 1, "solo")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        assert.are.equal(0, extmark_count(bufnr))
    end)

    it("highlights single occurrence when min_matches=1", function()
        showtime.setup({ min_matches = 1 })
        local bufnr, winid = open_buffer({
            "local solo = 1",
            "return 0",
        })
        local row, col = find_col(bufnr, 1, "solo")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        -- With a single occurrence the cursor is excluded, so 0 extmarks either way.
        -- Switch to a 2-occurrence buffer to confirm min_matches=1 highlights a lone sibling.
        engine.clear_all()
        local b2, w2 = open_buffer({ "local x = 1", "print(x)" })
        local r2, c2 = find_col(b2, 1, "x")
        vim.api.nvim_win_set_cursor(w2, { r2, c2 })
        engine.update(b2, w2)
        assert.are.equal(1, extmark_count(b2))
    end)

    it("scope-limits matches to the containing function", function()
        local bufnr, winid = open_buffer({
            "local function foo()",
            "    local x = 1",
            "    return x",
            "end",
            "local function bar()",
            "    local x = 2",
            "    return x",
            "end",
        })
        -- Cursor on x inside foo; bar's x's must not be highlighted.
        local row, col = find_col(bufnr, 2, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        -- foo has 2 x's; cursor excluded → 1 extmark.
        assert.are.equal(1, extmark_count(bufnr))
    end)

    it("respects exclude_buftypes", function()
        showtime.setup({ exclude_buftypes = { "nofile" } })
        local bufnr, winid = open_buffer({
            "local x = 1",
            "print(x, x)",
        })
        local row, col = find_col(bufnr, 1, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        assert.are.equal(2, extmark_count(bufnr))
        vim.bo[bufnr].buftype = "nofile"
        assert.are.equal(0, extmark_count(bufnr))
        engine.update(bufnr, winid)
        assert.are.equal(0, extmark_count(bufnr))
    end)

    it("respects vim.b.showtime_disabled", function()
        local bufnr, winid = open_buffer({
            "local x = 1",
            "print(x, x)",
        })
        vim.b[bufnr].showtime_disabled = true
        local row, col = find_col(bufnr, 1, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        assert.are.equal(0, extmark_count(bufnr))
    end)

    it("respects exclude_languages", function()
        showtime.setup({ exclude_languages = { "lua" } })
        local bufnr, winid = open_buffer({
            "local x = 1",
            "print(x, x)",
        })
        local row, col = find_col(bufnr, 1, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        assert.are.equal(0, extmark_count(bufnr))
    end)

    it("respects max_matches as a safety cap", function()
        showtime.setup({ max_matches = 2 })
        local bufnr, winid = open_buffer({
            "local x = 0",
            "x = x + x",
            "x = x + x",
        })
        local row, col = find_col(bufnr, 1, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        -- The display budget excludes the cursor occurrence.
        local count = extmark_count(bufnr)
        assert.are.equal(2, count)
    end)

    it("clears highlights when the cursor leaves an identifier", function()
        local bufnr, winid = open_buffer({
            "local x = 1",
            "print(x, x)",
        })
        local row, col = find_col(bufnr, 1, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        assert.is_true(extmark_count(bufnr) > 0)

        vim.api.nvim_win_set_cursor(winid, { 1, 0 }) -- on `local` keyword
        engine.update(bufnr, winid)
        assert.are.equal(0, extmark_count(bufnr))
    end)

    it("caches identical updates and skips redundant work", function()
        local bufnr, winid = open_buffer({
            "local x = 1",
            "print(x, x)",
        })
        local row, col = find_col(bufnr, 1, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        assert.is_true(extmark_count(bufnr) > 0)

        -- Fail on parsing without clearing the engine cache.
        local parser = vim.treesitter.get_parser(bufnr)
        local original = parser.parse
        parser.parse = function()
            error("Unexpected parse")
        end

        -- A cache hit should return early and reuse prepared decorations.
        local ok, failure = pcall(engine.update, bufnr, winid)
        parser.parse = original
        assert(ok, failure)
        assert.are.equal(2, extmark_count(bufnr))
    end)

    it("invalidates the cache when the buffer changes (changedtick)", function()
        local bufnr, winid = open_buffer({
            "local x = 1",
            "print(x, x)",
        })
        local row, col = find_col(bufnr, 1, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)

        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)

        -- Bump changedtick by appending a comment line.
        vim.api.nvim_buf_set_lines(bufnr, -1, -1, false, { "-- bump" })

        engine.update(bufnr, winid)
        assert.is_true(extmark_count(bufnr) > 0)
    end)

    it("invalidate_cache(winid) forces a rebuild on next update", function()
        local bufnr, winid = open_buffer({
            "local x = 1",
            "print(x, x)",
        })
        local row, col = find_col(bufnr, 1, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)

        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        engine.invalidate_cache(winid)

        engine.update(bufnr, winid)
        assert.is_true(extmark_count(bufnr) > 0)
    end)

    it("refreshes cached matches after the filetype changes", function()
        local buffer, window = open_buffer({ "local value = 1", "print(value, value)" })
        vim.api.nvim_win_set_cursor(window, { 1, 6 })
        engine.update(buffer, window)
        assert.are.equal(2, extmark_count(buffer))
        local changedtick = vim.api.nvim_buf_get_changedtick(buffer)
        vim.bo[buffer].filetype = "c"
        assert.are.equal(changedtick, vim.api.nvim_buf_get_changedtick(buffer))
        assert.are.equal(0, extmark_count(buffer))
        engine.update(buffer, window)
        assert.are.equal(2, extmark_count(buffer))
    end)

    it("clears cached matches when the new filetype is excluded or has no parser", function()
        showtime.setup({ exclude_languages = { "c" } })
        local buffer, window = open_buffer({ "local value = 1", "print(value, value)" })
        vim.api.nvim_win_set_cursor(window, { 1, 6 })
        engine.update(buffer, window)
        assert.are.equal(2, extmark_count(buffer))
        vim.bo[buffer].filetype = "c"
        engine.update(buffer, window)
        assert.are.equal(0, extmark_count(buffer))
        vim.bo[buffer].filetype = "lua"
        engine.update(buffer, window)
        assert.are.equal(2, extmark_count(buffer))
        vim.bo[buffer].filetype = "showtime_missing_parser"
        engine.update(buffer, window)
        assert.are.equal(0, extmark_count(buffer))
    end)

    it("clear() removes extmarks and forgets cache for a buffer", function()
        local bufnr, winid = open_buffer({
            "local x = 1",
            "print(x, x)",
        })
        local row, col = find_col(bufnr, 1, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        assert.is_true(extmark_count(bufnr) > 0)

        engine.clear(bufnr)
        assert.are.equal(0, extmark_count(bufnr))

        -- Subsequent update should re-place because cache was cleared.
        engine.update(bufnr, winid)
        assert.is_true(extmark_count(bufnr) > 0)
    end)

    it("user-supplied scope_nodes deep-merge with builtins", function()
        showtime.setup({ scope_nodes = { lua = { for_statement = true } } })
        local bufnr, winid = open_buffer({
            "local function foo()",
            "    for i = 1, 10 do",
            "        local x = i",
            "        print(x)",
            "    end",
            "    local x = 1", -- outside the for_statement scope
            "end",
        })
        -- Cursor on the x inside the for body.
        local row, col = find_col(bufnr, 3, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        engine.update(bufnr, winid)
        -- With for_statement as a scope, only the for-body x's are reachable
        -- (lines 3 and 4, cursor excluded, so 1 extmark).
        assert.are.equal(1, extmark_count(bufnr))
    end)

    it("reuses matches between occurrences of the same identifier", function()
        local bufnr, winid = open_buffer({ "local value = 1", "print(value, value)" })
        vim.api.nvim_win_set_cursor(winid, { 1, 6 })
        engine.update(bufnr, winid)
        local original = vim.treesitter.query.parse
        vim.treesitter.query.parse = function()
            error("Unexpected query")
        end
        vim.api.nvim_win_set_cursor(winid, { 2, 6 })
        local ok, failure = pcall(engine.update, bufnr, winid)
        vim.treesitter.query.parse = original
        assert(ok, failure)
        local count, marks = extmark_count(bufnr)
        assert.are.equal(2, count)
        assert.are.same({ 0, 6 }, { marks[1][1], marks[1][2] })
        assert.are.same({ 1, 13 }, { marks[2][1], marks[2][2] })
    end)

    it("applies configuration changes without cursor movement", function()
        local bufnr, winid = open_buffer({ "local value = 1", "print(value, value)" })
        vim.api.nvim_win_set_cursor(winid, { 1, 6 })
        engine.update(bufnr, winid)
        showtime.setup({ hl_group = "UpdatedReference" })
        local count, marks = extmark_count(bufnr)
        assert.are.equal(2, count)
        assert.are.equal("UpdatedReference", marks[1][3].hl_group)
        showtime.setup({ min_matches = 4 })
        assert.are.equal(0, extmark_count(bufnr))
    end)

    it("reserves the display budget for unfolded references", function()
        local lines = { "local value = 1" }
        for index = 2, 2000 do
            lines[index] = "print(value)"
        end
        lines[2001] = "print(value, value)"
        local bufnr, winid = open_buffer(lines)
        vim.wo.foldmethod = "manual"
        vim.cmd("2,2000fold")
        vim.api.nvim_win_set_cursor(winid, { 1, 6 })
        vim.cmd("redraw")
        engine.update(bufnr, winid)
        assert.is_true(vim.wait(1000, function()
            return extmark_count(bufnr) == 2
        end))
        local count, marks = extmark_count(bufnr)
        assert.are.equal(2, count)
        assert.are.equal(2000, marks[1][1])
        assert.are.equal(2000, marks[2][1])
        vim.cmd("normal! zE")
    end)

    it("does not draw in another window showing the same buffer", function()
        local bufnr, winid = open_buffer({ "local value = 1", "print(value, value)" })
        vim.cmd("vsplit")
        local other_window = vim.api.nvim_get_current_win()
        vim.api.nvim_set_current_win(winid)
        vim.api.nvim_win_set_cursor(winid, { 1, 6 })
        engine.update(bufnr, winid)
        assert.are.equal(2, extmark_count(bufnr, winid))
        assert.are.equal(0, extmark_count(bufnr, other_window))
        vim.api.nvim_win_close(other_window, true)
    end)

    it("ignores parser results after cancellation", function()
        local bufnr, winid = open_buffer({ "local value = 1", "print(value, value)" })
        vim.api.nvim_win_set_cursor(winid, { 1, 6 })
        local parser = vim.treesitter.get_parser(bufnr)
        local original = parser.parse
        local trees = parser:parse(true)
        local callback
        parser.parse = function(_, _, on_parse)
            callback = on_parse
        end
        engine.update(bufnr, winid)
        parser.parse = original
        assert.is_function(callback)
        engine.clear(bufnr)
        callback(nil, trees)
        assert.are.equal(0, extmark_count(bufnr))
    end)

    it("ignores parser results after the cursor moves", function()
        local bufnr, winid = open_buffer({ "local value = 1", "print(value, value)" })
        vim.api.nvim_win_set_cursor(winid, { 1, 6 })
        local parser = vim.treesitter.get_parser(bufnr)
        local original = parser.parse
        local trees = parser:parse(true)
        local callback
        parser.parse = function(_, _, on_parse)
            callback = on_parse
        end
        engine.update(bufnr, winid)
        parser.parse = original
        vim.api.nvim_win_set_cursor(winid, { 1, 0 })
        callback(nil, trees)
        assert.are.equal(0, extmark_count(bufnr))
    end)

    it("discards parser results when the filetype changes during parsing", function()
        local buffer, window = open_buffer({ "local value = 1", "print(value, value)" })
        vim.api.nvim_win_set_cursor(window, { 1, 6 })
        local parser = vim.treesitter.get_parser(buffer)
        local trees = parser:parse(true)
        local original = parser.parse
        local callback
        parser.parse = function(_, _, on_parse)
            callback = on_parse
        end
        engine.update(buffer, window)
        parser.parse = original
        assert.is_function(callback)
        vim.bo[buffer].filetype = "c"
        callback(nil, trees)
        assert.are.equal(0, extmark_count(buffer))
        vim.bo[buffer].filetype = "lua"
        assert.are.equal(0, extmark_count(buffer))
        engine.update(buffer, window)
        assert.are.equal(2, extmark_count(buffer))
    end)

    it("discards parser results when the buffer becomes excluded during parsing", function()
        local buffer, window = open_buffer({ "local value = 1", "print(value, value)" })
        vim.api.nvim_win_set_cursor(window, { 1, 6 })
        local parser = vim.treesitter.get_parser(buffer)
        local trees = parser:parse(true)
        local original = parser.parse
        local callback
        parser.parse = function(_, _, on_parse)
            callback = on_parse
        end
        engine.update(buffer, window)
        parser.parse = original
        assert.is_function(callback)
        vim.bo[buffer].buftype = "nofile"
        callback(nil, trees)
        assert.are.equal(0, extmark_count(buffer))
        vim.bo[buffer].buftype = ""
        assert.are.equal(0, extmark_count(buffer))
        engine.update(buffer, window)
        assert.are.equal(2, extmark_count(buffer))
    end)

    it("highlights injected Lua identifiers", function()
        local bufnr, winid = open_buffer({ "```lua", "local value = 1", "print(value)", "```" }, "markdown")
        vim.api.nvim_win_set_cursor(winid, { 2, 6 })
        engine.update(bufnr, winid)
        assert.is_true(vim.wait(1000, function()
            return extmark_count(bufnr) == 1
        end))
        local _, marks = extmark_count(bufnr)
        assert.are.same({ 2, 6 }, { marks[1][1], marks[1][2] })
    end)

    it("uses byte columns after UTF-8 text", function()
        local bufnr, winid = open_buffer({ "local value = 1", 'print("µ", value)' })
        vim.api.nvim_win_set_cursor(winid, { 1, 6 })
        engine.update(bufnr, winid)
        local count, marks = extmark_count(bufnr)
        assert.are.equal(1, count)
        assert.are.equal(12, marks[1][2])
        assert.are.equal(17, marks[1][3].end_col)
    end)
end)
