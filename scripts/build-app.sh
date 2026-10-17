#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
acc_build_flags=(-c release --jobs "${ACC_BUILD_JOBS:-2}")
if [[ "${ACC_UNIVERSAL:-0}" == 1 ]]; then
    acc_build_flags+=(--arch arm64 --arch x86_64)
fi
swift build "${acc_build_flags[@]}"
acc_bin_dir=$(swift build "${acc_build_flags[@]}" --show-bin-path)
mkdir -p "$PWD/dist"
acc_stage=$(mktemp -d "$PWD/dist/.build.XXXXXX")
trap 'rm -rf "$acc_stage"' EXIT
acc_bundle="$acc_stage/Acc.app"
mkdir -p "$acc_bundle/Contents/MacOS" "$acc_bundle/Contents/Resources"
cp "$acc_bin_dir/AccMenuBar" "$acc_bundle/Contents/MacOS/AccMenuBar"
cp "$acc_bin_dir/acc" "$acc_stage/acc"
cp Resources/Info.plist "$acc_bundle/Contents/Info.plist"
swift scripts/make-icon.swift "$acc_bundle/Contents/Resources/Acc.icns"
cp docs/THIRD_PARTY_NOTICES.md "$acc_bundle/Contents/Resources/ThirdPartyNotices.md"
cp docs/licenses/CodexBar.txt "$acc_bundle/Contents/Resources/CodexBar-License.txt"
cp LICENSE "$acc_bundle/Contents/Resources/LICENSE.txt"
# A stable signing identity preserves Keychain trust across rebuilds. Use an
# explicit override, otherwise the single available Developer ID identity.
acc_sign_identity=${ACC_SIGN_IDENTITY:-}
if [[ -z "$acc_sign_identity" ]]; then
    acc_sign_identity=$(python3 - <<'PY'
import re
import subprocess
result = subprocess.run(['security', 'find-identity', '-v', '-p', 'codesigning'], capture_output=True, text=True)
identities = re.findall(r'\b([0-9A-F]{40}) "Developer ID Application:[^"\n]+"', result.stdout)
print(identities[0] if len(identities) == 1 else '-')
PY
    )
fi
acc_sign_flags=(--force --sign "$acc_sign_identity")
if [[ "$acc_sign_identity" != - ]]; then
    acc_sign_flags+=(--options runtime --timestamp)
fi
codesign "${acc_sign_flags[@]}" "$acc_bundle"
codesign "${acc_sign_flags[@]}" --identifier dev.mo.acc.cli "$acc_stage/acc"
# Stage a complete signed bundle; never truncate an executable that may be running.
python3 - "$acc_stage" "$PWD/dist" <<'PY'
import os
from pathlib import Path
import sys
stage, destination = map(Path, sys.argv[1:])
old = stage / 'Previous.app'
app = destination / 'Acc.app'
if app.exists():
    os.rename(app, old)
try:
    os.rename(stage / 'Acc.app', app)
except BaseException:
    if old.exists():
        os.rename(old, app)
    raise
os.replace(stage / 'acc', destination / 'acc')
PY
print "Built $PWD/dist/Acc.app and $PWD/dist/acc"
./scripts/install-app.sh
