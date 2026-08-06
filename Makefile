# AppMixer — SwiftPM の実行ファイルから動く .app を組み立てる。
#
# Xcode プロジェクトは不要。macOS 14.4+ / Swift 5.9+ で:
#
#   開発
#     make run                    ビルド → .app 生成 → 署名 → 起動
#     make bundle                 .app を dist/ に生成するだけ
#     make clean
#
#   リリース（Mac App Store）
#     make clean                  前回の残りを消してから作り直す
#     make run-sandboxed          サンドボックスを有効にして起動（動作確認用）
#     make mas     MAS_IDENTITY="Apple Distribution: 名前 (TEAMID)" \
#                  MAS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: 名前 (TEAMID)" \
#                  PROVISION_PROFILE=AppMixer.provisionprofile
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

# CFBundleVersion は「前のリリースより必ず大きい」ことだけが求められる。
# 手で上げ忘れると、新しい版を入れても OS が古いままだと見なすことがある。
# 表示用バージョンから機械的に導いて、上げ忘れを起こさないようにする。
# 例: 0.1.0 -> 100 / 1.2.3 -> 10203
BUILD_NUMBER ?= $(shell echo "$(VERSION)" | awk -F. '{ printf "%d", ($$1*10000)+($$2*100)+$$3 }')

# 開発中の署名。既定は ad-hoc。提出用は下の MAS_IDENTITY を使う。
IDENTITY ?= -

# Mac App Store 用。開発用とは証明書もパッケージの形も別。
MAS_IDENTITY ?=
MAS_INSTALLER_IDENTITY ?=
PROVISION_PROFILE ?=
MAS_APP := $(DIST)/mas/$(APP_NAME).app
PKG     := $(DIST)/$(APP_NAME)-$(VERSION).pkg

# App Store の署名には、バンドル ID とチーム ID を焼いたエンタイトルメントが要る。
# 署名 ID の末尾の括弧がチーム ID なので、そこから取り出す（渡し忘れを減らす）。
TEAM_ID  ?= $(shell echo "$(MAS_IDENTITY)" | sed -n 's/.*(\([A-Z0-9]*\))$$/\1/p')
BUNDLE_ID := $(shell /usr/libexec/PlistBuddy -c "Print :CFBundleIdentifier" bundle/Info.plist 2>/dev/null)
# 提出時だけ使う、組み立て済みのエンタイトルメント。
MAS_ENTITLEMENTS := $(DIST)/mas/entitlements.plist

.PHONY: all build bundle icon sign run clean check-version run-sandboxed mas check-mas

# 署名やアーカイブは同じ .app を触るため、並列に走らせると壊れる。
.NOTPARALLEL:

all: sign

# バージョンが読めないまま進むと、名前が AppMixer-.pkg の提出物ができてしまう。
check-version:
	@if [ -z "$(VERSION)" ]; then \
		echo "error: bundle/Info.plist から CFBundleShortVersionString を読めません。"; exit 1; \
	fi

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

bundle: check-version build icon
	@rm -rf "$(APP)"
	@mkdir -p "$(CONTENTS)/MacOS" "$(CONTENTS)/Resources"
	@cp bundle/Info.plist "$(CONTENTS)/Info.plist"
	@/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $(BUILD_NUMBER)" "$(CONTENTS)/Info.plist"
	@cp bundle/icon/AppIcon.icns "$(CONTENTS)/Resources/AppIcon.icns"
	@cp "$(BUILD_DIR)/$(APP_NAME)" "$(CONTENTS)/MacOS/$(APP_NAME)"
	@printf 'APPL????' > "$(CONTENTS)/PkgInfo"
	@echo "Bundled -> $(APP) (version $(VERSION), build $(BUILD_NUMBER))"

sign: bundle
	@codesign --force --timestamp \
		--sign "$(IDENTITY)" \
		--entitlements bundle/$(APP_NAME).entitlements \
		"$(APP)"
	@echo "Signed with identity: $(IDENTITY)"
	@codesign --verify --strict --verbose=2 "$(APP)"

run: sign
	@echo "Launching $(APP) ..."
	@open "$(APP)"

