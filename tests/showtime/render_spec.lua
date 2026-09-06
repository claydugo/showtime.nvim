describe("showtime rendering", function()
    it("tracks focus, folds, and Insert mode without stale highlights", function()
        local cells = {}
        local attributes = {}
        local input = vim.uv.new_pipe(false)
        local output = vim.uv.new_pipe(false)
        local errors = vim.uv.new_pipe(false)
        local responses = {}
        local request_count = 0
        local unpacker = vim.mpack.Unpacker()
        local stderr = ""
        local child = assert(vim.uv.spawn(vim.v.progpath, {
            args = { "--embed", "--headless", "--clean", "-i", "NONE" },
            stdio = { input, output, errors },
        }, function() end))
        errors:read_start(function(_, data)
            stderr = stderr .. (data or "")
        end)
        output:read_start(function(_, data)
            if not data then
                return
            end
            local position = 1
            while position <= #data do
                local message
                message, position = unpacker(data, position)
                if message and message[1] == 1 then
                    responses[message[2]] = message
                elseif message and message[1] == 2 and message[2] == "redraw" then
                    for _, event in ipairs(message[3]) do
                        for index = 2, #event do
                            local arguments = event[index]
                            if event[1] == "hl_attr_define" then
                                attributes[arguments[1]] = arguments[2]
                            elseif event[1] == "grid_clear" then
                                cells[arguments[1]] = {}
                            elseif event[1] == "grid_line" then
                                local grid, row, column = arguments[1], arguments[2], arguments[3]
                                cells[grid] = cells[grid] or {}
                                cells[grid][row] = cells[grid][row] or {}
                                local attribute = 0
                                for _, cell in ipairs(arguments[4]) do
                                    attribute = cell[2] or attribute
                                    for _ = 1, cell[3] or 1 do
                                        cells[grid][row][column] = attribute
                                        column = column + 1
                                    end
                                end
                            end
                        end
                    end
                end
            end
        end)
        local function request(method, ...)
            request_count = request_count + 1
            local identifier = request_count
            input:write(vim.mpack.encode({ 0, identifier, method, { ... } }))
            assert(
                vim.wait(1000, function()
                    return responses[identifier] ~= nil
                end),
                stderr
            )
            local response = responses[identifier]
            assert(response[3] == vim.NIL, vim.inspect(response[3]))
            return response[4]
        end
        local function highlighted(position)
            local row = cells[1] and cells[1][position.row - 1]
            local attribute = row and attributes[row[position.col - 1]]
            return attribute and attribute.background == 0xaa00ff
        end
        local ok, failure = xpcall(function()
            request("nvim_ui_attach", 80, 20, { ext_linegrid = true })
            local positions = request(
                "nvim_exec_lua",
                [[
                vim.opt.runtimepath:prepend(...)
                vim.cmd("runtime plugin/showtime.lua")
                vim.bo.filetype = "lua"
                vim.api.nvim_buf_set_lines(0, 0, -1, false, { "local value = 1", "print(value, value)", "" })
                vim.api.nvim_win_set_cursor(0, { 1, 6 })
                vim.cmd("vsplit")
                vim.api.nvim_set_hl(0, "ShowtimeReference", { bg = "#aa00ff" })
                require("showtime").setup()
                vim.cmd("redraw")
                local windows = vim.api.nvim_list_wins()
                return {
                    vim.fn.screenpos(windows[1], 2, 7),
                    vim.fn.screenpos(windows[2], 2, 7),
                    windows,
                }
            ]],
                { vim.fn.getcwd() }
            )
            assert.is_true(vim.wait(1000, function()
                return highlighted(positions[1])
            end))
            assert.is_not_true(highlighted(positions[2]))
            request("nvim_set_current_win", positions[3][2])
            request("nvim_command", "redraw")
            assert.is_true(vim.wait(1000, function()
                return highlighted(positions[2]) and not highlighted(positions[1])
            end))
            request(
                "nvim_exec_lua",
                [[
                vim.wo.foldmethod = "manual"
                vim.cmd("2,3fold")
                vim.cmd("redraw")
            ]],
                {}
            )
            vim.wait(100, function()
                return false
            end)
            assert.is_not_true(highlighted(positions[2]))
            request("nvim_command", "normal! zR")
            assert.is_true(vim.wait(1000, function()
                return highlighted(positions[2])
            end))
            request(
                "nvim_exec_lua",
                [[
                local showtime = require("showtime")
                showtime.setup({ delay = 40 })
                require("showtime.engine").update(vim.api.nvim_get_current_buf())
                showtime.schedule_update(vim.api.nvim_get_current_buf())
                showtime.schedule_scroll_update(vim.api.nvim_get_current_buf())
                vim.api.nvim_input("i")
            ]],
                {}
            )
            assert.is_true(vim.wait(1000, function()
                return request("nvim_get_mode").mode == "i" and not highlighted(positions[2])
            end))
            vim.wait(100, function()
                return highlighted(positions[2])
            end)
            assert.is_not_true(highlighted(positions[2]))
        end, debug.traceback)
        child:kill("sigterm")
        input:close()
        output:close()
        errors:close()
        child:close()
        assert(ok, tostring(failure))
    end)
end)
