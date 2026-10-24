#!/usr/bin/env python3
"""fam-echo relay — 家族の iPhone から受けた文を Home Assistant 経由で Echo に読み上げさせる窓口。

Python 3 標準ライブラリだけで動く（依存なし）。

    POST /speak   {"from": "家族A", "text": "ご飯できたよ"}   要 Authorization: Bearer <FAM_ECHO_TOKEN>
    GET  /health  認証なし。relay の生存と HA への疎通を返す

読み上げ文は relay 側で「{from}から。{text}」に組む（アプリ側では組まない）。

設定は relay/.env（KEY=VALUE）と環境変数から読む（環境変数が優先）。項目は .env.example を参照。
トークン類はログ・レスポンスに一切出さない。
"""

from __future__ import annotations

import hmac
import json
import logging
import os
import sys
import time
import urllib.error
import urllib.request
from dataclasses import dataclass, field
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

LOG = logging.getLogger("fam-echo-relay")

HERE = Path(__file__).resolve().parent
DEFAULT_ENV_PATH = HERE / ".env"

MAX_TEXT_LEN = 500
MAX_FROM_LEN = 20
MAX_BODY_BYTES = 16 * 1024
SPEAK_TYPES = ("announce", "tts")
TARGET_CACHE_SECONDS = 300


# ---------------------------------------------------------------- 設定


def parse_env_file(path: Path) -> dict[str, str]:
    """KEY=VALUE 形式の .env を読む。# 行・空行は飛ばす。値の前後の引用符は外す。"""
    values: dict[str, str] = {}
    if not path.is_file():
        return values
    for raw in path.read_text(encoding="utf-8").splitlines():
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        if line.startswith("export "):
            line = line[len("export "):].strip()
        if "=" not in line:
            continue
        key, value = line.split("=", 1)
        value = value.strip()
        if len(value) >= 2 and value[0] == value[-1] and value[0] in "'\"":
            value = value[1:-1]
        values[key.strip()] = value
    return values


class ConfigError(Exception):
    pass


@dataclass
class Config:
    token: str
    ha_url: str = "http://localhost:8123"
    ha_token_file: Path = Path("~/work/home-assistant/.ha-token")
    notify_service: str = "alexa_media"
    echo_targets: list[str] = field(default_factory=list)
    speak_type: str = "announce"
    host: str = "127.0.0.1"
    port: int = 8790
    ha_timeout: float = 10.0

    @classmethod
    def load(cls, env_path: Path = DEFAULT_ENV_PATH, environ: dict[str, str] | None = None) -> "Config":
        merged = parse_env_file(env_path)
        merged.update({k: v for k, v in (os.environ if environ is None else environ).items() if k.startswith(("FAM_ECHO_", "HA_", "ECHO_", "RELAY_"))})

        token = merged.get("FAM_ECHO_TOKEN", "").strip()
        if len(token) < 16:
            raise ConfigError("FAM_ECHO_TOKEN が未設定か短すぎます（openssl rand -hex 32 で作ってください）")

        speak_type = merged.get("ECHO_SPEAK_TYPE", "announce").strip() or "announce"
        if speak_type not in SPEAK_TYPES:
            raise ConfigError(f"ECHO_SPEAK_TYPE は {'/'.join(SPEAK_TYPES)} のどちらかです")

        targets = [t.strip() for t in merged.get("ECHO_TARGETS", "").split(",") if t.strip()]
        try:
            port = int(merged.get("RELAY_PORT", "8790"))
            timeout = float(merged.get("HA_TIMEOUT", "10"))
        except ValueError as exc:
            raise ConfigError(f"数値の設定が読めません: {exc}") from None

        return cls(
            token=token,
            ha_url=merged.get("HA_URL", "http://localhost:8123").rstrip("/"),
            ha_token_file=Path(merged.get("HA_TOKEN_FILE", "~/work/home-assistant/.ha-token")).expanduser(),
            notify_service=merged.get("HA_NOTIFY_SERVICE", "alexa_media").strip() or "alexa_media",
            echo_targets=targets,
            speak_type=speak_type,
            host=merged.get("RELAY_HOST", "127.0.0.1"),
            port=port,
            ha_timeout=timeout,
        )


# ---------------------------------------------------------------- 入力と読み上げ文


class BadRequest(Exception):
    pass


