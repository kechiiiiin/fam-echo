#!/bin/bash
# fam-echo 見張り: Home Assistant（Docker 上のコンテナ）が落ちていたら起こす。
# 正常時は何も出力しない。launchd（StartInterval）から呼ばれる想定。
#
# 環境変数（すべて任意）:
#   HA_URL                      既定 http://localhost:8123/
#   HA_CONTAINER                既定 homeassistant
#   WATCHDOG_WAIT_SECONDS       復旧を待つ秒数（既定 180）
#   WATCHDOG_POLL_SECONDS       待つ間の確認間隔（既定 5）
#   WATCHDOG_STATE_DIR          状態・ロックの置き場（既定 ~/Library/Logs/fam-echo）
#   FAM_ECHO_WATCHDOG_NOTIFY    復旧に失敗したとき、本文を引数に実行するコマンド

# 既存の PATH を先頭に残し、launchd の狭い PATH を補う
PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:/Applications/Docker.app/Contents/Resources/bin"
export PATH

HA_URL="${HA_URL:-http://localhost:8123/}"
HA_CONTAINER="${HA_CONTAINER:-homeassistant}"
WAIT_SECONDS="${WATCHDOG_WAIT_SECONDS:-180}"
POLL_SECONDS="${WATCHDOG_POLL_SECONDS:-5}"
STATE_DIR="${WATCHDOG_STATE_DIR:-$HOME/Library/Logs/fam-echo}"
STATE_FILE="$STATE_DIR/watchdog.state"
LOCK_DIR="$STATE_DIR/watchdog.lock"

log() { printf '%s %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*"; }

ha_ok() {
  local code
  code=$(curl -s -m 5 -o /dev/null -w '%{http_code}' "$HA_URL" 2>/dev/null)
  [ "$code" = "200" ]
}

notify() {
  [ -n "${FAM_ECHO_WATCHDOG_NOTIFY:-}" ] || return 0
  bash -c "$FAM_ECHO_WATCHDOG_NOTIFY \"\$1\"" _ "$1" >/dev/null 2>&1 || true
}

container_running() {
  [ "$(docker inspect -f '{{.State.Running}}' "$HA_CONTAINER" 2>/dev/null)" = "true" ]
}

# daemon があるのにコンテナが止まっていたら起こす
ensure_container() {
  docker info >/dev/null 2>&1 || return 0
  if ! container_running; then
    log "コンテナ $HA_CONTAINER が止まっているので docker start します"
    docker start "$HA_CONTAINER" >/dev/null 2>&1 || log "docker start に失敗しました"
  fi
}

mkdir -p "$STATE_DIR" || exit 1

# 二重起動防止（mkdir ロック・10 分超の古いロックは破棄）
if [ -d "$LOCK_DIR" ] && [ -n "$(find "$LOCK_DIR" -maxdepth 0 -mmin +10 2>/dev/null)" ]; then
  rmdir "$LOCK_DIR" 2>/dev/null
fi
mkdir "$LOCK_DIR" 2>/dev/null || exit 0
trap 'rmdir "$LOCK_DIR" 2>/dev/null' EXIT

if ha_ok; then
  if [ -f "$STATE_FILE" ]; then
    rm -f "$STATE_FILE"
    log "Home Assistant が復帰しました"
  fi
  exit 0
fi

log "Home Assistant が応答しません（$HA_URL）"
echo down > "$STATE_FILE"

if ! docker info >/dev/null 2>&1; then
  log "Docker の daemon が動いていないので起動します"
  if ! docker desktop start >/dev/null 2>&1; then
    log "docker desktop start に失敗。open -a \"Docker Desktop\" を試します"
    open -a "Docker Desktop" >/dev/null 2>&1 || log "Docker Desktop を開けませんでした"
  fi
else
  ensure_container
fi

waited=0
while [ "$waited" -lt "$WAIT_SECONDS" ]; do
  sleep "$POLL_SECONDS"
  waited=$((waited + POLL_SECONDS))
  if ha_ok; then
    rm -f "$STATE_FILE"
    log "Home Assistant が復旧しました（${waited} 秒）"
    exit 0
  fi
  ensure_container
done

log "Home Assistant を ${WAIT_SECONDS} 秒待っても復旧しませんでした"
notify "fam-echo: Home Assistant が落ちています。自動復旧に失敗しました"
exit 1
