#!/usr/bin/env python3
"""開発用の偽 Home Assistant。本物の HA を起こさずに iPhone アプリ → relay → 「HA」の通しを試す。

    python3 relay/dev_fake_ha.py --port 18123 --token-file /tmp/fake-ha-token

relay 側は HA_URL=http://127.0.0.1:18123 と HA_TOKEN_FILE=<同じファイル> で起動する。
受けた notify 呼び出しは標準出力に出す（実際には何も鳴らない）。
"""

import argparse
import json
import secrets
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--port", type=int, default=18123)
    ap.add_argument("--token-file", required=True, help="無ければ作る。relay の HA_TOKEN_FILE と同じパスを渡す")
    ap.add_argument("--targets", default="media_player.living_echo,media_player.kitchen_echo")
    args = ap.parse_args()

    path = Path(args.token_file)
    if not path.exists():
        path.write_text(secrets.token_hex(32))
        path.chmod(0o600)
    token = path.read_text().strip()
    targets = [t for t in args.targets.split(",") if t]

    class H(BaseHTTPRequestHandler):
        def log_message(self, *a):
            pass

        def reply(self, status, body):
            data = json.dumps(body, ensure_ascii=False).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.end_headers()
            self.wfile.write(data)

        def authed(self):
            return self.headers.get("Authorization") == f"Bearer {token}"

        def do_GET(self):
            if not self.authed():
                return self.reply(401, {"message": "unauthorized"})
            if self.path == "/api/":
                return self.reply(200, {"message": "API running."})
            if self.path == "/api/states":
                return self.reply(200, [{"entity_id": t, "attributes": {"last_called": False, "last_called_summary": None}} for t in targets])
            self.reply(404, {})

        def do_POST(self):
            if not self.authed():
                return self.reply(401, {"message": "unauthorized"})
            n = int(self.headers.get("Content-Length") or 0)
            body = json.loads(self.rfile.read(n) or b"null")
            if self.path == "/api/template":
                return self.reply(200, targets)
            if self.path.startswith("/api/services/notify/"):
                print(f"[fake-ha] {self.path} {json.dumps(body, ensure_ascii=False)}", flush=True)
                return self.reply(200, [])
            self.reply(404, {})

    print(f"[fake-ha] listening on 127.0.0.1:{args.port}", flush=True)
    ThreadingHTTPServer(("127.0.0.1", args.port), H).serve_forever()


if __name__ == "__main__":
    main()
