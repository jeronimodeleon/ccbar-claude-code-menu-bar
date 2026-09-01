# CCBar — minimal Swift menu bar app
# No SPM dependency; compiles Sources/ directly with swiftc.

APP_NAME    := CCBar
BIN_DIR     := build
BIN         := $(BIN_DIR)/$(APP_NAME)
APP_BUNDLE  := $(BIN_DIR)/$(APP_NAME).app
SOURCES     := $(shell find Sources -name '*.swift')
SWIFTC      := xcrun swiftc
DEPLOY      := -target arm64-apple-macos14.0
OPTS        := -O -parse-as-library $(DEPLOY)
LSREGISTER  := /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister

.PHONY: run build app install test tsan clean

# Dev: register the bundle with LaunchServices, then exec the binary inside
# the bundle. The lsregister step is what populates Bundle.main with a real
# bundle proxy — without it UNUserNotificationCenter aborts on launch on
# Sonoma+. Ctrl-C stops the app.
run: app
	@$(LSREGISTER) -f $(APP_BUNDLE) 2>/dev/null || true
	@echo "Launching $(APP_NAME) (Ctrl-C to quit)…"
	@$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)

build: $(BIN)

$(BIN): $(SOURCES)
	@mkdir -p $(BIN_DIR)
	$(SWIFTC) $(OPTS) -o $(BIN) $(SOURCES)

# Bundle into a proper .app + ad-hoc code-sign. macOS Sonoma 14.6+ requires
# at least an ad-hoc signature for UNUserNotificationCenter and SMAppService
# to accept the bundle. `codesign --sign -` gives us that without needing an
# Apple Developer account.
app: $(APP_BUNDLE)

$(APP_BUNDLE): $(BIN) Resources/Info.plist
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@cp $(BIN) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@codesign --force --sign - $(APP_BUNDLE) 2>&1 | grep -v "replacing existing signature" || true
	@echo "Built $(APP_BUNDLE)"

# Install over the existing copy, wherever it lives, and register so launch
# finds the bundle. Installing blindly to ~/Applications would leave an
# already-installed /Applications copy stale — i.e. the user keeps launching
# the old binary and keeps hitting the bug they just updated to fix.
# Fresh installs land in ~/Applications, which needs no admin rights.
install: app
	@dest=$$(if [ -d /Applications/$(APP_NAME).app ]; then echo /Applications; else echo $(HOME)/Applications; fi); \
	mkdir -p "$$dest"; \
	rm -rf "$$dest/$(APP_NAME).app"; \
	cp -R $(APP_BUNDLE) "$$dest/"; \
	$(LSREGISTER) -f "$$dest/$(APP_NAME).app" 2>/dev/null || true; \
	echo "Installed to $$dest/$(APP_NAME).app"

# Pure-logic tests. CCBarApp.swift can't be linked in (it owns @main), so this
# builds only the self-contained units plus Tests/main.swift. -DDEBUG is what
# makes the selfTest() bodies exist at all — without it they compile out and
# silently "pass". Races are not covered here; use `make tsan` for those.
TEST_SOURCES := Sources/CCBar/MemoryScanner.swift Tests/main.swift

test: $(TEST_SOURCES)
	@mkdir -p $(BIN_DIR)
	@$(SWIFTC) -DDEBUG -g $(DEPLOY) -o $(BIN_DIR)/$(APP_NAME)-tests $(TEST_SOURCES)
	@$(BIN_DIR)/$(APP_NAME)-tests

# Thread Sanitizer build. The scan pile-up bug was a data race on
# ClaudeSessionScanner's cache — the class of bug unit tests never catch and
# only TSan reliably surfaces. Run this, then exercise the app (open/close the
# popover repeatedly for a few minutes); any "WARNING: ThreadSanitizer" means
# the serialization is still wrong. Unoptimized + debug info so reports are
# readable.
tsan: $(SOURCES)
	@mkdir -p $(BIN_DIR)
	$(SWIFTC) -DDEBUG -g -sanitize=thread -parse-as-library $(DEPLOY) -o $(BIN_DIR)/$(APP_NAME)-tsan $(SOURCES)
	@echo "Built $(BIN_DIR)/$(APP_NAME)-tsan — run it and exercise the menu bar."

clean:
	rm -rf $(BIN_DIR)