def _clean(value: object, name: str, max_len: int) -> str:
    if not isinstance(value, str):
        raise BadRequest(f"{name} は文字列で送ってください")
    # 改行・タブは読み上げでは意味がないので空白1つに畳む
    cleaned = " ".join(value.split())
    if not cleaned:
        raise BadRequest(f"{name} が空です")
    if len(cleaned) > max_len:
        raise BadRequest(f"{name} は{max_len}文字までです（{len(cleaned)}文字）")
    return cleaned


def parse_speak_body(raw: bytes) -> tuple[str, str]:
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, json.JSONDecodeError):
        raise BadRequest("JSON として読めません") from None
    if not isinstance(payload, dict):
        raise BadRequest("JSON オブジェクトで送ってください")
    sender = _clean(payload.get("from"), "from", MAX_FROM_LEN)
    text = _clean(payload.get("text"), "text", MAX_TEXT_LEN)
    return sender, text


def build_message(sender: str, text: str) -> str:
    """読み上げ文を組む。形は「{from}から。{text}」で固定。"""
    return f"{sender}から。{text}"


def token_matches(header_value: str | None, expected: str) -> bool:
    """Authorization: Bearer <token> を定数時間で比べる。"""
    if not header_value:
        return False
    scheme, _, supplied = header_value.partition(" ")
    if scheme.lower() != "bearer":
        return False
    return hmac.compare_digest(supplied.strip().encode("utf-8"), expected.encode("utf-8"))


# ---------------------------------------------------------------- Home Assistant


class HAError(Exception):
    """HA に届かない／HA が失敗を返した。relay は 502 にする。"""

    def __init__(self, code: str, detail: str):
        super().__init__(detail)
        self.code = code
        self.detail = detail


