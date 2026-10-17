#!/bin/zsh
# Launch a separate, credential-free copy beside the installed app.
set -euo pipefail
cd "${0:A:h:h}"
acc_preview="$PWD/dist/Acc Preview.app"
[[ -d dist/Acc.app ]] || { print -u2 'Run scripts/build-app.sh first.'; exit 1; }
# Stop only the isolated preview. The installed app keeps maintaining accounts.
swift - <<'SWIFT'
import AppKit
let previews = NSRunningApplication.runningApplications(withBundleIdentifier: "dev.mo.acc.preview")
for app in previews { _ = app.terminate() }
let deadline = Date().addingTimeInterval(10)
while previews.contains(where: { !$0.isTerminated }), Date() < deadline { Thread.sleep(forTimeInterval: 0.1) }
guard previews.allSatisfy(\.isTerminated) else {
    fputs("Quit Acc Preview, then try again.\n", stderr)
    exit(1)
}
SWIFT
acc_stage=$(mktemp -d "$PWD/dist/.preview.XXXXXX")
trap 'rm -rf "$acc_stage"' EXIT
ditto dist/Acc.app "$acc_stage/Acc Preview.app"
/usr/libexec/PlistBuddy -c 'Set :CFBundleIdentifier dev.mo.acc.preview' "$acc_stage/Acc Preview.app/Contents/Info.plist"
/usr/libexec/PlistBuddy -c 'Set :CFBundleName Acc Preview' "$acc_stage/Acc Preview.app/Contents/Info.plist"
codesign --force --sign - "$acc_stage/Acc Preview.app"
if [[ -d "$acc_preview" ]]; then mv "$acc_preview" "$acc_stage/Previous.app"; fi
mv "$acc_stage/Acc Preview.app" "$acc_preview"
open "$acc_preview" --args --window --demo
