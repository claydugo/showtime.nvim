local showtime = require("showtime")

describe("showtime health", function()
    it("checks source buffers and resolves highlight links", function()
        local source = vim.api.nvim_create_buf(false, true)
        vim.bo[source].buftype = ""
        vim.bo[source].filetype = "lua"
        local missing = vim.api.nvim_create_buf(false, true)
        vim.bo[missing].buftype = ""
        vim.bo[missing].filetype = "showtime_missing_parser"
        vim.api.nvim_set_current_buf(source)
        vim.api.nvim_set_hl(0, "ShowtimeEmptyTarget", {})
        vim.api.nvim_set_hl(0, "ShowtimeReference", { link = "ShowtimeEmptyTarget" })
        showtime.setup()
        vim.cmd("checkhealth showtime")
        local report = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), "\n")
        assert.is_not_nil(report:find("Parser available for filetype: lua", 1, true))
        assert.is_not_nil(report:find("No parser available for filetype: showtime_missing_parser", 1, true))
        assert.is_not_nil(report:find("{ShowtimeReference} has no attributes", 1, true))
        assert.is_nil(report:find("Parser available for filetype: checkhealth", 1, true))
        vim.api.nvim_buf_delete(source, { force = true })
        vim.api.nvim_buf_delete(missing, { force = true })
        showtime.cancel()
    end)
end)
