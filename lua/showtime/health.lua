local M = {}

--- Check a highlight group and report its resolved attributes.
--- @param name string
local function check_highlight(name)
    local hl = vim.api.nvim_get_hl(0, { name = name })
    if not hl or not next(hl) then
        vim.health.warn("{" .. name .. "} has no attributes, references may be invisible", {
            'Define it manually: `vim.api.nvim_set_hl(0, "' .. name .. '", { bg = "#2a2a3a" })`',
        })
        return
    end

    local attrs = {}
    if hl.link then
        attrs[#attrs + 1] = "link=" .. hl.link
    end
    if hl.bg then
        attrs[#attrs + 1] = string.format("bg=#%06x", hl.bg)
    end
    if hl.fg then
        attrs[#attrs + 1] = string.format("fg=#%06x", hl.fg)
    end
    if hl.underline then
        attrs[#attrs + 1] = "underline"
    end
    if hl.bold then
        attrs[#attrs + 1] = "bold"
    end
    if hl.italic then
        attrs[#attrs + 1] = "italic"
    end

    vim.health.ok("{" .. name .. "} defined (" .. table.concat(attrs, ", ") .. ")")
end

function M.check()
    vim.health.start("showtime.nvim")

    -- Version
    local version = require("showtime.version")
    vim.health.info("version: `" .. version .. "`")

    -- Requirements
    if vim.fn.has("nvim-0.11") == 1 then
        vim.health.ok("Neovim >= 0.11")
    else
        vim.health.error("showtime.nvim requires Neovim >= 0.11", {
            "Update Neovim to 0.11 or later",
        })
        return
    end

    -- Treesitter
    local bufnr = vim.api.nvim_get_current_buf()
    local ft = vim.bo[bufnr].filetype
    local parser_ok, _ = pcall(vim.treesitter.get_parser, bufnr)
    if parser_ok then
        vim.health.ok("treesitter parser available for current buffer (ft: `" .. ft .. "`)")
    else
        vim.health.warn("no treesitter parser for current buffer (ft: `" .. ft .. "`)", {
            "Install a parser: `:TSInstall " .. ft .. "`",
            "Highlighting will not work in buffers without a parser",
        })
    end

    -- Configuration
    local config = require("showtime.config").options
    vim.health.info("delay: `" .. config.delay .. "ms`")
    vim.health.info("hl_group: `" .. config.hl_group .. "`")
    vim.health.info("max_matches: `" .. config.max_matches .. "`")
    vim.health.info("min_matches: `" .. config.min_matches .. "`")

    if #config.exclude_languages > 0 then
        vim.health.info("exclude_languages: `" .. table.concat(config.exclude_languages, ", ") .. "`")
    end
    if #config.exclude_buftypes > 0 then
        vim.health.info("exclude_buftypes: `" .. table.concat(config.exclude_buftypes, ", ") .. "`")
    end

    -- Highlights
    check_highlight(config.hl_group)

    -- Status
    local showtime = require("showtime")
    if showtime.enabled then
        vim.health.ok("plugin is enabled")
    else
        vim.health.info("plugin is currently disabled")
    end
end

return M
