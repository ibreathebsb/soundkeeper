# Sound Keeper for macOS. Everything is built with Swift Package Manager; Xcode is not required.

APPDIR ?= /Applications

# Swift Testing needs a hint when only Command Line Tools are installed.
TESTING_PLUGINS := $(shell xcode-select -p 2>/dev/null)/usr/lib/swift/host/plugins/testing
ifneq ($(wildcard $(TESTING_PLUGINS)),)
TEST_FLAGS := -Xswiftc -plugin-path -Xswiftc $(TESTING_PLUGINS)
endif

.PHONY: app run install uninstall package test icon clean

# build/SoundKeeper.app (the menu bar app) and build/soundkeeper (the command line tool).
app:
	./scripts/build-app.sh

# Starts the freshly built app. A running Sound Keeper is replaced by it.
run: app
	open build/SoundKeeper.app

# Copies the app to /Applications and starts it from there.
install: app
	-./build/soundkeeper kill >/dev/null 2>&1
	rm -rf "$(APPDIR)/SoundKeeper.app"
	cp -R build/SoundKeeper.app "$(APPDIR)/SoundKeeper.app"
	open "$(APPDIR)/SoundKeeper.app"
	@echo "Installed $(APPDIR)/SoundKeeper.app. Turn on \"Start at Login\" in its menu to keep it running."

# Removes the app, its login item and its files.
uninstall:
	-./build/soundkeeper kill >/dev/null 2>&1
	-./build/soundkeeper uninstall >/dev/null 2>&1
	rm -rf "$(APPDIR)/SoundKeeper.app" "$(HOME)/Library/Application Support/SoundKeeper"
	-defaults delete local.soundkeeper >/dev/null 2>&1
	@echo "Sound Keeper is removed."

# dist/SoundKeeper-<version>-macos-<arch>.zip: the app and the command line tool, ready to be given to someone.
package: app
	./scripts/package.sh

test:
	swift test $(TEST_FLAGS)

# Redraws Resources/AppIcon.icns.
icon:
	swift scripts/make-icon.swift Resources/AppIcon.icns

clean:
	rm -rf .build build dist
