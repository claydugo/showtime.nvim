local config = require("showtime.config")

local function with_captured_notify(fn)
    local captured = {}
    local original = vim.notify
    vim.notify = function(msg, level)
        captured[#captured + 1] = { msg = msg, level = level }
    end
    local ok, err = pcall(fn)
    vim.notify = original
    assert(ok, err)
    return captured
end

describe("showtime.config", function()
    before_each(function()
        config.setup()
    end)

    describe("defaults", function()
        it("applies defaults when setup() is called with no args", function()
            assert.are.equal(0, config.options.delay)
            assert.are.equal("ShowtimeReference", config.options.hl_group)
            assert.are.equal(500, config.options.max_matches)
            assert.are.equal(2, config.options.min_matches)
            assert.are.same({}, config.options.exclude_languages)
            assert.are.same({ "nofile", "terminal", "prompt" }, config.options.exclude_buftypes)
        end)

        it("builds derived sets for O(1) lookup", function()
            config.setup({ exclude_languages = { "markdown", "help" } })
            assert.is_true(config.options._lang_set.markdown)
            assert.is_true(config.options._lang_set.help)
            assert.is_nil(config.options._lang_set.lua)

            assert.is_true(config.options._bt_set.nofile)
            assert.is_true(config.options._bt_set.terminal)
        end)

        it("resets cleanly when setup() is called with no args after a prior config", function()
            config.setup({ delay = 999 })
            assert.are.equal(999, config.options.delay)
            config.setup()
            assert.are.equal(0, config.options.delay)
        end)
    end)

    describe("merge", function()
        it("merges partial opts on top of defaults", function()
            config.setup({ delay = 200 })
            assert.are.equal(200, config.options.delay)
            assert.are.equal(500, config.options.max_matches) -- default preserved
            assert.are.equal(2, config.options.min_matches)
        end)
    end)

    describe("validation", function()
        it("warns and strips unknown keys", function()
            local notes = with_captured_notify(function()
                config.setup({ foo = "bar", delay = 50 })
            end)
            assert.are.equal(50, config.options.delay)
            assert.is_nil(config.options.foo)
            local saw_unknown = false
            for _, n in ipairs(notes) do
                if n.msg:find("unknown option") then
                    saw_unknown = true
                end
            end
            assert.is_true(saw_unknown)
        end)

        it("clamps negative delay to 0", function()
            with_captured_notify(function()
                config.setup({ delay = -100 })
            end)
            assert.are.equal(0, config.options.delay)
        end)

        it("clamps non-positive max_matches to 1", function()
            with_captured_notify(function()
                config.setup({ max_matches = 0 })
            end)
            assert.are.equal(1, config.options.max_matches)
        end)

        it("clamps min_matches < 1 to 1", function()
            with_captured_notify(function()
                config.setup({ min_matches = 0 })
            end)
            assert.are.equal(1, config.options.min_matches)
        end)

        it("rejects empty hl_group and falls back to default", function()
            with_captured_notify(function()
                config.setup({ hl_group = "" })
            end)
            assert.are.equal("ShowtimeReference", config.options.hl_group)
        end)

        it("rejects wrong types and keeps the previous config intact", function()
            config.setup({ delay = 100 })
            with_captured_notify(function()
                config.setup({ delay = "not a number" })
            end)
            assert.are.equal(100, config.options.delay)
        end)

        it("validates scope_nodes shape", function()
            local notes = with_captured_notify(function()
                config.setup({ scope_nodes = { lua = "not a table" } })
            end)
            -- Validation failed → previous (default) config is kept.
            assert.is_nil(config.options.scope_nodes)
            assert.is_true(#notes > 0)
        end)

        it("accepts a well-formed scope_nodes override", function()
            config.setup({ scope_nodes = { lua = { for_statement = true } } })
            assert.is_true(config.options.scope_nodes.lua.for_statement)
        end)
    end)
end)
