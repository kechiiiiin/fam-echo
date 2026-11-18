#!/bin/bash
# watchdog の単体テスト。docker / curl / open を偽コマンドで差し替える。
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/../fam_echo_watchdog.sh"
fails=0

setup() {
  T="$(mktemp -d "${TMPDIR:-/tmp}/watchdog-test.XXXXXX")"
  mkdir -p "$T/bin" "$T/state"
  : > "$T/calls"
  cat > "$T/bin/curl" <<'F'
#!/bin/bash
echo curl >> "$T/calls"
if [ -f "$T/ha_up" ]; then printf 200; else printf 000; fi
F
  cat > "$T/bin/docker" <<'F'
#!/bin/bash
echo "docker $*" >> "$T/calls"
case "$1" in
  info) [ -f "$T/daemon_up" ] || exit 1 ;;
  desktop) touch "$T/daemon_up" ;;
  inspect) if [ -f "$T/container_up" ]; then echo true; else echo false; fi ;;
  start) touch "$T/container_up" "$T/ha_up" ;;
esac
F
  cat > "$T/bin/open" <<'F'
#!/bin/bash
echo "open $*" >> "$T/calls"
F
  chmod +x "$T/bin/"*
}

run() {
  T="$T" PATH="$T/bin:$PATH" WATCHDOG_STATE_DIR="$T/state" \
    WATCHDOG_WAIT_SECONDS=2 WATCHDOG_POLL_SECONDS=1 \
    bash "$SCRIPT" > "$T/out" 2>&1
  RC=$?
}

check() { # 名前 条件コマンド...
  local name="$1"; shift
  if "$@"; then
    echo "ok   $name"
  else
    echo "FAIL $name"
    fails=$((fails + 1))
    sed 's/^/     | /' "$T/out"
  fi
}
has() { grep -q -- "$1" "$T/calls"; }
hasnt() { ! grep -q -- "$1" "$T/calls"; }
quiet() { [ ! -s "$T/out" ]; }
rc_is() { [ "$RC" = "$1" ]; }
out_has() { grep -q -- "$1" "$T/out"; }
calls_empty() { [ ! -s "$T/calls" ]; }

# (a) 正常時は無音で何もしない
setup; touch "$T/ha_up"; run
check "a: 正常は終了0" rc_is 0
check "a: 正常は無音" quiet
check "a: docker を呼ばない" hasnt docker

# (b) daemon 無し → docker desktop start
setup; run
check "b: docker desktop start を呼ぶ" has "docker desktop start"
check "b: 復旧して終了0" rc_is 0
check "b: 復旧後にコンテナも起こす" has "docker start homeassistant"

# (c) daemon あり・コンテナ停止 → docker start homeassistant
setup; touch "$T/daemon_up"; run
check "c: docker start homeassistant" has "docker start homeassistant"
check "c: desktop start は呼ばない" hasnt "desktop start"
check "c: 復旧で終了0" rc_is 0

# (d) 復帰時に「復帰」行を1度だけ
setup; touch "$T/daemon_up"; run          # 異常を記録（復旧しても state は消える）
echo down > "$T/state/watchdog.state"      # 異常のまま次回を迎えた状況を作る
touch "$T/ha_up"; run
check "d: 復帰行が出る" out_has "復帰"
run
check "d: 2回目は無音" quiet

# (e) 二重起動防止
setup; mkdir "$T/state/watchdog.lock"; run
check "e: ロック中は何もしない" calls_empty
check "e: ロック中は終了0" rc_is 0
touch -t 200001010000 "$T/state/watchdog.lock"; touch "$T/ha_up"; run
check "e: 古いロックは破棄して動く" has curl

# (f) 復旧失敗で通知が呼ばれる
setup
cat > "$T/bin/docker" <<'F'
#!/bin/bash
[ "$1" = info ] && exit 1
exit 0
F
echo 'echo "$1" > "$T/notified"' > "$T/notify.sh"
T="$T" PATH="$T/bin:$PATH" WATCHDOG_STATE_DIR="$T/state" WATCHDOG_WAIT_SECONDS=2 WATCHDOG_POLL_SECONDS=1 \
  FAM_ECHO_WATCHDOG_NOTIFY="bash $T/notify.sh" bash "$SCRIPT" > "$T/out" 2>&1
RC=$?
check "f: 失敗は終了1" rc_is 1
check "f: 通知コマンドが呼ばれる" test -s "$T/notified"

echo
if [ "$fails" = 0 ]; then echo "全部通りました"; else echo "失敗: $fails"; fi
exit "$fails"
