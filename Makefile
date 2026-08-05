# AppMixer — SwiftPM の実行ファイルから動く .app を組み立てる。
#
# Xcode プロジェクトは不要。macOS 14.4+ / Swift 5.9+ で:
#
#   開発
#     make run                    ビルド → .app 生成 → 署名 → 起動
#     make bundle                 .app を dist/ に生成するだけ
#     make clean
#
#   リリース
#     make dist    IDENTITY="Developer ID Application: 名前 (TEAMID)"
#     make notarize KEYCHAIN_PROFILE=AppMixerNotary
#     make release  IDENTITY="..." KEYCHAIN_PROFILE=...
#
# TCC（システム音声録音）の許可とログイン項目の登録は「署名 ID」に紐づく。
# ad-hoc 署名（IDENTITY=-）だと再ビルドの度に ID が変わり、毎回聞き直される。

APP_NAME  := AppMixer
CONFIG    := release
BUILD_DIR := .build/$(CONFIG)
DIST      := dist
APP       := $(DIST)/$(APP_NAME).app
CONTENTS  := $(APP)/Contents

# Info.plist を唯一の出所にしてバージョンを取り出す。
VERSION := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" bundle/Info.plist 2>/dev/null)
ZIP     := $(DIST)/$(APP_NAME)-$(VERSION).zip

# 既定は ad-hoc 署名。配布用は Developer ID を渡すこと。
IDENTITY ?= -
# `xcrun notarytool store-credentials` で作ったプロファイル名。
KEYCHAIN_PROFILE ?=

.PHONY: all build bundle icon sign run dist notarize release clean

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

# PNG 一式（bundle/icon/AppIcon.iconset）から .icns を作る。iconutil は macOS 専用。
icon:
	@if [ ! -f bundle/icon/AppIcon.icns ]; then \
		iconutil -c icns bundle/icon/AppIcon.iconset -o bundle/icon/AppIcon.icns && \
		echo "Icon -> bundle/icon/AppIcon.icns"; \
	fi

bundle: build icon
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp bundle/Info.plist "$(CONTENTS)/Info.plist"
	@cp bundle/icon/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@echo "Bundled -> $(APP) (version $(VERSION))"

sign: bundle
	@codesign --force --options runtime --timestamp \
		--sign "$(IDENTITY)" \
		--entitlements bundle/$(APP_NAME).entitlements \
		"$(APP)"
	@echo "Signed with identity: $(IDENTITY)"
	@codesign --verify --verbose=2 "$(APP)" || true

run: sign
	@echo "Launching $(APP) ..."
	@open "$(APP)"

# 配布用の zip を作る。公証は Developer ID 署名が前提なので ad-hoc を弾く。
dist: sign
	@if [ "$(IDENTITY)" = "-" ]; then \
		echo "error: 配布には Developer ID が要ります。"; \
		echo '       make dist IDENTITY="Developer ID Application: 名前 (TEAMID)"'; exit 1; \
	fi
	@rm -f "$(ZIP)"
	@ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	@echo "Archived -> $(ZIP)"

# 公証してチケットを .app に添付する。
# 事前に一度だけ:
#   xcrun notarytool store-credentials AppMixerNotary \
#     --apple-id <Apple ID> --team-id <TEAMID> --password <アプリ用パスワード>
notarize:
	@if [ -z "$(KEYCHAIN_PROFILE)" ]; then \
		echo "error: KEYCHAIN_PROFILE を指定してください。"; \
		echo "       make notarize KEYCHAIN_PROFILE=AppMixerNotary"; exit 1; \
	fi
	@if [ ! -f "$(ZIP)" ]; then echo "error: $(ZIP) がありません。先に make dist"; exit 1; fi
	xcrun notarytool submit "$(ZIP)" --keychain-profile "$(KEYCHAIN_PROFILE)" --wait
	xcrun stapler staple "$(APP)"
	@rm -f "$(ZIP)"
	@ditto -c -k --keepParent "$(APP)" "$(ZIP)"
	@echo "Notarized and stapled -> $(ZIP)"
	@spctl --assess --type execute --verbose=2 "$(APP)" || true

release: dist notarize
	@echo
	@echo "配布物: $(ZIP)"
	@echo "この後: git tag v$(VERSION) && git push origin v$(VERSION)"

clean:
	@rm -rf .build "$(DIST)" bundle/icon/AppIcon.icns
	@echo "Cleaned."