# --- Mac App Store ---------------------------------------------------------
#
# 提出には開発用とは別の証明書が要る（Apple Distribution と 3rd Party Mac
# Developer Installer の 2 枚）。App Sandbox を付け、pkg にして提出する。

# サンドボックスを有効にして起動する。App Store 版が成立するかを見るための的。
# Process Tap と集約デバイスの生成がここで通らなければ、App Store には出せない。
#
#   make run-sandboxed IDENTITY="AppMixer Dev"
#   log stream --predicate 'subsystem == "io.github.iam74k4.AppMixer"'
run-sandboxed: bundle
	@codesign --force --sign "$(IDENTITY)" \
		--entitlements bundle/$(APP_NAME).mas.entitlements \
		"$(APP)"
	@codesign --display --entitlements - "$(APP)" 2>&1 | grep -q app-sandbox \
		&& echo "App Sandbox: 有効" || echo "App Sandbox: 付いていません"
	@echo "Launching $(APP) (sandboxed) ..."
	@open "$(APP)"

check-mas:
	@if [ -z "$(MAS_IDENTITY)" ] || [ -z "$(MAS_INSTALLER_IDENTITY)" ]; then \
		echo "error: App Store 用の署名 ID が要ります。"; \
		echo '       make mas MAS_IDENTITY="Apple Distribution: 名前 (TEAMID)" \'; \
		echo '                MAS_INSTALLER_IDENTITY="3rd Party Mac Developer Installer: 名前 (TEAMID)" \'; \
		echo '                PROVISION_PROFILE=AppMixer.provisionprofile'; exit 1; \
	fi
	@if [ -z "$(PROVISION_PROFILE)" ] || [ ! -f "$(PROVISION_PROFILE)" ]; then \
		echo "error: プロビジョニングプロファイルが要ります（PROVISION_PROFILE）。"; \
		echo "       App Store Connect で作成したものを指定してください。"; exit 1; \
	fi
	@if [ -z "$(TEAM_ID)" ]; then \
		echo "error: チーム ID を取り出せませんでした。"; \
		echo '       MAS_IDENTITY を "Apple Distribution: 名前 (TEAMID)" の形で渡すか、'; \
		echo "       TEAM_ID=<TEAMID> を直接指定してください。"; exit 1; \
	fi

# 提出用の .pkg を作る。
mas: check-mas bundle
	@rm -rf "$(DIST)/mas"
	@mkdir -p "$(DIST)/mas"
	@cp -R "$(APP)" "$(MAS_APP)"
	@cp "$(PROVISION_PROFILE)" "$(MAS_APP)/Contents/embedded.provisionprofile"
	@# App Store の署名には application-identifier と team-identifier が要る。
	@# 無いまま提出すると、アップロードの検証で弾かれる。ここで足す。
	@cp bundle/$(APP_NAME).mas.entitlements "$(MAS_ENTITLEMENTS)"
	@/usr/libexec/PlistBuddy \
		-c "Add :com.apple.application-identifier string $(TEAM_ID).$(BUNDLE_ID)" \
		-c "Add :com.apple.developer.team-identifier string $(TEAM_ID)" \
		"$(MAS_ENTITLEMENTS)"
	@# App Store では Hardened Runtime ではなく App Sandbox を使う。
	@codesign --force --timestamp \
		--sign "$(MAS_IDENTITY)" \
		--entitlements "$(MAS_ENTITLEMENTS)" \
		"$(MAS_APP)"
	@codesign --verify --strict --verbose=2 "$(MAS_APP)"
	@# 焼けているか確かめる。抜けたまま提出すると、審査ではなく
	@# アップロードの段階で弾かれ、理由も分かりにくい。
	@codesign --display --entitlements - --xml "$(MAS_APP)" 2>/dev/null \
		| grep -q application-identifier \
		|| { echo "error: application-identifier が署名に入っていません。"; exit 1; }
	@rm -f "$(PKG)"
	@productbuild --component "$(MAS_APP)" /Applications \
		--sign "$(MAS_INSTALLER_IDENTITY)" "$(PKG)"
	@echo
	@echo "提出物: $(PKG)"
	@echo "この後: Transporter.app で App Store Connect へアップロードする"

clean:
	@rm -rf .build "$(DIST)" bundle/icon/AppIcon.icns
	@echo "Cleaned."
