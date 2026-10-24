#!/usr/bin/env python3
"""App Store Connect API の小さな道具（TestFlight の外部テスター配布用）。

標準ライブラリだけで動く。JWT（ES256）の署名だけは openssl コマンドに頼る。

    python3 ios/scripts/asc.py [--dry-run] <コマンド>

    register-bundle-id          バンドル ID（jp.kechiiiiin.famecho）を開発者アカウントに登録する（アプリ枠を作る前に要る）
    group                       外部テスターのグループ（TESTFLIGHT_GROUP）を無ければ作る
    invite EMAIL [FIRST LAST]   テスターを足してグループに入れる
    builds                      最近のビルドの処理状況と Beta App Review の状態を見る
    submit-review               最新ビルドにテスト情報を入れ、グループに足して Beta App Review に出す
    jwt                         JWT を作って中身（ヘッダとペイロード）だけ表示する（署名は伏せる）

設定は ios/Release.local.env（見本は ios/Release.example.env）から読む。
--dry-run では HTTP を送らず、送るはずのリクエストを表示する。キーが無ければ使い捨ての鍵で JWT を作る。
"""

from __future__ import annotations

import argparse
import base64
import json
import os
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

API = "https://api.appstoreconnect.apple.com"
BUNDLE_ID = "jp.kechiiiiin.famecho"
IOS_DIR = Path(__file__).resolve().parent.parent
ENV_FILE = IOS_DIR / "Release.local.env"
KEY_DIR = Path.home() / ".appstoreconnect" / "private_keys"


class ASCError(Exception):
    pass


# ---------- 設定 ----------

def load_env(path: Path = ENV_FILE) -> dict[str, str]:
    """KEY=値 の行を読む。# 始まりはコメント、値の \\n は改行にする。環境変数が優先。"""
    conf: dict[str, str] = {}
    if path.exists():
        for raw in path.read_text(encoding="utf-8").splitlines():
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            value = value.strip()
            if len(value) >= 2 and value[0] == value[-1] and value[0] in "\"'":
                value = value[1:-1]
            conf[key.strip()] = value.replace("\\n", "\n")
    for key in list(conf) + ["ASC_KEY_ID", "ASC_ISSUER_ID", "ASC_KEY_PATH"]:
        if os.environ.get(key):
            conf[key] = os.environ[key]
    return conf


def key_path(conf: dict[str, str]) -> Path:
    if conf.get("ASC_KEY_PATH"):
        return Path(os.path.expanduser(conf["ASC_KEY_PATH"]))
    return KEY_DIR / f"AuthKey_{conf.get('ASC_KEY_ID', '')}.p8"


def require_key(conf: dict[str, str]) -> Path:
    missing = [k for k in ("ASC_KEY_ID", "ASC_ISSUER_ID") if not conf.get(k)]
    if missing:
        raise ASCError(
            f"{', '.join(missing)} がありません。ios/Release.example.env を ios/Release.local.env に"
            "コピーして埋めてください（README「配る」の節）。")
    path = key_path(conf)
    if not path.exists():
        raise ASCError(f"API キーが見つかりません: {path}\n"
                       "App Store Connect で作った AuthKey_<KEY_ID>.p8 をそこに置いてください。")
    return path


# ---------- JWT（ES256） ----------

def b64url(data: bytes) -> str:
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode("ascii")


def der_to_raw_signature(der: bytes, size: int = 32) -> bytes:
    """openssl が出す DER の ECDSA 署名（SEQUENCE { INTEGER r, INTEGER s }）を JWS の r||s（64 バイト）にする。"""
    def read_len(buf: bytes, i: int) -> tuple[int, int]:
        n = buf[i]
        if n < 0x80:
            return n, i + 1
        count = n & 0x7F
        return int.from_bytes(buf[i + 1:i + 1 + count], "big"), i + 1 + count

    if der[0] != 0x30:
        raise ASCError("署名が DER の SEQUENCE ではありません")
    _, i = read_len(der, 1)
    parts = []
    for _ in range(2):
        if der[i] != 0x02:
            raise ASCError("署名の INTEGER が読めません")
        length, i = read_len(der, i + 1)
        value = der[i:i + length].lstrip(b"\x00")
        if len(value) > size:
            raise ASCError("署名の整数が長すぎます")
        parts.append(value.rjust(size, b"\x00"))
        i += length
    return parts[0] + parts[1]


