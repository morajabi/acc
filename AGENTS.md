# Acc

Keep the account lifecycle in `AccCore`. The app and CLI are thin consumers of that library. Prefer native macOS controls, concise account flows, and accessible layouts.

- Prefer straightforward Swift and small injectable interfaces. No third-party dependencies are currently needed.
- Automatic refresh is normal behavior; do not add auth-guard's double acknowledgements or process-name blocking.
- Preserve native unknown fields and unrelated settings. Save successful token rotations before publishing to native stores.
- Never print credentials, raw auth documents, HTTP authorization headers, or provider error bodies.
- Use synthetic credentials and temporary provider homes in tests; do not use real accounts to validate a change unless asked.
- Run `swift test` and `scripts/build-app.sh` for changes affecting the app/core.
- Every app build must install the complete signed bundle in `/Applications/Acc.app`; `scripts/build-app.sh` does this automatically. Relaunch from that path for live verification.
- Live provider login, native Keychain access, and running-client adoption are separate acceptance checks; do not claim them from fixture tests.
