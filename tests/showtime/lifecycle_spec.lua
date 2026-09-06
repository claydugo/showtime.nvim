local engine = require("showtime.engine")
local showtime = require("showtime")

vim.cmd("runtime plugin/showtime.lua")

local updates
local original_update = engine.update

local function open_buffer()
    local buffer = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_set_current_buf(buffer)
    vim.bo[buffer].buftype = ""
    vim.bo[buffer].filetype = "lua"
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, { "local value = 1", "print(value, value)", "print(value)" })
    vim.api.nvim_win_set_cursor(0, { 1, 6 })
    return buffer
end

describe("showtime lifecycle", function()
    before_each(function()
        showtime.setup()
        showtime.enabled = true
        updates = {}
        engine.update = function(buffer, window, ...)
            updates[#updates + 1] = { buffer, window }
            return original_update(buffer, window, ...)
        end
    end)

    after_each(function()
        engine.update = original_update
        showtime.cancel()
        engine.clear_all()
        vim.o.eventignore = ""
    end)

    it("cancels pending cursor and scroll timers on InsertEnter", function()
        local buffer = open_buffer()
        showtime.setup({ delay = 20 })
        vim.o.eventignore = "CursorMoved"
        showtime.schedule_update(buffer)
        showtime.schedule_scroll_update(buffer)
        updates = {}
        vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buffer })
        vim.wait(70, function()
            return #updates > 0
        end)
        assert.are.equal(0, #updates)
    end)

    it("rejects callbacks already queued before cancellation", function()
        local buffer = open_buffer()
        showtime.setup({ delay = 10 })
        vim.o.eventignore = "CursorMoved"
        local original_schedule = vim.schedule
        local scheduled = {}
        vim.schedule = function(callback)
            scheduled[#scheduled + 1] = callback
        end
        showtime.schedule_update(buffer)
        vim.wait(40, function()
            return #scheduled > 0
        end)
        vim.schedule = original_schedule
        assert.is_true(#scheduled > 0)
        updates = {}
        vim.api.nvim_exec_autocmds("InsertEnter", { buffer = buffer })
        for _, callback in ipairs(scheduled) do
            callback()
        end
        assert.are.equal(0, #updates)
    end)

    it("refreshes on entry and text changes without cursor movement", function()
        local buffer = open_buffer()
        for _, event in ipairs({ "BufWinEnter", "WinEnter", "InsertLeave", "TextChanged", "FileType" }) do
            updates = {}
            vim.api.nvim_exec_autocmds(event, { buffer = buffer })
            assert.are.same({ { buffer, vim.api.nvim_get_current_win() } }, updates)
        end
        showtime.disable()
        updates = {}
        showtime.enable()
        assert.are.same({ { buffer, vim.api.nvim_get_current_win() } }, updates)
    end)

    it("accepts command and mapping counts", function()
        local buffer = open_buffer()
        vim.cmd("2ShowtimeNextReference")
        assert.are.same({ 2, 13 }, vim.api.nvim_win_get_cursor(0))
        vim.cmd("2ShowtimePrevReference")
        assert.are.same({ 1, 6 }, vim.api.nvim_win_get_cursor(0))
        vim.keymap.set("n", "]r", "<Plug>(showtime-next-reference)", { buffer = buffer })
        vim.cmd("normal 2]r")
        assert.are.same({ 2, 13 }, vim.api.nvim_win_get_cursor(0))
    end)
end)