def raw_to_der_signature(raw: bytes) -> bytes:
    """テスト用の逆変換（openssl dgst -verify に渡すため）。"""
    def integer(b: bytes) -> bytes:
        b = b.lstrip(b"\x00") or b"\x00"
        if b[0] & 0x80:
            b = b"\x00" + b
        return b"\x02" + bytes([len(b)]) + b
    body = integer(raw[:32]) + integer(raw[32:])
    return b"\x30" + bytes([len(body)]) + body


def openssl_sign(message: bytes, pem_path: Path) -> bytes:
    proc = subprocess.run(["openssl", "dgst", "-sha256", "-sign", str(pem_path)],
                          input=message, capture_output=True, check=False)
    if proc.returncode != 0:
        raise ASCError("openssl で署名できませんでした: " + proc.stderr.decode(errors="replace").strip())
    return proc.stdout


def make_jwt(key_id: str, issuer_id: str, pem_path: Path, now: int | None = None,
             lifetime: int = 15 * 60) -> str:
    """App Store Connect API 用の JWT。有効期限は 20 分以内でなければならない。"""
    now = int(time.time()) if now is None else now
    header = {"alg": "ES256", "kid": key_id, "typ": "JWT"}
    payload = {"iss": issuer_id, "iat": now, "exp": now + lifetime, "aud": "appstoreconnect-v1"}
    signing_input = (b64url(json.dumps(header, separators=(",", ":")).encode()) + "."
                     + b64url(json.dumps(payload, separators=(",", ":")).encode()))
    der = openssl_sign(signing_input.encode("ascii"), pem_path)
    return signing_input + "." + b64url(der_to_raw_signature(der))


def make_throwaway_key(directory: Path) -> Path:
    """dry-run 用の使い捨て P-256 鍵（App Store Connect には通じない）。"""
    path = directory / "dry-run-key.p8"
    subprocess.run(["openssl", "genpkey", "-algorithm", "EC", "-pkeyopt", "ec_paramgen_curve:P-256",
                    "-out", str(path)], check=True, capture_output=True)
    return path


# ---------- HTTP ----------

class Client:
    def __init__(self, token: str, dry_run: bool = False, out=sys.stdout):
        self.token = token
        self.dry_run = dry_run
        self.out = out
        self.sent: list[dict] = []  # dry-run で組み立てたリクエスト（テストで見る）

    def request(self, method: str, path: str, params: dict | None = None, body: dict | None = None) -> dict:
        url = API + path
        if params:
            url += "?" + urllib.parse.urlencode(params, safe="[],")
        data = json.dumps(body, ensure_ascii=False).encode("utf-8") if body is not None else None
        req = urllib.request.Request(url, data=data, method=method)
        req.add_header("Authorization", "Bearer " + self.token)
        if data is not None:
            req.add_header("Content-Type", "application/json")
        if self.dry_run:
            self.sent.append({"method": method, "url": url, "body": body,
                              "headers": dict(req.header_items())})
            print(f"[dry-run] {method} {url}", file=self.out)
            if body is not None:
                print(json.dumps(body, ensure_ascii=False, indent=2), file=self.out)
            return fake_response(method, path)
        try:
            with urllib.request.urlopen(req, timeout=60) as resp:
                raw = resp.read()
                return json.loads(raw) if raw else {}
        except urllib.error.HTTPError as e:
            detail = e.read().decode("utf-8", errors="replace")
            try:
                errors = json.loads(detail).get("errors", [])
                detail = "; ".join(f"{x.get('title')}: {x.get('detail')}" for x in errors) or detail
            except ValueError:
                pass
            raise ASCError(f"{method} {path} → HTTP {e.code}: {detail}") from None

    def get(self, path, params=None):
        return self.request("GET", path, params=params)

    def post(self, path, body):
        return self.request("POST", path, body=body)

    def patch(self, path, body):
        return self.request("PATCH", path, body=body)


