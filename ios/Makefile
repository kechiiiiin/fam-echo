# fam-echo iOS
#
#   make check     xcodegen generate → シミュレータ向けにビルド。警告が1つでもあれば失敗にする
#   make sim       専用シミュレータ（FamEcho-Sim）にビルドして入れて起動する
#   make uitest    UI テスト（名前選択→送信→履歴→ボタン保存→編集・削除・失敗表示）。手元で一式なら scripts/uitest-local.sh
#   make icon      Design/icon.svg からアプリアイコンを作り直す
#
# 配る（README「配る（TestFlight／実機へ直接）」）
#   make archive            Release で .xcarchive を作る（ビルド番号は日時で自動。BUILD_NUMBER= で上書き可）
#   make export-testflight  .xcarchive から App Store Connect 向けの .ipa を build/export/ に書き出す（送らない）
#   make upload             API キーで App Store Connect へ上げる（Release.local.env と .p8 が要る）
#   make release            archive → upload
#   make device-list        実機の一覧（名前・接続・デベロッパモード）
#   make device-install DEVICE=<名前かUDID>   開発用署名でビルドして Wi-Fi 越しに入れる（TestFlight を使えない端末用）
#   make asc-test           asc.py（TestFlight の招待・審査提出）の単体テスト
#
# *.xcodeproj は生成物でコミットしない。各ターゲットの先頭で毎回 generate する（brew install xcodegen）。
# build/ の .xcarchive・.ipa・ログには送信先とトークンが埋め込まれている。コミットも共有もしない（gitignore 済み）。

PROJECT = FamEcho.xcodeproj
SCHEME  = FamEcho
BUNDLE  = jp.kechiiiiin.famecho
SIM     = FamEcho-Sim
SIMTYPE = com.apple.CoreSimulator.SimDeviceType.iPhone-17
DERIVED = build
APP     = $(DERIVED)/Build/Products/Debug-iphonesimulator/FamEcho.app

.PHONY: help generate check sim-create sim uitest icon clean \
        archive export-testflight upload release device-list device-install asc-test require-secrets require-asc-key require-device

# ---- 配る ----
RELEASE_ENV   = Release.local.env
ARCHIVE       = build/archive/FamEcho.xcarchive
EXPORT_DIR    = build/export
EXPORT_PLIST  = build/ExportOptions.generated.plist
RELEASE_DD    = build/release
DEVICE_DD     = build/device
DEVICE_APP    = $(DEVICE_DD)/Build/Products/Release-iphoneos/FamEcho.app
DESTINATION  ?= export
# ビルド番号: 「年月日.1時分」（例 20261024.12057）。上げるたびに増えればよいので project.yml は書き換えない
BUILD_NUMBER := $(shell date +%Y%m%d.1%H%M)

# API キー（Release.local.env から読む。環境変数でも渡せる）
env_value = $(strip $(shell sed -n 's/^$(1)=//p' $(RELEASE_ENV) 2>/dev/null | tail -1))
ASC_KEY_ID    ?= $(call env_value,ASC_KEY_ID)
ASC_ISSUER_ID ?= $(call env_value,ASC_ISSUER_ID)
ASC_KEY_PATH  ?= $(call env_value,ASC_KEY_PATH)
ifeq ($(strip $(ASC_KEY_PATH)),)
ASC_KEY_PATH := $(HOME)/.appstoreconnect/private_keys/AuthKey_$(ASC_KEY_ID).p8
endif
ASC_KEY_PATH := $(patsubst ~/%,$(HOME)/%,$(ASC_KEY_PATH))
# キーがそろっていれば xcodebuild にも渡す（Xcode にアカウントが無くても署名・プロファイル更新ができる）
ifneq ($(and $(ASC_KEY_ID),$(ASC_ISSUER_ID),$(wildcard $(ASC_KEY_PATH))),)
AUTH_FLAGS = -authenticationKeyPath "$(ASC_KEY_PATH)" -authenticationKeyID $(ASC_KEY_ID) -authenticationKeyIssuerID $(ASC_ISSUER_ID)
endif

help:
	@grep -E '^#   make' Makefile | sed 's/^#   //'

generate:
	xcodegen generate --quiet

check: generate
	@rm -rf build-check
	@set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) \
	  -destination 'generic/platform=iOS Simulator' -configuration Debug \
	  -derivedDataPath build-check CODE_SIGNING_ALLOWED=NO build 2>&1 | tee build-check.log | grep -E '(warning|error):|BUILD (SUCCEEDED|FAILED)' || true
	@w=$$(grep -E ': warning:' build-check.log | sort -u | wc -l | tr -d ' '); \
	 e=$$(grep -E ': error:' build-check.log | sort -u | wc -l | tr -d ' '); \
	 ok=$$(grep -c 'BUILD SUCCEEDED' build-check.log); \
	 echo "warnings=$$w errors=$$e"; \
	 rm -rf build-check build-check.log; \
	 test "$$ok" -ge 1 -a "$$w" -eq 0 -a "$$e" -eq 0
	@echo "check OK（警告0・エラー0）"

sim-create:
	@xcrun simctl list devices | grep -q "$(SIM) (" || xcrun simctl create $(SIM) $(SIMTYPE)
	@xcrun simctl boot $(SIM) 2>/dev/null || true

sim: generate sim-create
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=iOS Simulator,name=$(SIM)' \
	  -configuration Debug -derivedDataPath $(DERIVED) build -quiet
	xcrun simctl install $(SIM) $(APP)
	xcrun simctl launch $(SIM) $(BUNDLE)

