"""asc.py の単体テスト（API は叩かない）。  python3 -m unittest discover -s ios/scripts -v"""

import base64
import io
import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import asc  # noqa: E402


def unb64(part: str) -> bytes:
    return base64.urlsafe_b64decode(part + "=" * (-len(part) % 4))


class JWTTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.dir = Path(self.tmp.name)
        self.key = asc.make_throwaway_key(self.dir)
        pub = self.dir / "pub.pem"
        subprocess.run(["openssl", "pkey", "-in", str(self.key), "-pubout", "-out", str(pub)], check=True,
                       capture_output=True)
        self.pub = pub

    def tearDown(self):
        self.tmp.cleanup()

    def test_header_and_payload(self):
        token = asc.make_jwt("ABC123DEFG", "11111111-2222-3333-4444-555555555555", self.key, now=1_700_000_000)
        h, p, s = token.split(".")
        self.assertEqual(json.loads(unb64(h)), {"alg": "ES256", "kid": "ABC123DEFG", "typ": "JWT"})
        payload = json.loads(unb64(p))
        self.assertEqual(payload["iss"], "11111111-2222-3333-4444-555555555555")
        self.assertEqual(payload["aud"], "appstoreconnect-v1")
        self.assertEqual(payload["iat"], 1_700_000_000)
        self.assertLessEqual(payload["exp"] - payload["iat"], 20 * 60)  # Apple の上限は 20 分
        self.assertEqual(len(unb64(s)), 64)  # ES256 は r||s の 64 バイト（DER ではない）

    def test_signature_verifies_with_openssl(self):
        for _ in range(5):  # r/s の先頭が 0 になる回もあるので何度か
            token = asc.make_jwt("K", "I", self.key)
            signing_input, sig = token.rsplit(".", 1)
            der = asc.raw_to_der_signature(unb64(sig))
            sig_file = self.dir / "sig.der"
            sig_file.write_bytes(der)
            proc = subprocess.run(["openssl", "dgst", "-sha256", "-verify", str(self.pub), "-signature",
                                   str(sig_file)], input=signing_input.encode(), capture_output=True)
            self.assertEqual(proc.returncode, 0, proc.stdout + proc.stderr)

    def test_der_roundtrip_with_short_integers(self):
        raw = b"\x00" * 31 + b"\x01" + b"\x80" + b"\x11" * 31
        self.assertEqual(asc.der_to_raw_signature(asc.raw_to_der_signature(raw)), raw)


class ConfigTest(unittest.TestCase):
    def test_load_env(self):
        with tempfile.TemporaryDirectory() as d:
            f = Path(d) / "x.env"
            f.write_text("# コメント\nASC_KEY_ID=ABC\nREVIEW_NOTES=一行目\\n二行目\nEMPTY=\nQ=\"引用\"\n",
                         encoding="utf-8")
            conf = asc.load_env(f)
        self.assertEqual(conf["ASC_KEY_ID"], "ABC")
        self.assertEqual(conf["REVIEW_NOTES"], "一行目\n二行目")
        self.assertEqual(conf["EMPTY"], "")
        self.assertEqual(conf["Q"], "引用")

    def test_missing_key_message(self):
        with self.assertRaises(asc.ASCError) as cm:
            asc.require_key({"ASC_KEY_ID": "NOPE", "ASC_ISSUER_ID": "x", "ASC_KEY_PATH": "/nonexistent/AuthKey.p8"})
        self.assertIn("API キーが見つかりません", str(cm.exception))
        with self.assertRaises(asc.ASCError):
            asc.require_key({})


class RequestShapeTest(unittest.TestCase):
    def client(self):
        return asc.Client("TOKEN", dry_run=True, out=io.StringIO())

    def test_invite_new_tester(self):
        c = self.client()
        asc.invite(c, "APP1", "家族", "a@example.com", "Taro", "Yamada")
        methods = [(r["method"], r["url"].split("?")[0]) for r in c.sent]
        self.assertEqual(methods, [
            ("GET", asc.API + "/v1/betaGroups"),
            ("POST", asc.API + "/v1/betaGroups"),
            ("GET", asc.API + "/v1/betaTesters"),
            ("POST", asc.API + "/v1/betaTesters"),
        ])
        group = c.sent[1]["body"]["data"]
        self.assertEqual(group["attributes"]["isInternalGroup"], False)
        self.assertEqual(group["relationships"]["app"]["data"], {"type": "apps", "id": "APP1"})
        tester = c.sent[3]["body"]["data"]
        self.assertEqual(tester["type"], "betaTesters")
        self.assertEqual(tester["attributes"], {"email": "a@example.com", "firstName": "Taro", "lastName": "Yamada"})
        self.assertEqual(tester["relationships"]["betaGroups"]["data"][0]["type"], "betaGroups")
        self.assertEqual(c.sent[0]["headers"]["Authorization"], "Bearer TOKEN")
        self.assertIn("filter[app]=APP1", c.sent[0]["url"])
        self.assertEqual(c.sent[3]["headers"]["Content-type"], "application/json")

    def test_submit_review(self):
        c = self.client()
        conf = {k: "x" for k in list(asc.REVIEW_FIELDS.values()) + ["BETA_DESCRIPTION", "BETA_FEEDBACK_EMAIL"]}
        conf["WHAT_TO_TEST"] = "送れるか"
        asc.submit_review(c, "APP1", conf)
        posts = [(r["method"], r["url"].split("?")[0].replace(asc.API, "")) for r in c.sent if r["method"] != "GET"]
        self.assertIn(("PATCH", "/v1/betaAppReviewDetails/DRYRUN-DETAIL"), posts)
        self.assertIn(("POST", "/v1/betaAppLocalizations"), posts)
        self.assertIn(("POST", "/v1/betaBuildLocalizations"), posts)
        self.assertIn(("POST", "/v1/betaGroups/DRYRUN-NEW/relationships/builds"), posts)
        self.assertEqual(posts[-1], ("POST", "/v1/betaAppReviewSubmissions"))
        sub = c.sent[-1]["body"]["data"]
        self.assertEqual(sub["relationships"]["build"]["data"], {"type": "builds", "id": "DRYRUN-BUILD"})
        detail = next(r for r in c.sent if r["method"] == "PATCH" and "betaAppReviewDetails" in r["url"])
        self.assertEqual(detail["body"]["data"]["attributes"]["demoAccountRequired"], False)

    def test_register_bundle_id(self):
        c = self.client()
        asc.register_bundle_id(c)
        self.assertEqual(c.sent[-1]["method"], "POST")
        self.assertTrue(c.sent[-1]["url"].endswith("/v1/bundleIds"))
        self.assertEqual(c.sent[-1]["body"]["data"]["attributes"],
                         {"identifier": "jp.kechiiiiin.famecho", "name": "fam-echo", "platform": "IOS"})

    def test_submit_review_requires_contact(self):
        with self.assertRaises(asc.ASCError) as cm:
            asc.submit_review(self.client(), "APP1", {})
        self.assertIn("REVIEW_CONTACT_EMAIL", str(cm.exception))


if __name__ == "__main__":
    unittest.main()
