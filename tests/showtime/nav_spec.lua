local engine = require("showtime.engine")
local nav = require("showtime.nav")
local showtime = require("showtime")

local function open_buffer(lines, ft)
    ft = ft or "lua"
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    vim.bo[bufnr].filetype = ft
    vim.bo[bufnr].buftype = ""
    vim.api.nvim_set_current_buf(bufnr)
    local ok = pcall(vim.treesitter.get_parser, bufnr, ft)
    assert(ok, "no treesitter parser for filetype: " .. ft)
    return bufnr, vim.api.nvim_get_current_win()
end

--- (1-indexed row, 0-indexed col) of the nth occurrence of `needle` on a line.
local function find_col(bufnr, lnum, needle, nth)
    nth = nth or 1
    local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, false)[1]
    local s = 0
    for _ = 1, nth do
        s = line:find(needle, s + 1, true)
        assert(s, "needle not found on line: " .. tostring(line))
    end
    return lnum, s - 1
end

-- Four occurrences of `x`, all inside foo's scope:
--   line 2 col -> #1, line 3 (x = x + 1) -> #2 and #3, line 4 -> #4
local SAMPLE = {
    "local function foo()",
    "    local x = 1",
    "    x = x + 1",
    "    return x",
    "end",
}

describe("showtime.nav", function()
    before_each(function()
        showtime.setup()
        showtime.enabled = true
        vim.o.wrapscan = true
    end)

    after_each(function()
        engine.clear_all()
    end)

    it("references() collects all in-scope occurrences including the cursor", function()
        local bufnr, winid = open_buffer(SAMPLE)
        local row, col = find_col(bufnr, 2, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        local matches, idx = engine.references(bufnr, winid)
        assert.are.equal(4, #matches)
        assert.are.equal(1, idx) -- cursor sits on the first occurrence
    end)

    it("references() returns nil when the cursor is not on an identifier", function()
        local bufnr, winid = open_buffer(SAMPLE)
        vim.api.nvim_win_set_cursor(winid, { 1, 0 }) -- on the `local` keyword
        assert.is_nil(engine.references(bufnr, winid))
    end)

    it("references() is scope-limited", function()
        local bufnr, winid = open_buffer({
            "local function foo()",
            "    local x = 1",
            "    return x",
            "end",
            "local function bar()",
            "    return x",
            "end",
        })
        local row, col = find_col(bufnr, 2, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        local matches = engine.references(bufnr, winid)
        assert.are.equal(2, #matches) -- only foo's two x's, not bar's
    end)

    it("next_reference moves to the following occurrence", function()
        local bufnr, winid = open_buffer(SAMPLE)
        vim.api.nvim_win_set_cursor(winid, { find_col(bufnr, 2, "x") })
        nav.next_reference()
        assert.are.same({ find_col(bufnr, 3, "x", 1) }, vim.api.nvim_win_get_cursor(winid))
    end)

    it("prev_reference moves to the preceding occurrence", function()
        local bufnr, winid = open_buffer(SAMPLE)
        vim.api.nvim_win_set_cursor(winid, { find_col(bufnr, 4, "x") })
        nav.prev_reference()
        -- previous of `return x` is the second x on `x = x + 1`
        assert.are.same({ find_col(bufnr, 3, "x", 2) }, vim.api.nvim_win_get_cursor(winid))
    end)

    it("wraps from last to first with wrapscan on", function()
        local bufnr, winid = open_buffer(SAMPLE)
        vim.api.nvim_win_set_cursor(winid, { find_col(bufnr, 4, "x") })
        nav.next_reference()
        assert.are.same({ find_col(bufnr, 2, "x") }, vim.api.nvim_win_get_cursor(winid))
    end)

    it("clamps at the last occurrence with wrapscan off", function()
        vim.o.wrapscan = false
        local bufnr, winid = open_buffer(SAMPLE)
        local row, col = find_col(bufnr, 4, "x")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        nav.next_reference()
        assert.are.same({ row, col }, vim.api.nvim_win_get_cursor(winid)) -- stayed put
    end)

    it("does not move when there are no other references in scope", function()
        local bufnr, winid = open_buffer({
            "local function foo()",
            "    local solo = 1",
            "    return 0",
            "end",
        })
        local row, col = find_col(bufnr, 2, "solo")
        vim.api.nvim_win_set_cursor(winid, { row, col })
        nav.next_reference()
        assert.are.same({ row, col }, vim.api.nvim_win_get_cursor(winid))
    end)
end)