uitest: generate sim-create
	rm -rf $(DERIVED)/uitest.xcresult
	-xcrun simctl uninstall $(SIM) $(BUNDLE)
	xcodebuild -project $(PROJECT) -scheme $(SCHEME) -destination 'platform=iOS Simulator,name=$(SIM)' \
	  -derivedDataPath $(DERIVED) -resultBundlePath $(DERIVED)/uitest.xcresult test

icon:
	rsvg-convert -w 1024 -h 1024 -b '#E8742C' Design/icon.svg | magick - -alpha off FamEcho/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png

# ---- 配る ----

# 送信先とトークンが無いまま配ると「送信先が未設定」のアプリになるので止める（中身は読まない）
require-secrets:
	@test -s Secrets.xcconfig || { echo "Secrets.xcconfig がありません（Secrets.example.xcconfig を見本に作る）。配るビルドには送信先が要ります"; exit 1; }

require-asc-key:
	@test -n "$(ASC_KEY_ID)" -a -n "$(ASC_ISSUER_ID)" || { echo "ASC_KEY_ID / ASC_ISSUER_ID がありません。Release.example.env を Release.local.env にコピーして埋めてください"; exit 1; }
	@test -f "$(ASC_KEY_PATH)" || { echo "API キーがありません: $(ASC_KEY_PATH)"; echo "App Store Connect で作った AuthKey_<KEY_ID>.p8 をそこに置いてください（README「配る」）"; exit 1; }

archive: generate require-secrets
	@mkdir -p build/archive
	rm -rf $(ARCHIVE)
	@echo "ビルド番号 $(BUILD_NUMBER) で archive します"
	@set -o pipefail; xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	  -destination 'generic/platform=iOS' -derivedDataPath $(RELEASE_DD) -archivePath $(ARCHIVE) \
	  -allowProvisioningUpdates $(AUTH_FLAGS) CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) archive 2>&1 \
	  | tee build/archive.log | grep -E '(error|warning):|ARCHIVE (SUCCEEDED|FAILED)|Signing Identity|Provisioning Profile' || \
	  { echo "archive に失敗しました（全文は ios/build/archive.log）"; exit 1; }
	@echo "$(BUILD_NUMBER)" > build/archive/BUILD_NUMBER
	@printf "できました: %s（版 %s・ビルド %s）\n" "$(ARCHIVE)" \
	  "$$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleShortVersionString' $(ARCHIVE)/Info.plist)" \
	  "$$(/usr/libexec/PlistBuddy -c 'Print :ApplicationProperties:CFBundleVersion' $(ARCHIVE)/Info.plist)"

export-testflight:
	@test -d $(ARCHIVE) || { echo "$(ARCHIVE) がありません。先に make archive"; exit 1; }
	rm -rf $(EXPORT_DIR)
	@mkdir -p $(EXPORT_DIR)
	cp ExportOptions.plist $(EXPORT_PLIST)
	plutil -replace destination -string $(DESTINATION) $(EXPORT_PLIST)
	@set -o pipefail; xcodebuild -exportArchive -archivePath $(ARCHIVE) -exportPath $(EXPORT_DIR) \
	  -exportOptionsPlist $(EXPORT_PLIST) -allowProvisioningUpdates $(AUTH_FLAGS) 2>&1 \
	  | tee build/export.log | grep -E '(error|warning):|EXPORT (SUCCEEDED|FAILED)|Upload|Uploaded|uploaded' || \
	  { echo "export に失敗しました（全文は ios/build/export.log）"; exit 1; }
	@if [ "$(DESTINATION)" = export ]; then ls -lh $(EXPORT_DIR)/*.ipa; else echo "App Store Connect へ上げました。処理状況: python3 scripts/asc.py builds"; fi

upload: require-asc-key
	$(MAKE) export-testflight DESTINATION=upload

release: archive upload

device-list:
	@python3 scripts/device.py list

# 開発用署名（Apple Development）で Release 構成をビルドして入れる。
# -allowProvisioningDeviceRegistration で、その端末を開発者アカウントに登録しプロファイルに足す（初回だけ）
require-device:
	@test -n "$(DEVICE)" || { echo "DEVICE=<名前かUDID> を渡してください（make device-list で見られます）"; exit 1; }

device-install: require-device generate require-secrets
	@set -e -o pipefail; ids="$$(python3 scripts/device.py resolve "$(DEVICE)")"; \
	  udid="$${ids%% *}"; ident="$${ids##* }"; \
	  echo "$(DEVICE) → UDID $$udid にビルドします（ビルド番号 $(BUILD_NUMBER)）"; \
	  mkdir -p build; \
	  xcodebuild -project $(PROJECT) -scheme $(SCHEME) -configuration Release \
	    -destination "id=$$udid" -derivedDataPath $(DEVICE_DD) \
	    -allowProvisioningUpdates -allowProvisioningDeviceRegistration $(AUTH_FLAGS) \
	    CURRENT_PROJECT_VERSION=$(BUILD_NUMBER) build 2>&1 | tee build/device.log \
	    | grep -E '(error|warning):|BUILD (SUCCEEDED|FAILED)'; \
	  xcrun devicectl device install app --device "$$ident" $(DEVICE_APP)

asc-test:
	python3 -m unittest discover -s scripts -v

clean:
	rm -rf $(DERIVED) build-check build-check.log $(PROJECT)
