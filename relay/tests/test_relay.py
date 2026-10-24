"""fam-echo relay の単体テスト。HA は同じプロセス内の偽サーバーで置き換える。

    cd relay && python3 -m unittest discover -s tests -v
"""

from __future__ import annotations

import json
import socket
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import fam_echo_relay as relay  # noqa: E402

RELAY_TOKEN = "t" * 64
HA_TOKEN = "ha-test-token-not-real"


class FakeHA:
    """Home Assistant REST API の必要な所だけ真似る偽サーバー。"""

    def __init__(self, template_result=None, states=None, fail_template=False):
        self.calls: list[tuple[str, str, dict | None, str | None]] = []
        self.template_result = template_result
        self.states = states or []
        self.fail_template = fail_template
        fake = self

        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def _reply(self, status, body):
                data = json.dumps(body).encode()
                self.send_response(status)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(data)))
                self.end_headers()
                self.wfile.write(data)

            def _record(self):
                n = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(n)) if n else None
                fake.calls.append((self.command, self.path, body, self.headers.get("Authorization")))
                return body

            def do_GET(self):
                self._record()
                if self.headers.get("Authorization") != f"Bearer {HA_TOKEN}":
                    return self._reply(401, {"message": "unauthorized"})
                if self.path == "/api/":
                    return self._reply(200, {"message": "API running."})
                if self.path == "/api/states":
                    return self._reply(200, fake.states)
                self._reply(404, {})

            def do_POST(self):
                self._record()
                if self.headers.get("Authorization") != f"Bearer {HA_TOKEN}":
                    return self._reply(401, {"message": "unauthorized"})
                if self.path == "/api/template":
                    if fake.fail_template:
                        return self._reply(400, {"message": "bad template"})
                    return self._reply(200, fake.template_result if fake.template_result is not None else [])
                if self.path.startswith("/api/services/notify/"):
                    return self._reply(200, [])
                self._reply(404, {})

        self.server = ThreadingHTTPServer(("127.0.0.1", 0), H)
        self.url = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()
        self.server.server_close()

    def notify_calls(self):
        return [c for c in self.calls if c[1].startswith("/api/services/notify/")]


def free_closed_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


class RelayTestBase(unittest.TestCase):
    targets = ["media_player.living_echo", "media_player.bedroom_echo"]

    def make_fake_ha(self):
        return FakeHA()

    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.ha_token_path = Path(self.tmp.name) / ".ha-token"
        self.ha_token_path.write_text(HA_TOKEN + "\n")
        self.fake = self.make_fake_ha()
        self.config = relay.Config(
            token=RELAY_TOKEN,
            ha_url=self.fake.url if self.fake else f"http://127.0.0.1:{free_closed_port()}",
            ha_token_file=self.ha_token_path,
            echo_targets=list(self.targets),
            host="127.0.0.1",
            port=0,
            ha_timeout=2,
        )
        self.server = relay.make_server(self.config)
        self.base = f"http://127.0.0.1:{self.server.server_address[1]}"
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        if self.fake:
            self.fake.close()
        self.tmp.cleanup()

    def request(self, method, path, body=None, token=RELAY_TOKEN, raw=None):
        data = raw if raw is not None else (None if body is None else json.dumps(body, ensure_ascii=False).encode())
        req = urllib.request.Request(self.base + path, data=data, method=method)
        req.add_header("Content-Type", "application/json")
        if token is not None:
            req.add_header("Authorization", f"Bearer {token}")
        try:
            with urllib.request.urlopen(req, timeout=5) as r:
                return r.status, json.loads(r.read())
        except urllib.error.HTTPError as e:
            return e.code, json.loads(e.read())


