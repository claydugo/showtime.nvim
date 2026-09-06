local M = {}

local config = require("showtime.config")
local utils = require("showtime.utils")

---@type boolean
M.enabled = true

--- Public access to the resolved config table.
---@type showtime.Config
M.config = config.options

--- Timer for CursorMoved debounce.
local cursor_timer = vim.uv.new_timer()

--- Timer for WinScrolled debounce.
local scroll_timer = vim.uv.new_timer()

--- Per-timer pending target. Each timer has its own pair so a cursor event in
--- one window can't redirect a pending scroll update for another window.
local pending_cursor_bufnr, pending_cursor_winid = 0, 0
local pending_scroll_bufnr, pending_scroll_winid = 0, 0
local generation = 0
local cursor_generation = 0
local scroll_generation = 0

--- Validate buffer/window are still consistent, then run engine update.
---@param bufnr number
---@param winid number
local function run_update(bufnr, winid, update_generation)
    if
        M.enabled
        and generation == update_generation
        and not vim.api.nvim_get_mode().mode:match("^[iRt]")
        and vim.api.nvim_buf_is_loaded(bufnr)
        and vim.api.nvim_win_is_valid(winid)
        and winid == vim.api.nvim_get_current_win()
        and vim.api.nvim_win_get_buf(winid) == bufnr
    then
        require("showtime.engine").update(bufnr, winid, config.options, function()
            return M.enabled and generation == update_generation
        end, function()
            if M.enabled and generation == update_generation then
                M.schedule_scroll_update(bufnr, winid)
            end
        end)
    end
end

local function cursor_callback()
    local bufnr, winid = pending_cursor_bufnr, pending_cursor_winid
    local update_generation, timer_generation = generation, cursor_generation
    vim.schedule(function()
        if timer_generation == cursor_generation then
            run_update(bufnr, winid, update_generation)
        end
    end)
end

local function scroll_callback()
    local bufnr, winid = pending_scroll_bufnr, pending_scroll_winid
    local update_generation, timer_generation = generation, scroll_generation
    vim.schedule(function()
        if timer_generation == scroll_generation then
            run_update(bufnr, winid, update_generation)
        end
    end)
end

function M.cancel()
    generation = generation + 1
    cursor_generation = cursor_generation + 1
    scroll_generation = scroll_generation + 1
    cursor_timer:stop()
    scroll_timer:stop()
end

--- Merge user options into config and define the default highlight group.
--- Calling setup() is optional -- the plugin works with defaults.
---@param opts showtime.Config?
function M.setup(opts)
    if not config.setup(opts) then
        return
    end
    M.cancel()
    require("showtime.engine").clear_all()
    vim.api.nvim_set_hl(0, M.config.hl_group, { default = true, link = "LspReferenceText" })
    require("showtime.engine")._rebuild_scope_nodes(M.config.scope_nodes)
    M.schedule_update(vim.api.nvim_get_current_buf())
end

--- Schedule an engine update with CursorMoved delay.
---@param bufnr number
---@param winid number? Window ID (default: current window)
function M.schedule_update(bufnr, winid)
    if not M.enabled then
        return
    end
    winid = winid or vim.api.nvim_get_current_win()
    local delay = M.config.delay
    cursor_generation = cursor_generation + 1
    cursor_timer:stop()
    if delay > 0 then
        pending_cursor_bufnr = bufnr
        pending_cursor_winid = winid
        cursor_timer:start(delay, 0, cursor_callback)
    else
        run_update(bufnr, winid, generation)
    end
end

--- Schedule an engine update with scroll debounce (delay with 30ms floor).
---@param bufnr number
---@param winid number? Window ID (default: current window)
function M.schedule_scroll_update(bufnr, winid)
    if not M.enabled then
        return
    end
    winid = winid or vim.api.nvim_get_current_win()
    local delay = math.max(M.config.delay, 30)
    scroll_generation = scroll_generation + 1
    scroll_timer:stop()
    pending_scroll_bufnr = bufnr
    pending_scroll_winid = winid
    scroll_timer:start(delay, 0, scroll_callback)
end

function M.enable()
    M.enabled = true
    M.schedule_update(vim.api.nvim_get_current_buf())
    utils.notify("showtime: enabled")
end

function M.disable()
    M.enabled = false
    M.cancel()
    require("showtime.engine").clear_all()
    utils.notify("showtime: disabled")
end

function M.toggle()
    if M.enabled then
        M.disable()
    else
        M.enable()
    end
end

---@return boolean
function M.is_enabled()
    return M.enabled
end

--- Jump to the next reference of the identifier under the cursor, within scope.
function M.next_reference(count)
    require("showtime.nav").next_reference(count)
end

--- Jump to the previous reference of the identifier under the cursor, within scope.
function M.prev_reference(count)
    require("showtime.nav").prev_reference(count)
end

return M