class HAClient:
    def __init__(self, config: Config, opener=None):
        self.config = config
        self._open = opener or urllib.request.urlopen
        self._cached_targets: list[str] = []
        self._cached_at = 0.0

    def _ha_token(self) -> str:
        path = self.config.ha_token_file
        try:
            token = path.read_text(encoding="utf-8").strip()
        except OSError:
            raise HAError("ha_token_missing", f"HA トークンのファイルが読めません（{path}）") from None
        if not token:
            raise HAError("ha_token_missing", f"HA トークンのファイルが空です（{path}）")
        return token

    def _request(self, method: str, path: str, body: object | None = None):
        data = None if body is None else json.dumps(body, ensure_ascii=False).encode("utf-8")
        req = urllib.request.Request(
            self.config.ha_url + path,
            data=data,
            method=method,
            headers={
                "Authorization": f"Bearer {self._ha_token()}",
                "Content-Type": "application/json",
            },
        )
        try:
            with self._open(req, timeout=self.config.ha_timeout) as resp:
                raw = resp.read()
        except urllib.error.HTTPError as exc:
            if exc.code in (401, 403):
                raise HAError("ha_auth_failed", "Home Assistant がトークンを受け付けません") from None
            raise HAError("ha_error", f"Home Assistant がエラーを返しました（HTTP {exc.code}）") from None
        except (urllib.error.URLError, TimeoutError, ConnectionError, OSError) as exc:
            reason = getattr(exc, "reason", exc)
            raise HAError("ha_unreachable", f"Home Assistant に届きません（{reason}）") from None
        if not raw:
            return None
        try:
            return json.loads(raw.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            return None

    def ping(self) -> dict:
        try:
            self._request("GET", "/api/")
            return {"reachable": True}
        except HAError as exc:
            return {"reachable": False, "error": exc.code, "detail": exc.detail}

    def discover_targets(self) -> list[str]:
        """Alexa Media Player 由来の media_player を探す。

        1. テンプレート API の integration_entities('alexa_media') で確実に引く
        2. だめなら /api/states から、Alexa Media Player だけが持つ属性
           （last_called と last_called_summary）を手掛かりに拾う
        """
        now = time.monotonic()
        if self._cached_targets and now - self._cached_at < TARGET_CACHE_SECONDS:
            return list(self._cached_targets)

        targets: list[str] = []
        try:
            result = self._request(
                "POST",
                "/api/template",
                {"template": "{{ integration_entities('alexa_media') | select('match', 'media_player\\\\.') | list | tojson }}"},
            )
            if isinstance(result, list):
                targets = [t for t in result if isinstance(t, str) and t.startswith("media_player.")]
        except HAError as exc:
            if exc.code in ("ha_unreachable", "ha_auth_failed", "ha_token_missing"):
                raise
            targets = []

        if not targets:
            states = self._request("GET", "/api/states")
            for st in states if isinstance(states, list) else []:
                entity_id = st.get("entity_id", "") if isinstance(st, dict) else ""
                attrs = st.get("attributes", {}) if isinstance(st, dict) else {}
                if entity_id.startswith("media_player.") and "last_called" in attrs and "last_called_summary" in attrs:
                    targets.append(entity_id)

        targets = sorted(set(targets))
        if targets:
            self._cached_targets, self._cached_at = targets, now
        return targets

    def resolve_targets(self) -> list[str]:
        if self.config.echo_targets:
            return list(self.config.echo_targets)
        targets = self.discover_targets()
        if not targets:
            raise HAError(
                "no_targets",
                "読み上げ先の Echo が見つかりません。Alexa Media Player の連携を確かめるか、ECHO_TARGETS を設定してください",
            )
        return targets

    def speak(self, message: str) -> list[str]:
        targets = self.resolve_targets()
        self._request(
            "POST",
            f"/api/services/notify/{self.config.notify_service}",
            {"message": message, "target": targets, "data": {"type": self.config.speak_type}},
        )
        return targets


# ---------------------------------------------------------------- HTTP


def make_handler(config: Config, ha: HAClient):
    class Handler(BaseHTTPRequestHandler):
        server_version = "fam-echo-relay/1"
        sys_version = ""

        def log_message(self, fmt, *args):  # 標準のアクセスログはヘッダを出さないが、念のため自前に寄せる
            LOG.info("%s %s", self.address_string(), fmt % args)

        def _send_json(self, status: int, body: dict):
            data = json.dumps(body, ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def _error(self, status: int, code: str, detail: str):
            self._send_json(status, {"ok": False, "error": code, "detail": detail})

        def do_GET(self):
            if self.path.split("?", 1)[0] == "/health":
                self._send_json(200, {"ok": True, "status": "ok", "ha": ha.ping()})
                return
            self._error(404, "not_found", "そのパスはありません")

        def do_POST(self):
            if self.path.split("?", 1)[0] != "/speak":
                self._error(404, "not_found", "そのパスはありません")
                return
            if not token_matches(self.headers.get("Authorization"), config.token):
                self._error(401, "unauthorized", "合言葉（トークン）が違います")
                return
            try:
                length = int(self.headers.get("Content-Length") or 0)
            except ValueError:
                length = -1
            if length <= 0:
                self._error(400, "bad_request", "本文が空です")
                return
            if length > MAX_BODY_BYTES:
                self._error(413, "too_large", "本文が大きすぎます")
                return
            raw = self.rfile.read(length)
            try:
                sender, text = parse_speak_body(raw)
            except BadRequest as exc:
                self._error(400, "bad_request", str(exc))
                return

            message = build_message(sender, text)
            try:
                targets = ha.speak(message)
            except HAError as exc:
                LOG.warning("speak failed: from=%s len=%d error=%s", sender, len(text), exc.code)
                self._error(502, exc.code, exc.detail)
                return
            LOG.info("spoke: from=%s len=%d targets=%d type=%s", sender, len(text), len(targets), config.speak_type)
            self._send_json(200, {"ok": True, "message": message, "targets": targets, "type": config.speak_type})

    return Handler


def make_server(config: Config, ha: HAClient | None = None) -> ThreadingHTTPServer:
    ha = ha or HAClient(config)
    return ThreadingHTTPServer((config.host, config.port), make_handler(config, ha))


def main(argv: list[str] | None = None) -> int:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    env_path = Path(os.environ.get("FAM_ECHO_ENV_FILE", str(DEFAULT_ENV_PATH))).expanduser()
    try:
        config = Config.load(env_path)
    except ConfigError as exc:
        LOG.error("設定エラー: %s（%s）", exc, env_path)
        return 2
    server = make_server(config)
    targets = ",".join(config.echo_targets) if config.echo_targets else "(HA から自動検出)"
    LOG.info("listening on http://%s:%d  ha=%s  type=%s  targets=%s", config.host, config.port, config.ha_url, config.speak_type, targets)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()
    return 0


if __name__ == "__main__":
    sys.exit(main())
