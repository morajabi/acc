#!/bin/zsh
# Package an already-built app. Compilation belongs in CI.
set -euo pipefail
cd "${0:A:h:h}"
acc_bundle="$PWD/dist/Acc.app"
acc_release_dir="$PWD/dist/release"
acc_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$acc_bundle/Contents/Info.plist")
if [[ -n "${ACC_RELEASE_TAG:-}" && "$ACC_RELEASE_TAG" != "v$acc_version" ]]; then
    print -u2 "Release tag must match app version v$acc_version."
    exit 1
fi
codesign --verify --deep --strict "$acc_bundle"
for acc_architecture in arm64 x86_64; do
    xcrun lipo "$acc_bundle/Contents/MacOS/AccMenuBar" -verify_arch "$acc_architecture"
done
mkdir -p "$acc_release_dir"
rm -f "$acc_release_dir/Acc-macOS.zip"
ditto -c -k --sequesterRsrc --keepParent "$acc_bundle" "$acc_release_dir/Acc-macOS.zip"

if [[ -n "${ACC_NOTARY_PROFILE:-}" ]]; then
    acc_notary_flags=(--keychain-profile "$ACC_NOTARY_PROFILE")
    if [[ -n "${ACC_NOTARY_KEYCHAIN:-}" ]]; then
        acc_notary_flags+=(--keychain "$ACC_NOTARY_KEYCHAIN")
    fi
    xcrun notarytool submit "$acc_release_dir/Acc-macOS.zip" \
        "${acc_notary_flags[@]}" --wait --timeout 30m \
        --output-format json > "$acc_release_dir/notarization.json"
    python3 - "$acc_release_dir/notarization.json" <<'PY'
import json
import sys
with open(sys.argv[1]) as source:
    result = json.load(source)
if result.get('status') != 'Accepted':
    raise SystemExit('Apple did not accept this notarization submission; the release will not be published.')
PY
    xcrun stapler staple "$acc_bundle"
    xcrun stapler validate "$acc_bundle"
    spctl --assess --type execute --verbose "$acc_bundle"
    # The distributed and installed app must contain the same stapled ticket.
    ./scripts/install-app.sh
    rm "$acc_release_dir/Acc-macOS.zip"
    ditto -c -k --sequesterRsrc --keepParent "$acc_bundle" "$acc_release_dir/Acc-macOS.zip"
fi

python3 - "$acc_release_dir" <<'PY'
import hashlib
from pathlib import Path
import sys
release = Path(sys.argv[1])
archive = release / 'Acc-macOS.zip'
hasher = hashlib.sha256()
with archive.open('rb') as source:
    for chunk in iter(lambda: source.read(1024 * 1024), b''):
        hasher.update(chunk)
digest = hasher.hexdigest()
(release / 'SHA256SUMS.txt').write_text(f'{digest}  {archive.name}\n')
PY
print "Packaged Acc $acc_version for Apple silicon and Intel."
print "$acc_release_dir/Acc-macOS.zip"
