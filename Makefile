# AppMixer — build a runnable .app from the SwiftPM executable.
#
# Xcode は不要。macOS 14.4+ / Swift 5.9+ で:
#   make run                 # ビルド → .app 生成 → 署名 → 起動
#   make bundle              # .app を dist/ に生成するだけ
#   make sign IDENTITY="..." # 署名 ID を指定（TCC 許可を再ビルド後も維持したい場合に推奨）
#   make clean
#
# TCC（システム音声録音）の許可は「署名 ID」に紐づく。
# ad-hoc 署名（IDENTITY=-）だと再ビルドの度に ID が変わり、毎回プロンプトが出る。
# 安定させたい場合は自己署名証明書を作り IDENTITY にその名前を渡すこと（README 参照）。

APP_NAME  := AppMixer
CONFIG    := release
BUILD_DIR := .build/$(CONFIG)
DIST      := dist
APP       := $(DIST)/$(APP_NAME).app
CONTENTS  := $(APP)/Contents

# 既定は ad-hoc 署名。安定 ID を使うなら `make run IDENTITY="Apple Development: ..."`
IDENTITY ?= -

.PHONY: all build bundle sign run clean

all: sign

# Process Tap API は macOS 14.4 SDK 以降でしか解決できない（Xcode 15.3+）。
# 古い SDK だと "cannot find 'CATapDescription' in scope" になるため事前に検査する。
build:
	@sdk="$$(xcrun --show-sdk-version 2>/dev/null)"; \
	major="$${sdk%%.*}"; minor="$$(echo "$$sdk" | cut -d. -f2)"; minor="$${minor:-0}"; \
	if [ -z "$$sdk" ] || [ "$$major" -lt 14 ] || { [ "$$major" -eq 14 ] && [ "$$minor" -lt 4 ]; }; then \
		echo "error: macOS 14.4 SDK 以降が必要です (Xcode 15.3+)。検出: $${sdk:-none}"; exit 1; \
	fi
	swift build -c $(CONFIG)

bundle: build
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS"
	@mkdir -p "$(CONTENTS)/Resources"
	@cp bundle/Info.plist "$(CONTENTS)/Info.plist"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@echo "Bundled -> $(APP)"

sign: bundle
	@codesign --force --options runtime \
		--sign "$(IDENTITY)" \
		--entitlements bundle/$(APP_NAME).entitlements \
		"$(APP)"
	@echo "Signed with identity: $(IDENTITY)"
	@codesign --verify --verbose=2 "$(APP)" || true

run: sign
	@echo "Launching $(APP) ..."
	@open "$(APP)"

clean:
	@rm -rf .build "$(DIST)"
	@echo "Cleaned."
