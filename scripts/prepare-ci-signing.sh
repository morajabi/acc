#!/bin/zsh
# Optional CI signing. Certificate material is supplied by the repository owner;
# this script never exports keys from a developer's machine.
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true ]] || { print -u2 'This script is only for GitHub Actions.'; exit 1; }
umask 077
python3 - <<'PY'
import base64
import os
from pathlib import Path
import re
import secrets
import shlex
import subprocess

certificate_names = ('ACC_CERTIFICATE_P12', 'ACC_CERTIFICATE_PASSWORD')
notary_names = ('ACC_APPLE_ID', 'ACC_APPLE_APP_PASSWORD', 'ACC_APPLE_TEAM_ID')
certificate = [bool(os.environ.get(name)) for name in certificate_names]
notary = [bool(os.environ.get(name)) for name in notary_names]
if any(certificate) and not all(certificate):
    raise SystemExit('Configure both certificate secrets, or neither.')
if any(notary) and not all(notary):
    raise SystemExit('Configure all three notarization secrets, or none.')
if any(notary) and not all(certificate):
    raise SystemExit('Notarization requires a Developer ID signing certificate.')

with open(os.environ['GITHUB_ENV'], 'a') as output:
    output.write('ACC_SIGN_IDENTITY=-\n')
    if not all(certificate):
        print('No signing secrets configured: the release will be ad-hoc signed and not notarized.')
        raise SystemExit(0)

    temporary = Path(os.environ['RUNNER_TEMP'])
    keychain = temporary / 'acc-signing.keychain-db'
    p12 = temporary / 'acc-signing.p12'
    password = secrets.token_urlsafe(32)
    p12.write_bytes(base64.b64decode(os.environ['ACC_CERTIFICATE_P12'], validate=True))
    def run(*arguments):
        return subprocess.run(arguments, check=True, capture_output=True, text=True).stdout
    try:
        run('security', 'create-keychain', '-p', password, str(keychain))
        run('security', 'set-keychain-settings', '-lut', '21600', str(keychain))
        run('security', 'unlock-keychain', '-p', password, str(keychain))
        existing = shlex.split(run('security', 'list-keychains', '-d', 'user'))
        run('security', 'list-keychains', '-d', 'user', '-s', str(keychain), *existing)
        run('security', 'import', str(p12), '-k', str(keychain),
            '-P', os.environ['ACC_CERTIFICATE_PASSWORD'], '-T', '/usr/bin/codesign')
        run('security', 'set-key-partition-list', '-S', 'apple-tool:,apple:,codesign:',
            '-s', '-k', password, str(keychain))
        identities = re.findall(r'\b([0-9A-F]{40}) "Developer ID Application:[^"\n]+"',
            run('security', 'find-identity', '-v', '-p', 'codesigning', str(keychain)))
        if len(identities) != 1:
            raise SystemExit('The certificate must contain one valid Developer ID Application identity.')
        output.write(f'ACC_SIGN_IDENTITY={identities[0]}\n')
        if all(notary):
            run('xcrun', 'notarytool', 'store-credentials', 'AccRelease',
                '--apple-id', os.environ['ACC_APPLE_ID'],
                '--password', os.environ['ACC_APPLE_APP_PASSWORD'],
                '--team-id', os.environ['ACC_APPLE_TEAM_ID'], '--keychain', str(keychain))
            output.write('ACC_NOTARY_PROFILE=AccRelease\n')
            output.write(f'ACC_NOTARY_KEYCHAIN={keychain}\n')
    except subprocess.CalledProcessError:
        # Some tool failures echo arguments. Never emit secret-bearing commands.
        raise SystemExit('Could not prepare the signing keychain or notarization credentials.') from None
    finally:
        p12.unlink(missing_ok=True)
PY