def fake_response(method: str, path: str) -> dict:
    """dry-run で流れを最後まで辿れるよう、最小の偽の応答を返す。"""
    if method == "GET" and path == "/v1/apps":
        return {"data": [{"type": "apps", "id": "DRYRUN-APP", "attributes": {"bundleId": BUNDLE_ID}}]}
    if method == "GET" and path == "/v1/builds":
        return {"data": [{"type": "builds", "id": "DRYRUN-BUILD",
                          "attributes": {"version": "20261024.12000", "processingState": "VALID",
                                         "uploadedDate": "2026-10-24T12:00:00Z", "expired": False},
                          "relationships": {}}], "included": []}
    if method == "GET" and path.endswith("/betaAppReviewDetail"):
        return {"data": {"type": "betaAppReviewDetails", "id": "DRYRUN-DETAIL"}}
    if method == "GET":
        return {"data": []}
    return {"data": {"type": "dry-run", "id": "DRYRUN-NEW"}}


# ---------- 操作 ----------

def register_bundle_id(c: Client) -> None:
    res = c.get("/v1/bundleIds", {"filter[identifier]": BUNDLE_ID, "limit": "5"})
    for b in res.get("data", []):
        if b.get("attributes", {}).get("identifier") == BUNDLE_ID:
            print(f"{BUNDLE_ID} は登録済みです（{b['id']}）")
            return
    c.post("/v1/bundleIds", {"data": {
        "type": "bundleIds",
        "attributes": {"identifier": BUNDLE_ID, "name": "fam-echo", "platform": "IOS"},
    }})
    print(f"{BUNDLE_ID} を登録しました。App Store Connect の新規 App でバンドル ID に選べます")


def find_app(c: Client) -> str:
    res = c.get("/v1/apps", {"filter[bundleId]": BUNDLE_ID, "limit": "1"})
    if not res.get("data"):
        raise ASCError(f"App Store Connect に {BUNDLE_ID} のアプリがありません（マイ App → ＋ → 新規 App で作る）")
    return res["data"][0]["id"]


def ensure_group(c: Client, app_id: str, name: str) -> str:
    res = c.get("/v1/betaGroups", {"filter[app]": app_id, "filter[name]": name, "limit": "10"})
    for g in res.get("data", []):
        if g.get("attributes", {}).get("name") == name and not g["attributes"].get("isInternalGroup"):
            print(f"グループ「{name}」はあります（{g['id']}）")
            return g["id"]
    created = c.post("/v1/betaGroups", {"data": {
        "type": "betaGroups",
        "attributes": {"name": name, "isInternalGroup": False, "publicLinkEnabled": False},
        "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
    }})
    print(f"外部テスターのグループ「{name}」を作りました（{created['data']['id']}）")
    return created["data"]["id"]


def invite(c: Client, app_id: str, group_name: str, email: str, first: str = "", last: str = "") -> None:
    group_id = ensure_group(c, app_id, group_name)
    existing = c.get("/v1/betaTesters", {"filter[email]": email, "limit": "1"}).get("data", [])
    if existing:
        tester_id = existing[0]["id"]
        c.post(f"/v1/betaGroups/{group_id}/relationships/betaTesters",
               {"data": [{"type": "betaTesters", "id": tester_id}]})
        print(f"既存のテスター {email} をグループに足しました")
        return
    attrs = {"email": email}
    if first:
        attrs["firstName"] = first
    if last:
        attrs["lastName"] = last
    c.post("/v1/betaTesters", {"data": {
        "type": "betaTesters", "attributes": attrs,
        "relationships": {"betaGroups": {"data": [{"type": "betaGroups", "id": group_id}]}},
    }})
    print(f"{email} をテスターに足しました（グループにビルドが入っていれば招待メールが届きます）")


def list_builds(c: Client, app_id: str, limit: int = 5) -> list[dict]:
    res = c.get("/v1/builds", {
        "filter[app]": app_id, "sort": "-uploadedDate", "limit": str(limit),
        "include": "buildBetaDetail,betaAppReviewSubmission",
    })
    included = {(x["type"], x["id"]): x for x in res.get("included", [])}
    rows = []
    for b in res.get("data", []):
        rel = b.get("relationships", {})
        detail = included.get(("buildBetaDetails", (rel.get("buildBetaDetail", {}).get("data") or {}).get("id")))
        review = included.get(("betaAppReviewSubmissions",
                               (rel.get("betaAppReviewSubmission", {}).get("data") or {}).get("id")))
        a = b.get("attributes", {})
        rows.append({
            "id": b["id"], "version": a.get("version"), "processing": a.get("processingState"),
            "uploaded": a.get("uploadedDate"), "expired": a.get("expired"),
            "external": (detail or {}).get("attributes", {}).get("externalBuildState"),
            "review": (review or {}).get("attributes", {}).get("betaReviewState"),
        })
    return rows


