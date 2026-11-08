#!/bin/zsh
set -euo pipefail
cd "${0:A:h:h}"

[[ $(git branch --show-current) == main ]] || { print -u2 'Switch to main to release.'; exit 1; }
[[ -z $(git status --porcelain) ]] || { print -u2 'Commit or stash your changes first.'; exit 1; }
git fetch --quiet --tags origin
[[ $(git rev-list --count HEAD..origin/main) == 0 ]] || { print -u2 'Pull origin/main first.'; exit 1; }
[[ $(git rev-list --count origin/main..HEAD) != 0 ]] || { print 'Nothing to push.'; exit 0; }

swift test
scripts/build-app.sh

acc_version=$(python3 scripts/next-version.py)
acc_head=$(git rev-parse HEAD)
git push origin main
print "Pushed. Release v$acc_version will publish once the Release workflow passes."

command -v gh >/dev/null || exit 0
for _ in {1..30}; do
    acc_run=$(gh run list --workflow release.yml --commit "$acc_head" --json databaseId --jq '.[0].databaseId // empty')
    [[ -n $acc_run ]] && break
    sleep 2
done
if [[ -z ${acc_run:-} ]]; then
    print 'No Release run started; docs-only and [skip ci] pushes do not release.'
    exit 0
fi
gh run watch "$acc_run" --exit-status
gh release view "v$acc_version" --json url --jq .url
