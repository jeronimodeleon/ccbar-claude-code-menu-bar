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

.PHONY: run build app install clean

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

# Install to ~/Applications and register so first launch finds the bundle.
install: app
	@mkdir -p $(HOME)/Applications
	@rm -rf $(HOME)/Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) $(HOME)/Applications/
	@$(LSREGISTER) -f $(HOME)/Applications/$(APP_NAME).app 2>/dev/null || true
	@echo "Installed to ~/Applications/$(APP_NAME).app"

clean:
	rm -rf $(BIN_DIR)