def print_builds(rows: list[dict]) -> None:
    if not rows:
        print("ビルドはまだありません（make upload で上げる）")
        return
    print(f"{'ビルド':<16} {'処理':<12} {'外部テスト':<28} {'審査':<16} アップロード")
    for r in rows:
        print(f"{r['version'] or '':<16} {r['processing'] or '-':<12} {r['external'] or '-':<28} "
              f"{r['review'] or '-':<16} {r['uploaded'] or ''}{'（期限切れ）' if r['expired'] else ''}")


REVIEW_FIELDS = {
    "contactFirstName": "REVIEW_CONTACT_FIRST_NAME",
    "contactLastName": "REVIEW_CONTACT_LAST_NAME",
    "contactEmail": "REVIEW_CONTACT_EMAIL",
    "contactPhone": "REVIEW_CONTACT_PHONE",
}


def check_review_config(conf: dict[str, str]) -> None:
    need = list(REVIEW_FIELDS.values()) + ["BETA_DESCRIPTION", "BETA_FEEDBACK_EMAIL"]
    missing = [k for k in need if not conf.get(k)]
    if missing:
        raise ASCError("Beta App Review に要るテスト情報が空です: " + ", ".join(missing)
                       + "\nios/Release.local.env に書いてください。")


def upsert_beta_app_localization(c: Client, app_id: str, conf: dict[str, str]) -> None:
    locale = conf.get("BETA_LOCALE") or "ja"
    attrs = {"description": conf["BETA_DESCRIPTION"], "feedbackEmail": conf["BETA_FEEDBACK_EMAIL"]}
    if conf.get("BETA_PRIVACY_POLICY_URL"):
        attrs["privacyPolicyUrl"] = conf["BETA_PRIVACY_POLICY_URL"]
    res = c.get("/v1/betaAppLocalizations", {"filter[app]": app_id, "filter[locale]": locale})
    if res.get("data"):
        loc_id = res["data"][0]["id"]
        c.patch(f"/v1/betaAppLocalizations/{loc_id}",
                {"data": {"type": "betaAppLocalizations", "id": loc_id, "attributes": attrs}})
    else:
        c.post("/v1/betaAppLocalizations", {"data": {
            "type": "betaAppLocalizations", "attributes": {"locale": locale, **attrs},
            "relationships": {"app": {"data": {"type": "apps", "id": app_id}}},
        }})


def update_review_detail(c: Client, app_id: str, conf: dict[str, str]) -> None:
    detail_id = c.get(f"/v1/apps/{app_id}/betaAppReviewDetail")["data"]["id"]
    attrs = {api: conf[key] for api, key in REVIEW_FIELDS.items()}
    attrs["demoAccountRequired"] = False
    if conf.get("REVIEW_NOTES"):
        attrs["notes"] = conf["REVIEW_NOTES"]
    c.patch(f"/v1/betaAppReviewDetails/{detail_id}",
            {"data": {"type": "betaAppReviewDetails", "id": detail_id, "attributes": attrs}})


def set_what_to_test(c: Client, build_id: str, conf: dict[str, str]) -> None:
    text = conf.get("WHAT_TO_TEST")
    if not text:
        return
    locale = conf.get("BETA_LOCALE") or "ja"
    res = c.get(f"/v1/builds/{build_id}/betaBuildLocalizations")
    for loc in res.get("data", []):
        if loc.get("attributes", {}).get("locale") == locale:
            c.patch(f"/v1/betaBuildLocalizations/{loc['id']}",
                    {"data": {"type": "betaBuildLocalizations", "id": loc["id"],
                              "attributes": {"whatsNew": text}}})
            return
    c.post("/v1/betaBuildLocalizations", {"data": {
        "type": "betaBuildLocalizations", "attributes": {"locale": locale, "whatsNew": text},
        "relationships": {"build": {"data": {"type": "builds", "id": build_id}}},
    }})


