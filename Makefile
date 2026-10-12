NVIM ?= nvim
STYLUA ?= stylua
LUACHECK ?= luacheck

.PHONY: test format lint check

test:
	NVIM_LOG_FILE=$(CURDIR)/nvim.log $(NVIM) -n --headless -u NONE -i NONE -c 'luafile tests/run.lua'

format:
	$(STYLUA) lua tests examples

lint:
	$(STYLUA) --check lua tests examples
	$(LUACHECK) lua tests examples

check: test lint
	git diff --check
