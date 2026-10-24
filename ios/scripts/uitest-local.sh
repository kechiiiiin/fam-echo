#!/bin/sh
# UI テストを手元で一式回す。本物の HA・常駐の relay（8790）・Secrets.xcconfig には触れない。
#
#   ios/scripts/uitest-local.sh          偽 HA と relay 2つ（正常・HA 停止）を空いているポートで起動 → make uitest
#   ios/scripts/uitest-local.sh --shots  さらに ios/docs/ のスクリーンショットを書き出し直す
#
# アプリの送信先とトークンは TEST_RUNNER_FAM_ECHO_* でテストに渡し、テストが起動引数でアプリに差し込む。
# relay は FAM_ECHO_ENV_FILE を空の場所に向けるので relay/.env も読まない。
set -eu
mode=${1:-}
cd "$(dirname "$0")/.."
root=$(cd .. && pwd)

work=$(mktemp -d "${TMPDIR:-/tmp}/fam-echo-uitest.XXXXXX")
pids=""
cleanup() {
  for p in $pids; do kill "$p" 2>/dev/null || true; done
  rm -rf "$work"
}
trap cleanup EXIT INT TERM

# 空いているポートを4つ（偽 HA・relay・HA 停止用 relay・誰も待たない HA）。常駐の 8790 は避ける
set -- $(python3 - <<'PY'
import socket
ports = []
while len(ports) < 4:
    s = socket.socket(); s.bind(("127.0.0.1", 0)); p = s.getsockname()[1]; s.close()
    if p != 8790 and p not in ports:
        ports.append(p)
print(*ports)
PY
)
ha_port=$1 relay_port=$2 down_port=$3 dead_ha_port=$4
token=$(openssl rand -hex 32)

python3 "$root/relay/dev_fake_ha.py" --port "$ha_port" --token-file "$work/ha-token" >"$work/fake-ha.log" 2>&1 &
pids="$pids $!"
sleep 1

start_relay() {  # $1=relay のポート $2=HA の URL
  env -u ECHO_TARGETS FAM_ECHO_ENV_FILE="$work/no-env" FAM_ECHO_TOKEN="$token" \
    HA_URL="$2" HA_TOKEN_FILE="$work/ha-token" HA_TIMEOUT=3 RELAY_HOST=127.0.0.1 RELAY_PORT="$1" \
    python3 "$root/relay/fam_echo_relay.py" >"$work/relay-$1.log" 2>&1 &
  pids="$pids $!"
}
start_relay "$relay_port" "http://127.0.0.1:$ha_port"
start_relay "$down_port" "http://127.0.0.1:$dead_ha_port"

for port in "$relay_port" "$down_port"; do
  i=0
  until curl -sf "http://127.0.0.1:$port/health" >/dev/null; do
    i=$((i + 1)); [ "$i" -lt 20 ] || { echo "relay（$port）が起動しません"; cat "$work/relay-$port.log"; exit 1; }
    sleep 0.5
  done
done
echo "偽 HA :$ha_port / relay :$relay_port / HA 停止の relay :$down_port"

export TEST_RUNNER_FAM_ECHO_URL="http://127.0.0.1:$relay_port"
export TEST_RUNNER_FAM_ECHO_TOKEN="$token"
export TEST_RUNNER_FAM_ECHO_HA_DOWN_URL="http://127.0.0.1:$down_port"
make uitest

if [ "$mode" = "--shots" ]; then
  ./export-shots.sh
fi
