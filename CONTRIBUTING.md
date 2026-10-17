# Contributing

Acc is a macOS app, a CLI, and an independent Swift core. Use macOS 14 or later
and Swift 6.2 or later. There are no third-party package dependencies.

```sh
swift test
./scripts/build-app.sh
python3 scripts/smoke-test.py
./scripts/preview-app.sh
```

The build installs `/Applications/Acc.app`. Quit and reopen that copy to use the
new version. Preview launches a separate app with synthetic accounts and no
credential access, networking, or login-item registration. Preview account
changes are in memory; Help → Reset Preview Accounts restores the fixtures.

Build incrementally and only when code changes need verification. The app build
defaults to two jobs to reduce local load; set `ACC_BUILD_JOBS=1` for the lowest
concurrency. Prefer CI for repeat full builds and avoid running `swift test` and
`swift build` concurrently against the same checkout.

For layout checks in both appearances:

```sh
./dist/Acc.app/Contents/MacOS/AccMenuBar --render-previews /tmp/acc-previews
```

Keep credential parsing, renewal, persistence, and provider integration in
`AccCore`. The app and CLI should call the same service. Use injectable HTTP and
native storage interfaces, temporary directories, and synthetic credentials in
tests. Never run a live token exchange just to test a patch.

Changes to renewal must preserve successful rotations before native publication,
distinguish a definite preconnection failure from an unknown outcome, and keep
usage retries independent of renewal deadlines. A consumed refresh token is not
recoverable from an old file. See [authentication](docs/AUTHENTICATION.md) and
[verification](docs/VERIFICATION.md).

Use native controls, standard menus and shortcuts, accessible labels, semantic
colors, and layouts that work at the minimum window height. Check both light and
dark appearance and empty, pending, paused, stale, and sign-in-required states.

Keep pull requests focused and describe the behavior changed and checks run.
Do not attach real auth files, raw HTTP responses, account exports, or screenshots
of private accounts. See [security reporting](SECURITY.md) for sensitive issues.
