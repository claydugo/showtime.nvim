local M = {}

local utils = require("showtime.utils")

--- Move the cursor to another reference of the identifier under it, staying
--- within the treesitter scope showtime highlights. Honors `v:count1` and
--- `wrapscan`, pushes the jumplist, and opens folds at the destination.
---@param direction number 1 for the next reference, -1 for the previous
local function goto_reference(direction, count)
    local winid = vim.api.nvim_get_current_win()
    local bufnr = vim.api.nvim_win_get_buf(winid)

    local matches, cursor_index = require("showtime.engine").references(bufnr, winid)
    if not matches then
        utils.notify("showtime: no reference under cursor", vim.log.levels.WARN)
        return
    end
    if #matches < 2 then
        utils.notify("showtime: no other references in scope", vim.log.levels.INFO)
        return
    end

    -- Anchor on the cursor's own occurrence; fall back to the first match when
    -- the cursor node somehow isn't in the collected set.
    local n = #matches
    local target
    if cursor_index then
        local idx = cursor_index + direction * count
        if vim.o.wrapscan then
            idx = (idx - 1) % n + 1
        else
            idx = math.max(1, math.min(n, idx))
        end
        target = matches[idx]
    else
        target = matches[direction > 0 and 1 or n]
    end

    local cursor = vim.api.nvim_win_get_cursor(winid)
    if cursor[1] == target[1] + 1 and cursor[2] == target[2] then
        return
    end

    -- Push the current position to the jumplist so <C-o> returns here, then move.
    -- Treesitter ranges are 0-indexed; nvim_win_set_cursor wants a 1-indexed row.
    vim.cmd("normal! m'")
    vim.api.nvim_win_set_cursor(winid, { target[1] + 1, target[2] })
    vim.cmd("silent! normal! zv")
end

function M.next_reference(count)
    goto_reference(1, count or vim.v.count1)
end

function M.prev_reference(count)
    goto_reference(-1, count or vim.v.count1)
end

return M
