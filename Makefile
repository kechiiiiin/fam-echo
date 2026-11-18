# fam-echo
#
#   make relay-test      relay の単体テスト（HA はモック）
#   make relay-run       relay を前面で起動（relay/.env を読む）
#   make relay-plist     launchd の plist を relay/build/ に書き出すだけ（何も読み込まない）
#   make relay-install   plist を ~/Library/LaunchAgents に置いて launchctl で常駐させる
#   make relay-uninstall 常駐をやめて plist を消す
#   make relay-log       relay のログを追う
#   make tunnel-plist    Cloudflare Tunnel の config.yml と plist を tunnel/build/ に書き出して検証するだけ
#   make tunnel-install  plist を ~/Library/LaunchAgents に置いて launchctl で常駐させる
#   make tunnel-uninstall Tunnel の常駐をやめて plist を消す
#   make tunnel-log      Tunnel のログを追う
#   make watchdog-test   HA 見張りの単体テスト（docker / curl は偽コマンド）
#   make watchdog-plist  見張りの plist を watchdog/build/ に書き出して検証するだけ
#   make watchdog-install 見張りを launchd に常駐させる（5分ごとに HA を確認し、落ちていれば起こす）
#   make watchdog-uninstall 見張りの常駐をやめて plist を消す
#   make watchdog-log    見張りのログを追う
#   make install         relay・tunnel・watchdog の全部
#   make check           iOS アプリを xcodegen → シミュレータ向けビルド（警告0・エラー0で成功）
#   make sim / uitest    iOS をシミュレータで起動 / UI テスト（ios/Makefile）
#   make archive / export-testflight / upload / release   TestFlight 向けに作る・書き出す・上げる（ios/Makefile）
#   make device-list / device-install DEVICE=<名前かUDID> [NAME=<送り主の名前>]  開発用ビルドを実機へ Wi-Fi 越しに入れる。NAME= でその端末の名前を焼き込む（ios/Makefile）
#   make asc-test        TestFlight の道具（ios/scripts/asc.py）の単体テスト

PYTHON    ?= $(shell command -v python3)
RELAY_DIR := $(CURDIR)/relay
LOG_DIR   := $(HOME)/Library/Logs/fam-echo
LABEL     := jp.kechiiiiin.fam-echo.relay
PLIST     := relay/build/$(LABEL).plist
AGENTS    := $(HOME)/Library/LaunchAgents

WATCHDOG_DIR   := $(CURDIR)/watchdog
WATCHDOG_LABEL := jp.kechiiiiin.fam-echo.watchdog
WATCHDOG_PLIST := watchdog/build/$(WATCHDOG_LABEL).plist

CLOUDFLARED  ?= $(shell command -v cloudflared || echo /opt/homebrew/bin/cloudflared)
TUNNEL_LABEL := jp.kechiiiiin.fam-echo.tunnel
TUNNEL_CONF  := $(CURDIR)/tunnel/build/config.yml
TUNNEL_PLIST := tunnel/build/$(TUNNEL_LABEL).plist

.PHONY: help relay-test relay-run relay-plist relay-install relay-uninstall relay-log tunnel-plist tunnel-install tunnel-uninstall tunnel-log watchdog-test watchdog-plist watchdog-install watchdog-uninstall watchdog-log install check sim uitest \
        archive export-testflight upload release device-list device-install asc-test

help:
	@grep -E '^#   make' Makefile | sed 's/^#   //'

relay-test:
	cd relay && $(PYTHON) -m unittest discover -s tests -v

relay-run:
	$(PYTHON) relay/fam_echo_relay.py

relay-plist:
	@mkdir -p relay/build
	sed -e 's|@PYTHON@|$(PYTHON)|g' -e 's|@RELAY_DIR@|$(RELAY_DIR)|g' -e 's|@LOG_DIR@|$(LOG_DIR)|g' \
	  relay/launchd/$(LABEL).plist.template > $(PLIST)
	plutil -lint $(PLIST)