def submit_review(c: Client, app_id: str, conf: dict[str, str]) -> None:
    check_review_config(conf)
    rows = list_builds(c, app_id, limit=1)
    if not rows:
        raise ASCError("ビルドがありません（make upload で上げてから）")
    build = rows[0]
    if build["processing"] != "VALID":
        raise ASCError(f"最新ビルド {build['version']} はまだ処理中です（{build['processing']}）。"
                       "数分〜数十分おいて builds で確かめてください。")
    if build["review"] in ("WAITING_FOR_REVIEW", "IN_REVIEW", "APPROVED"):
        print(f"ビルド {build['version']} はすでに審査に出ています（{build['review']}）")
        return
    upsert_beta_app_localization(c, app_id, conf)
    update_review_detail(c, app_id, conf)
    set_what_to_test(c, build["id"], conf)
    group_id = ensure_group(c, app_id, conf.get("TESTFLIGHT_GROUP") or "家族")
    c.post(f"/v1/betaGroups/{group_id}/relationships/builds",
           {"data": [{"type": "builds", "id": build["id"]}]})
    c.post("/v1/betaAppReviewSubmissions", {"data": {
        "type": "betaAppReviewSubmissions",
        "relationships": {"build": {"data": {"type": "builds", "id": build["id"]}}},
    }})
    print(f"ビルド {build['version']} を Beta App Review に出しました（通ればグループのテスターに届きます）")


# ---------- 入口 ----------

def build_client(conf: dict[str, str], dry_run: bool, tmp: Path) -> Client:
    try:
        path = require_key(conf)
        key_id, issuer = conf["ASC_KEY_ID"], conf["ASC_ISSUER_ID"]
    except ASCError:
        if not dry_run:
            raise
        print("[dry-run] API キーが無いので、使い捨ての鍵で JWT を作ります（実際の API には通じません）")
        path = make_throwaway_key(tmp)
        key_id, issuer = conf.get("ASC_KEY_ID") or "DRYRUNKEY0", conf.get("ASC_ISSUER_ID") or "00000000-0000-0000-0000-000000000000"
    return Client(make_jwt(key_id, issuer, path), dry_run=dry_run)


def decode_part(part: str) -> dict:
    return json.loads(base64.urlsafe_b64decode(part + "=" * (-len(part) % 4)))


def main(argv: list[str] | None = None) -> int:
    p = argparse.ArgumentParser(description="App Store Connect（TestFlight）の道具")
    p.add_argument("--dry-run", action="store_true", help="HTTP を送らず、送るはずのリクエストを表示する")
    sub = p.add_subparsers(dest="cmd", required=True)
    sub.add_parser("register-bundle-id")
    sub.add_parser("group")
    inv = sub.add_parser("invite")
    inv.add_argument("email")
    inv.add_argument("first", nargs="?", default="")
    inv.add_argument("last", nargs="?", default="")
    sub.add_parser("builds")
    sub.add_parser("submit-review")
    sub.add_parser("jwt")
    args = p.parse_args(argv)

    conf = load_env()
    try:
        with tempfile.TemporaryDirectory() as tmp:
            c = build_client(conf, args.dry_run, Path(tmp))
        if args.cmd == "jwt":
            h, pl, sig = c.token.split(".")
            print(json.dumps({"header": decode_part(h), "payload": decode_part(pl),
                              "signature_bytes": len(base64.urlsafe_b64decode(sig + "=" * (-len(sig) % 4)))},
                             ensure_ascii=False, indent=2))
            return 0
        if args.cmd == "register-bundle-id":
            register_bundle_id(c)
            return 0
        app_id = find_app(c)
        group = conf.get("TESTFLIGHT_GROUP") or "家族"
        if args.cmd == "group":
            ensure_group(c, app_id, group)
        elif args.cmd == "invite":
            invite(c, app_id, group, args.email, args.first, args.last)
        elif args.cmd == "builds":
            print_builds(list_builds(c, app_id))
        elif args.cmd == "submit-review":
            if args.dry_run:
                for key in list(REVIEW_FIELDS.values()) + ["BETA_DESCRIPTION", "BETA_FEEDBACK_EMAIL"]:
                    if not conf.get(key):
                        print(f"[dry-run] {key} が空なので仮の値で続けます（本番では止まります）")
                        conf[key] = f"<{key}>"
            submit_review(c, app_id, conf)
    except ASCError as e:
        print(f"止めました: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
