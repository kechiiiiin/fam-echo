#!/usr/bin/env python3
"""実機の一覧と、名前／UDID から xcodebuild 用の UDID と devicectl 用の識別子を引く。

    python3 ios/scripts/device.py list
    python3 ios/scripts/device.py resolve <名前かUDIDか識別子>   → "<udid> <identifier>" を1行で出す

シミュレータは除く。名前は完全一致を先に、無ければ部分一致（大文字小文字は無視）が1台だけのときに使う。
"""

import json
import subprocess
import sys
import tempfile
from pathlib import Path


def devices() -> list[dict]:
    with tempfile.TemporaryDirectory() as d:
        out = Path(d) / "devices.json"
        proc = subprocess.run(["xcrun", "devicectl", "list", "devices", "--json-output", str(out)],
                              capture_output=True, text=True)
        if proc.returncode != 0 or not out.exists():
            sys.exit("devicectl で端末一覧が取れませんでした:\n" + proc.stderr)
        data = json.loads(out.read_text())
    rows = []
    for x in data.get("result", {}).get("devices", []):
        hw, dp, cp = x.get("hardwareProperties", {}), x.get("deviceProperties", {}), x.get("connectionProperties", {})
        if hw.get("reality") != "physical":
            continue
        rows.append({
            "name": dp.get("name", ""), "udid": hw.get("udid", ""), "identifier": x.get("identifier", ""),
            "model": hw.get("marketingName", ""), "os": dp.get("osVersionNumber", ""),
            "transport": cp.get("transportType") or "-", "tunnel": cp.get("tunnelState") or "-",
            "devmode": dp.get("developerModeStatus") or "-",
        })
    return rows


def resolve(query: str, rows: list[dict]) -> dict:
    q = query.strip().lower()
    for r in rows:
        if q in (r["udid"].lower(), r["identifier"].lower(), r["name"].lower()):
            return r
    hits = [r for r in rows if q in r["name"].lower()]
    if len(hits) == 1:
        return hits[0]
    names = ", ".join(r["name"] for r in (hits or rows)) or "（実機が1台も見えません）"
    sys.exit(f"DEVICE={query} に当たる端末を1台に絞れません。候補: {names}")


def main() -> None:
    if len(sys.argv) >= 2 and sys.argv[1] == "list":
        rows = devices()
        if not rows:
            print("実機が見えません（一度ケーブルで繋いで「このコンピュータを信頼」してから）")
            return
        print(f"{'名前':<28} {'機種':<22} {'iOS':<8} {'接続':<10} {'トンネル':<14} {'デベロッパモード':<10} UDID")
        for r in rows:
            print(f"{r['name']:<28} {r['model']:<22} {r['os']:<8} {r['transport']:<10} {r['tunnel']:<14} "
                  f"{r['devmode']:<10} {r['udid']}")
    elif len(sys.argv) == 3 and sys.argv[1] == "resolve":
        r = resolve(sys.argv[2], devices())
        print(r["udid"], r["identifier"])
    else:
        sys.exit(__doc__)


if __name__ == "__main__":
    main()
