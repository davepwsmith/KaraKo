LUA ?= $(shell command -v lua5.1 || command -v luajit || command -v lua)
LUAC ?= $(shell command -v luac5.1 || command -v luac)

PLUGIN_SOURCES := $(wildcard karako.koplugin/*.lua) $(wildcard spec/*.lua)
# tools/ runs inside KOReader and must set G_reader_settings, which is a global
# by KOReader's design, so it gets the syntax check but not the globals check.
ALL_SOURCES := $(PLUGIN_SOURCES) $(wildcard tools/*.lua)

.PHONY: test check all

all: check test

test:
	@$(LUA) spec/all.lua

# luac -p catches syntax errors; the SETGLOBAL grep catches accidental globals,
# which Lua otherwise accepts silently and fails on much later.
check:
	@status=0; \
	for f in $(ALL_SOURCES); do \
		if ! out=$$($(LUAC) -p "$$f" 2>&1); then \
			echo "syntax: $$f: $$out"; status=1; \
		fi; \
	done; \
	for f in $(PLUGIN_SOURCES); do \
		if $(LUAC) -l -p "$$f" 2>/dev/null | grep -q SETGLOBAL; then \
			echo "global assignment in $$f:"; \
			$(LUAC) -l -p "$$f" | grep SETGLOBAL; status=1; \
		fi; \
	done; \
	[ $$status -eq 0 ] && echo "check: $(words $(ALL_SOURCES)) files OK"; \
	exit $$status
