.PHONY: deps test lint

deps:
	@test -d .deps/plenary.nvim || \
		git clone --depth 1 https://github.com/nvim-lua/plenary.nvim .deps/plenary.nvim

test: deps
	@nvim --headless --noplugin -u tests/minimal_init.lua \
		-c "PlenaryBustedDirectory tests/showtime { minimal_init = 'tests/minimal_init.lua', sequential = true }"

lint:
	@luacheck lua/ plugin/
	@stylua --check .
