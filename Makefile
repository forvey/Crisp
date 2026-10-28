# Crisp — convenience wrappers around the existing build scripts.
#
# Fast dev loop (Command Line Tools only, no Xcode):
#   make dev        compile, swap the binary into /Applications/Crisp.app, relaunch
#   make compile    compile the binary only (./Crisp-bin), no swap — quick build check
#   make test       generate the Xcode project and run unit tests
#   make check      lint + tests + localization keys + audio driver checks: run before pushing
#                   (auto-run on every push after: git config core.hooksPath .githooks)
#
# Distributable DMG:
#   make build      signed universal (arm64 + x86_64) DMG via scripts/release.sh (dry run)
#   make dmg        DMG via Xcode (scripts/build-dmg.sh; needs full Xcode + xcodegen)
#   make release ARGS="vX.Y.Z notes.md --publish"   full release (see scripts/release.sh)
#
#   make clean      remove build artifacts
#   make help       list targets (default)
#
# The dev target honours dev.sh's CRISP_APP override, e.g.:
#   make dev CRISP_APP=/path/to/Crisp.app

# Single source of truth for the version: project.yml (used to tag the dry-run DMG).
VERSION := $(shell grep -E '^[[:space:]]*MARKETING_VERSION:' project.yml | head -1 | sed -E 's/.*"([^"]+)".*/\1/')

# Use Xcode.app's toolchain when installed, even if xcode-select still points at
# the Command Line Tools: xcodebuild (test) and SwiftLint's SourceKit need it.
ifneq (,$(wildcard /Applications/Xcode.app))
export DEVELOPER_DIR ?= /Applications/Xcode.app/Contents/Developer
# git hooks inherit SDKROOT for the Command Line Tools SDK from the git shim; with
# Xcode's swiftc that pairs a compiler and an SDK of different Swift versions.
unexport SDKROOT
endif

# swiftc invocation kept in sync with dev.sh's compile step.
SWIFT_SOURCES := Crisp/App/*.swift Crisp/Models/*.swift Crisp/Services/*.swift \
                 Crisp/Views/*.swift Crisp/Utilities/*.swift
SWIFTC_FLAGS := -O -swift-version 6 -parse-as-library \
                -import-objc-header Crisp/Crisp-Bridging-Header.h \
                -framework AppKit -framework SwiftUI -framework IOKit -framework CoreAudio \
                -F vendor/Sparkle -framework Sparkle \
                -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
                -Xlinker -undefined -Xlinker dynamic_lookup

.DEFAULT_GOAL := help
.PHONY: help dev compile test lint loc-check check build dmg release clean vendor audio-driver-test

# Sparkle framework, pinned + cached in vendor/ (needed to compile and to
# generate the Xcode project's framework reference).
vendor:
	@./scripts/fetch-sparkle.sh

help:
	@echo "Crisp — make targets:"
	@echo "  make dev        compile + swap into /Applications/Crisp.app + relaunch (dev.sh)"
	@echo "  make compile    compile ./Crisp-bin only, no swap (quick build check)"
	@echo "  make test       generate the Xcode project and run unit tests"
	@echo "  make check      lint + tests + localization keys + audio driver checks"
	@echo "  make build      signed universal DMG, needs Xcode (scripts/release.sh v$(VERSION))"
	@echo "  make dmg        DMG via Xcode (scripts/build-dmg.sh)"
	@echo "  make release ARGS=\"vX.Y.Z notes.md --publish\"   full release (scripts/release.sh)"
	@echo "  make clean      remove build artifacts (Crisp-bin, build/, Crisp.dmg)"

dev:
	./dev.sh

compile: vendor
	@echo "==> Compiling Crisp $(VERSION) -> ./Crisp-bin"
	swiftc $(SWIFTC_FLAGS) $(SWIFT_SOURCES) -o Crisp-bin
	@echo "Done. ./Crisp-bin built (not swapped into the app; use 'make dev' for that)."

# Warnings are errors here (the baseline is zero, issue #47), so a PR that
# introduces one fails make check and CI. `make compile` stays permissive for
# mid-iteration builds.
test: vendor
	xcodegen generate
	xcodebuild -quiet test -project Crisp.xcodeproj -scheme Crisp \
		-destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO \
		SWIFT_TREAT_WARNINGS_AS_ERRORS=YES

lint:
	@command -v swiftlint >/dev/null || { echo "SwiftLint not installed: brew install swiftlint"; exit 1; }
	swiftlint lint --strict --quiet

# Same check as CI's "Check localization keys" step: every key the code uses
# must exist in the String Catalog (missing keys silently fall back to English).
# The export writes every key it extracts into the catalog, so the check would pass
# for a key the committed catalog lacks. Put the file back before checking it.
loc-check: vendor
	xcodegen generate
	mkdir -p build && cp Crisp/Resources/Localizable.xcstrings build/Localizable.xcstrings.orig
	xcodebuild -quiet -exportLocalizations -project Crisp.xcodeproj \
		-localizationPath build/loc CODE_SIGNING_ALLOWED=NO \
		SWIFT_EMIT_LOC_STRINGS=YES; status=$$?; \
		cp build/Localizable.xcstrings.orig Crisp/Resources/Localizable.xcstrings; exit $$status
	python3 scripts/check-localization-keys.py build/loc/en.xcloc \
		Crisp/Resources/Localizable.xcstrings scripts/i18n-missing-allowlist.txt

# Exercise the virtual input driver without installing it or opening audio devices.
audio-driver-test:
	mkdir -p build/audio-evidence
	xcrun clang -std=c11 -fblocks -O2 -Wall -Wextra -Werror -Wno-unused-parameter \
		-framework CoreAudio -framework CoreFoundation AudioDriver/CrispRemoteMicrophone.c \
		Tests/RemoteAudio/AudioDriverTests.c -o build/audio-evidence/driver-tests
	build/audio-evidence/driver-tests

check: lint test loc-check audio-driver-test
	@echo "check passed: lint clean, tests green, localization keys complete, audio driver checks passed"

build:
	./scripts/release.sh v$(VERSION)

dmg:
	./scripts/build-dmg.sh

release:
	./scripts/release.sh $(ARGS)

clean:
	rm -f Crisp-bin Crisp.dmg
	rm -rf build
	@echo "Cleaned: Crisp-bin, Crisp.dmg, build/"
