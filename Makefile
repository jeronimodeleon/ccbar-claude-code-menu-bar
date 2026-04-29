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

.PHONY: run build app install clean

# Dev: build + launch the .app bundle directly so Bundle.main has a real
# bundle ID + Info.plist (required by UNUserNotificationCenter and friends).
# Ctrl-C in this terminal stops the app.
run: app
	@echo "Launching $(APP_NAME) (Ctrl-C to quit)…"
	@$(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)

build: $(BIN)

$(BIN): $(SOURCES)
	@mkdir -p $(BIN_DIR)
	$(SWIFTC) $(OPTS) -o $(BIN) $(SOURCES)

# Bundle into a proper .app (so Finder/Login Items work)
app: $(APP_BUNDLE)

$(APP_BUNDLE): $(BIN) Resources/Info.plist
	@rm -rf $(APP_BUNDLE)
	@mkdir -p $(APP_BUNDLE)/Contents/MacOS
	@cp $(BIN) $(APP_BUNDLE)/Contents/MacOS/$(APP_NAME)
	@cp Resources/Info.plist $(APP_BUNDLE)/Contents/Info.plist
	@echo "Built $(APP_BUNDLE)"

# Install to ~/Applications (no admin required)
install: app
	@mkdir -p $(HOME)/Applications
	@rm -rf $(HOME)/Applications/$(APP_NAME).app
	@cp -R $(APP_BUNDLE) $(HOME)/Applications/
	@echo "Installed to ~/Applications/$(APP_NAME).app"

clean:
	rm -rf $(BIN_DIR)
