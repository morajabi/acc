#!/usr/bin/env python3
"""Exercise shipping CLI workflows offline, with synthetic credentials and isolated homes."""
import base64
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

binary = Path(sys.argv[1] if len(sys.argv) > 1 else 'dist/acc').resolve()


def fixture(user, rotation=0):
    now = time.time()
    claims = {'sub': user, 'email': user + '@example.test', 'iat': now, 'exp': now + 7200,
              'https://api.openai.com/auth': {'chatgpt_account_id': 'personal', 'chatgpt_user_id': user}}
    token = 'fixture.' + base64.urlsafe_b64encode(json.dumps(claims).encode()).decode().rstrip('=') + '.fixture'
    return {'auth_mode': 'chatgpt', 'tokens': {'access_token': token, 'id_token': token,
            'refresh_token': f'fixture-{user}-{rotation}', 'account_id': 'personal'}, 'future': {'keep': True}}


with tempfile.TemporaryDirectory(prefix='acc-cli-smoke-') as directory:
    root = Path(directory)
    env = {**os.environ, 'ACC_HOME': str(root / 'acc'), 'CODEX_HOME': str(root / 'codex'),
           'CLAUDE_CONFIG_DIR': str(root / 'claude'), 'CLAUDE_SECURESTORAGE_CONFIG_DIR': str(root / 'claude')}
    (root / 'codex').mkdir()
    (root / 'codex' / 'config.toml').write_text('model = "fixture-model"\n')
    native = root / 'codex' / 'auth.json'
    native.write_text(json.dumps(fixture('alice')))
    (root / 'bob.json').write_text(json.dumps(fixture('bob')))

    def invoke(*args, json_output=True, success=True):
        result = subprocess.run([str(binary), *args, *(['--json'] if json_output else [])],
                                env=env, capture_output=True, text=True, timeout=15)
        assert (result.returncode == 0) == success, (args, result.returncode, result.stderr)
        for output in [result.stdout, result.stderr]:
            assert 'access_token' not in output and 'refresh_token' not in output
            assert 'fixture-alice' not in output and 'fixture-bob' not in output
        if not success:
            return result
        return json.loads(result.stdout) if json_output else result.stdout

    assert invoke('list') == []
    current = invoke('current', 'codex')[0]
    assert current['identity']['userID'] == 'alice' and 'savedAccountID' not in current
    assert not (root / 'acc').exists(), 'Discovery must be read-only'
    settings = invoke('settings', '--usage', 'off')
    assert settings['showUsage'] is False
    assert settings['maximumRefreshIntervalSeconds'] == 432000
    assert settings['codexRefreshBeforeExpirySeconds'] == 432000
    assert settings['retryUncertainRefresh'] is False
    preferences = invoke('settings', '--renew-days', '3', '--codex-lead-hours', '48', '--claude-lead-minutes', '30')
    assert preferences['maximumRefreshIntervalSeconds'] == 259200
    assert preferences['codexRefreshBeforeExpirySeconds'] == 172800
    assert preferences['refreshBeforeExpirySeconds'] == 1800
    invoke('settings', '--renew-days', 'invalid', success=False)
    invoke('settings', '--renew-days', 'nan', success=False)
    invoke('settings', '--renew-days', '0', success=False)
    invoke('settings', '--renew-days', '5', '--codex-lead-hours', '120', '--claude-lead-minutes', '10')
    alice = invoke('add', 'codex', '--name', 'Alice')[0]['id']
    assert invoke('add', 'codex')[0]['id'] == alice
    bob = invoke('add', 'codex', '--file', str(root / 'bob.json'), '--name', 'Bob')[0]['id']
    assert next(a for a in invoke('switch', bob) if a['id'] == bob)['isActive']
    invoke('rename', bob, 'Work')
    invoke('switch', alice)
    before = native.read_bytes()
    assert next(a for a in invoke('detach', alice) if a['id'] == alice)['isPaused']
    invoke('maintain')
    assert native.read_bytes() == before
    assert next(a for a in invoke('resume', alice) if a['id'] == alice)['isPaused'] is False
    replacement = root / 'replacement.json'
    replacement.write_text(json.dumps(fixture('alice', 2)))
    invoke('replace', alice, '--file', str(replacement))
    assert json.loads(native.read_text())['tokens']['refresh_token'] == 'fixture-alice-2'
    invoke('replace', alice, '--file', str(root / 'bob.json'), success=False)
    (root / 'bad.json').write_text('not-json')
    invoke('add', 'codex', '--file', str(root / 'bad.json'), success=False)

    # Real process supervision around fake provider executables.
    bin_dir = root / 'bin'
    bin_dir.mkdir()
    provider_cli = bin_dir / 'codex'
    provider_cli.write_text('#!/bin/sh\n/bin/cp "$ACC_LOGIN_FIXTURE" "$CODEX_HOME/auth.json"\n')
    provider_cli.chmod(0o700)
    env['PATH'] = str(bin_dir) + ':' + env.get('PATH', '')
    env['ACC_LOGIN_FIXTURE'] = str(root / 'bob.json')
    invoke('login', 'codex', '--name', 'Work')
    assert json.loads(native.read_text())['tokens']['refresh_token'] == 'fixture-alice-2'
    assert invoke('pending') == []
    invoke('login', 'codex', '--replace', alice, success=False)
    pending = invoke('pending')[0]['id']
    invoke('login-resume', pending, success=False)
    invoke('login-resume', pending, '--as-new')
    assert invoke('pending') == []
    invoke('login', 'codex', '--replace', alice, success=False)
    invoke('login-discard', invoke('pending')[0]['id'])
    assert invoke('pending') == []

    provider_cli.write_text('#!/bin/sh\necho $$ > "$ACC_CHILD_PID_FILE"\nexec /bin/sleep 30\n')
    env['ACC_CHILD_PID_FILE'] = str(root / 'child.pid')
    process = subprocess.Popen([str(binary), 'login', 'codex', '--json'], env=env,
                               stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    deadline = time.monotonic() + 8
    while not (root / 'child.pid').exists() and time.monotonic() < deadline:
        time.sleep(0.05)
    assert (root / 'child.pid').exists(), 'Login child did not start'
    child_pid = int((root / 'child.pid').read_text())
    process.send_signal(signal.SIGINT)
    output, error = process.communicate(timeout=8)
    assert process.returncode == 130, ('login cancellation', process.returncode, output, error)
    try:
        os.kill(child_pid, 0)
        raise AssertionError('Cancelled login left a child process alive')
    except ProcessLookupError:
        pass
    assert list((root / 'acc' / 'signins').iterdir()) == []

    watch = subprocess.Popen([str(binary), 'watch'], env=env, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    time.sleep(0.2)
    watch.terminate()
    output, error = watch.communicate(timeout=5)
    assert watch.returncode == 130, ('watch cancellation', watch.returncode, output, error)
    invoke('refresh', alice, '--unexpected', success=False)
    invoke('switch', 'missing-account', success=False)
    invoke('remove', bob)
    assert len(invoke('list')) == 1
    invoke('signout', 'codex')
    assert not native.exists()
    assert 'identity' not in invoke('current', 'codex')[0]
    assert (root / 'codex' / 'config.toml').read_text() == 'model = "fixture-model"\n'
    assert (root / 'acc' / 'accounts.json').stat().st_mode & 0o777 == 0o600
    assert (root / 'acc').stat().st_mode & 0o777 == 0o700
    assert 'Codex and Claude accounts' in invoke('help', json_output=False)
print('CLI smoke passed: discovery, import, switch, detach/resume, replacement, browser-process login, pending recovery/discard, cancellation, watch shutdown, removal, sign-out, redaction, permissions.')
