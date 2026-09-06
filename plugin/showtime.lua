if vim.g.loaded_showtime then
    return
end
vim.g.loaded_showtime = true

vim.api.nvim_set_hl(0, "ShowtimeReference", { default = true, link = "LspReferenceText" })

vim.api.nvim_create_user_command("ShowtimeEnable", function()
    require("showtime").enable()
end, { desc = "Enable showtime reference highlighting" })

vim.api.nvim_create_user_command("ShowtimeDisable", function()
    require("showtime").disable()
end, { desc = "Disable showtime reference highlighting" })

vim.api.nvim_create_user_command("ShowtimeToggle", function()
    require("showtime").toggle()
end, { desc = "Toggle showtime reference highlighting" })

vim.api.nvim_create_user_command("ShowtimeNextReference", function(args)
    require("showtime").next_reference(args.count)
end, { count = 1, desc = "Jump to the next reference in scope" })

vim.api.nvim_create_user_command("ShowtimePrevReference", function(args)
    require("showtime").prev_reference(args.count)
end, { count = 1, desc = "Jump to the previous reference in scope" })

-- No default keymaps. Bind these <Plug> mappings yourself if you want motions.
vim.keymap.set("n", "<Plug>(showtime-next-reference)", function()
    require("showtime").next_reference()
end, { desc = "Jump to the next reference in scope" })

vim.keymap.set("n", "<Plug>(showtime-prev-reference)", function()
    require("showtime").prev_reference()
end, { desc = "Jump to the previous reference in scope" })

local group = vim.api.nvim_create_augroup("showtime", { clear = true })

vim.api.nvim_create_autocmd({ "CursorMoved", "BufWinEnter", "WinEnter", "InsertLeave", "TextChanged", "FileType" }, {
    group = group,
    callback = function(args)
        local winid = vim.api.nvim_get_current_win()
        require("showtime").schedule_update(args.buf, winid)
    end,
})

vim.api.nvim_create_autocmd("WinScrolled", {
    group = group,
    callback = function(args)
        -- args.match is the first scrolled/resized window id (may differ from current window).
        local winid = vim.api.nvim_get_current_win()
        if not vim.v.event[tostring(winid)] and tonumber(args.match) ~= winid then
            return
        end
        local bufnr = vim.api.nvim_win_get_buf(winid)
        require("showtime.engine").invalidate_cache(winid)
        require("showtime").schedule_scroll_update(bufnr, winid)
    end,
})

vim.api.nvim_create_autocmd({ "BufLeave", "WinLeave", "InsertEnter" }, {
    group = group,
    callback = function(args)
        require("showtime").cancel()
        require("showtime.engine").clear(args.buf)
    end,
})

vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function(args)
        local winid = tonumber(args.match)
        if winid then
            require("showtime.engine").cleanup_window(winid)
        end
    end,
})

vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = group,
    callback = function(args)
        require("showtime.engine").cleanup_buffer(args.buf)
    end,
})

vim.api.nvim_create_autocmd("ColorScheme", {
    group = group,
    callback = function()
        local config = require("showtime").config
        vim.api.nvim_set_hl(0, config.hl_group, { default = true, link = "LspReferenceText" })
    end,
})

require("showtime").schedule_update(vim.api.nvim_get_current_buf())
