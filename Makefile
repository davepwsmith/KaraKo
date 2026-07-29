LUA ?= $(shell command -v lua5.1 || command -v luajit || command -v lua)
LUAC ?= $(shell command -v luac5.1 || command -v luac)

SOURCES := $(wildcard karakeep.koplugin/*.lua) $(wildcard spec/*.lua)

.PHONY: test check all

all: check test

test:
	@$(LUA) spec/all.lua

# luac -p catches syntax errors; the SETGLOBAL grep catches accidental globals,
# which Lua otherwise accepts silently and fails on much later.
check:
	@status=0; \
	for f in $(SOURCES); do \
		if ! out=$$($(LUAC) -p "$$f" 2>&1); then \
			echo "syntax: $$f: $$out"; status=1; \
		elif $(LUAC) -l -p "$$f" 2>/dev/null | grep -q SETGLOBAL; then \
			echo "global assignment in $$f:"; \
			$(LUAC) -l -p "$$f" | grep SETGLOBAL; status=1; \
		fi; \
	done; \
	[ $$status -eq 0 ] && echo "check: $(words $(SOURCES)) files OK"; \
	exit $$status