relay-install: relay-plist
	@test -f relay/.env || (echo "relay/.env がありません（relay/.env.example をコピーして埋める）" && exit 1)
	mkdir -p $(LOG_DIR) $(AGENTS)
	cp $(PLIST) $(AGENTS)/$(LABEL).plist
	-launchctl bootout gui/$$(id -u)/$(LABEL) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENTS)/$(LABEL).plist
	@echo "常駐させました。確認: curl -s http://127.0.0.1:8790/health"

relay-uninstall:
	-launchctl bootout gui/$$(id -u)/$(LABEL)
	rm -f $(AGENTS)/$(LABEL).plist

relay-log:
	tail -f $(LOG_DIR)/relay.log

tunnel-plist:
	@mkdir -p tunnel/build
	sed -e 's|@HOME@|$(HOME)|g' tunnel/config.yml.template > $(TUNNEL_CONF)
	sed -e 's|@CLOUDFLARED@|$(CLOUDFLARED)|g' -e 's|@CONFIG@|$(TUNNEL_CONF)|g' -e 's|@LOG_DIR@|$(LOG_DIR)|g' \
	  tunnel/launchd/$(TUNNEL_LABEL).plist.template > $(TUNNEL_PLIST)
	plutil -lint $(TUNNEL_PLIST)
	$(CLOUDFLARED) tunnel --config $(TUNNEL_CONF) ingress validate

tunnel-install: tunnel-plist
	@test -f $(HOME)/.cloudflared/cert.pem || echo "注意: ~/.cloudflared/cert.pem がありません（cloudflared tunnel login が未実施かも）"
	mkdir -p $(LOG_DIR) $(AGENTS)
	cp $(TUNNEL_PLIST) $(AGENTS)/$(TUNNEL_LABEL).plist
	-launchctl bootout gui/$$(id -u)/$(TUNNEL_LABEL) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENTS)/$(TUNNEL_LABEL).plist
	@echo "Tunnel を常駐させました。確認: curl -s https://fam-echo.kechiiiiin.com/health"

tunnel-uninstall:
	-launchctl bootout gui/$$(id -u)/$(TUNNEL_LABEL)
	rm -f $(AGENTS)/$(TUNNEL_LABEL).plist

tunnel-log:
	tail -f $(LOG_DIR)/tunnel.log

watchdog-test:
	bash watchdog/tests/test_watchdog.sh

watchdog-plist:
	@mkdir -p watchdog/build
	sed -e 's|@WATCHDOG_DIR@|$(WATCHDOG_DIR)|g' -e 's|@LOG_DIR@|$(LOG_DIR)|g' \
	  watchdog/launchd/$(WATCHDOG_LABEL).plist.template > $(WATCHDOG_PLIST)
	plutil -lint $(WATCHDOG_PLIST)

watchdog-install: watchdog-plist
	mkdir -p $(LOG_DIR) $(AGENTS)
	cp $(WATCHDOG_PLIST) $(AGENTS)/$(WATCHDOG_LABEL).plist
	-launchctl bootout gui/$$(id -u)/$(WATCHDOG_LABEL) 2>/dev/null
	launchctl bootstrap gui/$$(id -u) $(AGENTS)/$(WATCHDOG_LABEL).plist
	@echo "見張りを常駐させました。ログ: $(LOG_DIR)/watchdog.log（正常時は無音）"

watchdog-uninstall:
	-launchctl bootout gui/$$(id -u)/$(WATCHDOG_LABEL)
	rm -f $(AGENTS)/$(WATCHDOG_LABEL).plist

watchdog-log:
	tail -f $(LOG_DIR)/watchdog.log

install: relay-install tunnel-install watchdog-install

check:
	$(MAKE) -C ios check

sim:
	$(MAKE) -C ios sim

uitest:
	$(MAKE) -C ios uitest

archive export-testflight upload release device-list asc-test:
	$(MAKE) -C ios $@

device-install:
	$(MAKE) -C ios device-install DEVICE="$(DEVICE)" NAME="$(NAME)"