class SpeakTests(RelayTestBase):
    def test_success_builds_message_and_calls_ha(self):
        status, body = self.request("POST", "/speak", {"from": "家族A", "text": "ご飯できたよ"})
        self.assertEqual(status, 200)
        self.assertEqual(body["message"], "家族Aから。ご飯できたよ")
        calls = self.fake.notify_calls()
        self.assertEqual(len(calls), 1)
        method, path, payload, auth = calls[0]
        self.assertEqual(path, "/api/services/notify/alexa_media")
        self.assertEqual(payload, {"message": "家族Aから。ご飯できたよ", "target": self.targets, "data": {"type": "announce"}})
        self.assertEqual(auth, f"Bearer {HA_TOKEN}")

    def test_no_auth_is_401(self):
        status, body = self.request("POST", "/speak", {"from": "家族B", "text": "a"}, token=None)
        self.assertEqual(status, 401)
        self.assertEqual(body["error"], "unauthorized")
        self.assertEqual(self.fake.notify_calls(), [])

    def test_wrong_token_is_401(self):
        status, _ = self.request("POST", "/speak", {"from": "家族B", "text": "a"}, token="x" * 64)
        self.assertEqual(status, 401)
        self.assertEqual(self.fake.notify_calls(), [])

    def test_empty_text_is_400(self):
        for text in ["", "   ", "\n\t"]:
            status, body = self.request("POST", "/speak", {"from": "家族C", "text": text})
            self.assertEqual(status, 400, text)
            self.assertEqual(body["error"], "bad_request")
        self.assertEqual(self.fake.notify_calls(), [])

    def test_text_over_500_is_400_and_500_is_ok(self):
        status, _ = self.request("POST", "/speak", {"from": "家族C", "text": "あ" * 501})
        self.assertEqual(status, 400)
        status, _ = self.request("POST", "/speak", {"from": "家族C", "text": "あ" * 500})
        self.assertEqual(status, 200)

    def test_from_validation(self):
        for sender in [None, "", "あ" * 21, 123]:
            status, _ = self.request("POST", "/speak", {"from": sender, "text": "やあ"})
            self.assertEqual(status, 400, sender)

    def test_invalid_json_is_400(self):
        status, _ = self.request("POST", "/speak", raw=b"{not json")
        self.assertEqual(status, 400)
        status, _ = self.request("POST", "/speak", raw=b"[1,2]")
        self.assertEqual(status, 400)

    def test_newlines_are_folded(self):
        status, body = self.request("POST", "/speak", {"from": " 家族A ", "text": "お風呂\n沸いたよ"})
        self.assertEqual(status, 200)
        self.assertEqual(body["message"], "家族Aから。お風呂 沸いたよ")

    def test_tts_type(self):
        self.config.speak_type = "tts"
        status, body = self.request("POST", "/speak", {"from": "家族B", "text": "ただいま"})
        self.assertEqual(status, 200)
        self.assertEqual(self.fake.notify_calls()[0][2]["data"], {"type": "tts"})

    def test_unknown_path_is_404(self):
        status, _ = self.request("POST", "/nope", {"from": "家族B", "text": "a"})
        self.assertEqual(status, 404)

    def test_health_without_auth(self):
        status, body = self.request("GET", "/health", token=None)
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")
        self.assertEqual(body["ha"], {"reachable": True})


class HADownTests(RelayTestBase):
    def make_fake_ha(self):
        return None  # 閉じたポートを指す

    def test_speak_is_502_when_ha_down(self):
        status, body = self.request("POST", "/speak", {"from": "家族A", "text": "ご飯できたよ"})
        self.assertEqual(status, 502)
        self.assertFalse(body["ok"])
        self.assertEqual(body["error"], "ha_unreachable")
        self.assertIn("Home Assistant", body["detail"])

    def test_health_still_ok_but_reports_ha(self):
        status, body = self.request("GET", "/health", token=None)
        self.assertEqual(status, 200)
        self.assertEqual(body["status"], "ok")
        self.assertFalse(body["ha"]["reachable"])
        self.assertEqual(body["ha"]["error"], "ha_unreachable")

    def test_auth_checked_before_ha(self):
        status, _ = self.request("POST", "/speak", {"from": "家族A", "text": "x"}, token="bad")
        self.assertEqual(status, 401)


class HAAuthFailTests(RelayTestBase):
    def setUp(self):
        super().setUp()
        self.ha_token_path.write_text("wrong-ha-token")

    def test_ha_rejects_token_is_502(self):
        status, body = self.request("POST", "/speak", {"from": "家族A", "text": "x"})
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "ha_auth_failed")
        self.assertNotIn("wrong-ha-token", json.dumps(body))


