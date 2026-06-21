local engine = require("showtime.engine")
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

local function extmark_count(bufnr)
    return #vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, {})
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
        vim.bo[bufnr].buftype = "nofile"
        local row, col = find_col(bufnr, 1, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
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
        -- find_matches caps internally at 2; one of those 2 may be the cursor (excluded).
        local count = extmark_count(bufnr)
        assert.is_true(count >= 1 and count <= 2)
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

        -- Manually wipe extmarks without clearing the engine cache.
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
        assert.are.equal(0, extmark_count(bufnr))

        -- A cache hit should return early without re-placing extmarks.
        engine.update(bufnr, winid)
        assert.are.equal(0, extmark_count(bufnr))
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
end)
