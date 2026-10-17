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
print "Installed /Applications/Acc.app. Relaunch Acc to use this build."
