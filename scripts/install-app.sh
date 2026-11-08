#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"
# Copy and verify a complete bundle before replacing the installed app. A running
# process keeps its old executable until it quits normally; never truncate it.
acc_install_stage=$(mktemp -d /Applications/.acc-install.XXXXXX)
trap 'rm -rf "$acc_install_stage"' EXIT
ditto "$PWD/dist/Acc.app" "$acc_install_stage/Acc.app"
codesign --verify --deep --strict "$acc_install_stage/Acc.app"
python3 - "$acc_install_stage" <<'PY'
import os
from pathlib import Path
import sys
stage = Path(sys.argv[1])
installed = Path('/Applications/Acc.app')
previous = stage / 'Previous.app'
if installed.exists():
    os.rename(installed, previous)
try:
    os.rename(stage / 'Acc.app', installed)
except BaseException:
    if previous.exists():
        os.rename(previous, installed)
    raise
PY
print "Installed /Applications/Acc.app."
[[ -n ${CI:-} ]] && exit 0
acc_running=$(pgrep -f '^/Applications/Acc.app/Contents/MacOS/AccMenuBar' || true)
[[ -z $acc_running ]] && exit 0
osascript -e 'tell application id "dev.mo.acc" to quit' >/dev/null 2>&1 || true
for _ in {1..150}; do
    pgrep -f '^/Applications/Acc.app/Contents/MacOS/AccMenuBar' >/dev/null || break
    sleep 0.2
done
if pgrep -f '^/Applications/Acc.app/Contents/MacOS/AccMenuBar' >/dev/null; then
    print -u2 'Acc is still finishing work; quit and reopen it to use this build.'
else
    open /Applications/Acc.app
    print 'Relaunched Acc.'
fi
