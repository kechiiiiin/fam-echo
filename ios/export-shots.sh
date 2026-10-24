#!/bin/sh
# UI テストの結果（既定 build/uitest.xcresult・引数で別の .xcresult）から名前つきスクリーンショットを docs/ に書き出す
set -eu
cd "$(dirname "$0")"
result=${1:-build/uitest.xcresult}
out=build/attachments
rm -rf "$out"
xcrun xcresulttool export attachments --path "$result" --output-path "$out" >/dev/null
mkdir -p docs
python3 - "$out" <<'PY'
import json, re, shutil, subprocess, sys
out = sys.argv[1]
for test in json.load(open(f"{out}/manifest.json")):
    for a in test["attachments"]:
        name = a.get("suggestedHumanReadableName", "")
        m = re.match(r"(\d\d-[\w-]+?)_\d+_", name)
        if m and a["exportedFileName"].endswith(".png"):
            dst = f"docs/{m.group(1)}.png"
            shutil.copy(f"{out}/{a['exportedFileName']}", dst)
            subprocess.run(["sips", "-Z", "900", dst], capture_output=True)
            print(dst)
PY
