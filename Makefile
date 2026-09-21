PREFIX ?= /Applications

APP = build/Reaper.app

# Built as a bare bundle rather than through Xcode so the whole project stays
# `make && make install`. Ad-hoc signed: it is only ever installed locally, and
# the login item is a LaunchAgent rather than SMAppService precisely so no
# Developer ID is needed.
#
# Order matters for the two files carrying top-level code: none here does, but
# main.swift must come last for swiftc to accept it as the entry point.
SWIFT = app/Core.swift app/Watch.swift app/Rules.swift app/StatusArt.swift \
        app/ProcessWindow.swift app/DetailWindow.swift app/main.swift

all: $(APP)

$(APP): $(SWIFT) app/Info.plist app/Reaper.icns
	@rm -rf $(APP)
	@mkdir -p $(APP)/Contents/MacOS $(APP)/Contents/Resources
	swiftc -O -target arm64-apple-macos13.0  -o build/.Reaper-arm64  $(SWIFT)
	swiftc -O -target x86_64-apple-macos13.0 -o build/.Reaper-x86_64 $(SWIFT)
	lipo -create -output $(APP)/Contents/MacOS/Reaper build/.Reaper-arm64 build/.Reaper-x86_64
	@rm -f build/.Reaper-arm64 build/.Reaper-x86_64
	cp app/Info.plist $(APP)/Contents/Info.plist
	cp app/Reaper.icns $(APP)/Contents/Resources/Reaper.icns
	codesign --force --sign - $(APP)
	@echo "built $(APP)"

app: $(APP)

# Logic checks: the rules and their states, the sustain clock, what may be
# killed, and the formatting the windows rely on. No window is created, so this
# runs on a headless runner.
test: build/tests
	./build/tests

# Every app file but main.swift, which carries top-level code and so cannot be
# linked into anything else. Linking the windows too means the suite compiles
# them, even though it never opens one.
TEST_SRC = tests/Tests.swift tests/RuleTests.swift tests/WatchTests.swift \
           tests/ViewTests.swift \
           app/Core.swift app/Watch.swift app/Rules.swift app/StatusArt.swift \
           app/ProcessWindow.swift app/DetailWindow.swift

build/tests: $(TEST_SRC)
	@mkdir -p build
	swiftc -o $@ $(TEST_SRC)

# Copying the bundle is the whole install: nothing runs as root, nothing is
# written outside the bundle, and "Start at Login" is a per-user LaunchAgent the
# app writes itself.
install: $(APP)
	rm -rf $(PREFIX)/Reaper.app
	cp -R $(APP) $(PREFIX)/Reaper.app
	@echo "installed $(PREFIX)/Reaper.app -- open it to put the mark in the menu bar"

uninstall:
	rm -rf $(PREFIX)/Reaper.app
	rm -f $(HOME)/Library/LaunchAgents/com.local.reaper.plist
	@echo "removed the app and the login item. Settings stay in defaults;"
	@echo "run: defaults delete com.local.reaper"

clean:
	rm -rf build

.PHONY: all app test install uninstall clean