class HATokenMissingTests(RelayTestBase):
    def setUp(self):
        super().setUp()
        self.ha_token_path.unlink()

    def test_missing_ha_token_file_is_502(self):
        status, body = self.request("POST", "/speak", {"from": "家族A", "text": "x"})
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "ha_token_missing")


class DiscoveryTemplateTests(RelayTestBase):
    targets: list[str] = []

    def make_fake_ha(self):
        return FakeHA(template_result=["media_player.kitchen", "sensor.foo", "media_player.living"])

    def test_targets_from_integration_entities(self):
        status, body = self.request("POST", "/speak", {"from": "家族B", "text": "いってきます"})
        self.assertEqual(status, 200)
        self.assertEqual(body["targets"], ["media_player.kitchen", "media_player.living"])
        tmpl = [c for c in self.fake.calls if c[1] == "/api/template"][0][2]["template"]
        self.assertIn("integration_entities('alexa_media')", tmpl)


class DiscoveryStatesFallbackTests(RelayTestBase):
    targets: list[str] = []

    def make_fake_ha(self):
        states = [
            {"entity_id": "media_player.echo_dot", "attributes": {"last_called": False, "last_called_summary": None, "locale": "ja-JP"}},
            {"entity_id": "media_player.apple_tv", "attributes": {"friendly_name": "Apple TV"}},
            {"entity_id": "sensor.x", "attributes": {"last_called": True, "last_called_summary": "x"}},
        ]
        return FakeHA(states=states, fail_template=True)

    def test_targets_from_state_attributes(self):
        status, body = self.request("POST", "/speak", {"from": "家族B", "text": "いってきます"})
        self.assertEqual(status, 200)
        self.assertEqual(body["targets"], ["media_player.echo_dot"])


class NoTargetsTests(RelayTestBase):
    targets: list[str] = []

    def test_no_targets_is_502(self):
        status, body = self.request("POST", "/speak", {"from": "家族B", "text": "x"})
        self.assertEqual(status, 502)
        self.assertEqual(body["error"], "no_targets")
        self.assertEqual(self.fake.notify_calls(), [])


class UnitTests(unittest.TestCase):
    def test_build_message(self):
        self.assertEqual(relay.build_message("家族A", "ご飯できたよ"), "家族Aから。ご飯できたよ")

    def test_token_matches(self):
        self.assertTrue(relay.token_matches("Bearer abc", "abc"))
        self.assertTrue(relay.token_matches("bearer abc", "abc"))
        self.assertFalse(relay.token_matches("Bearer abd", "abc"))
        self.assertFalse(relay.token_matches("Basic abc", "abc"))
        self.assertFalse(relay.token_matches(None, "abc"))
        self.assertFalse(relay.token_matches("", "abc"))

    def test_config_load_from_env_file(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / ".env"
            p.write_text(
                "# comment\nFAM_ECHO_TOKEN=" + "a" * 64 + "\n"
                "ECHO_TARGETS = media_player.a, media_player.b ,\n"
                "ECHO_SPEAK_TYPE=tts\nHA_TOKEN_FILE='~/x/.ha-token'\nRELAY_PORT=9999\n"
            )
            c = relay.Config.load(p, environ={})
            self.assertEqual(c.echo_targets, ["media_player.a", "media_player.b"])
            self.assertEqual(c.speak_type, "tts")
            self.assertEqual(c.port, 9999)
            self.assertEqual(c.ha_token_file, Path("~/x/.ha-token").expanduser())
            c2 = relay.Config.load(p, environ={"ECHO_SPEAK_TYPE": "announce"})
            self.assertEqual(c2.speak_type, "announce")

    def test_config_requires_token_and_valid_type(self):
        with tempfile.TemporaryDirectory() as d:
            p = Path(d) / ".env"
            p.write_text("FAM_ECHO_TOKEN=short\n")
            with self.assertRaises(relay.ConfigError):
                relay.Config.load(p, environ={})
            p.write_text("FAM_ECHO_TOKEN=" + "a" * 64 + "\nECHO_SPEAK_TYPE=shout\n")
            with self.assertRaises(relay.ConfigError):
                relay.Config.load(p, environ={})


if __name__ == "__main__":
    unittest.main()
