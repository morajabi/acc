# Releasing Acc

Every push to `main` is a release. GitHub Actions runs the tests, builds a
universal Apple silicon/Intel app, installs and verifies the signed bundle on
the runner, exercises offline CLI workflows, packages the app, and publishes
**Acc-macOS.dmg**, **Acc-macOS.zip**, and **SHA256SUMS.txt**. Pushes that change only docs,
Markdown, or the license do not release, and neither do commits marked
`[skip ci]`. Pull requests run CI without releasing.

## Push

```sh
scripts/push.sh
```

The script requires a clean, up-to-date `main`, runs `swift test` and
`scripts/build-app.sh` (which installs `/Applications/Acc.app`), pushes, then
follows the Release run and prints the release URL.

## Versions

Releases take the next patch after the newest `v*` tag. To start a new minor
or major line, raise `AccVersion.current` in `Sources/AccCore/Version.swift`;
the next release uses that version when it is higher. `scripts/build-app.sh`
stamps the bundle from that file, and the workflow stamps it with the assigned
version before building, so the app, CLI, tag, and asset always agree. Check
what the next push will publish with `python3 scripts/next-version.py`.

Releases run one at a time. A failed run publishes nothing and creates no tag,
so the next push retries the same version. A public release is never
overwritten.

To review a release before it goes public, choose **Actions → Release → Run
workflow** with **draft** selected, or:

```sh
gh workflow run release.yml -F draft=true
```

Publish the draft from GitHub when it looks right.

## Automatic updates

The app updates itself with [Sparkle](https://sparkle-project.org). Each release
attaches **appcast.xml**, signed with the project's EdDSA key, and the app reads
it from `releases/latest/download/appcast.xml` every six hours. Updates download
and install automatically by default; **Settings → General → Updates** turns that
off, and **Check for Updates…** is in the app menu and the popover's gear menu.

The public key is `SUPublicEDKey` in `Resources/Info.plist`. The private key lives
in the maintainer's login Keychain (account `acc`) and in the
`SPARKLE_PRIVATE_KEY` Actions secret; releases fail without it. To restore the
secret from the Keychain:

```sh
.build/artifacts/sparkle/Sparkle/bin/generate_keys --account acc -x sparkle-key
gh secret set SPARKLE_PRIVATE_KEY < sparkle-key && rm sparkle-key
```

Losing the private key means installed copies can no longer verify updates, so
keep the Keychain item backed up. Never commit it.

## Signing and notarization

Without signing secrets, CI uses an **ad-hoc signature**. It verifies the bundle's
integrity but does not identify a trusted developer. Such releases are **not
notarized**, and their download notes explain the native macOS **Open Anyway**
step. Do not describe these builds as Developer ID signed or notarized.

For automated Developer ID signing, the repository owner can configure these
GitHub Actions secrets:

| Secret | Value |
| --- | --- |
| `ACC_CERTIFICATE_P12` | Base64-encoded Developer ID Application certificate and private key, exported by its owner |
| `ACC_CERTIFICATE_PASSWORD` | Password protecting that export |

For notarization, also configure all three:

| Secret | Value |
| --- | --- |
| `ACC_APPLE_ID` | Apple developer account email |
| `ACC_APPLE_APP_PASSWORD` | App-specific password for that account |
| `ACC_APPLE_TEAM_ID` | Developer team ID |

Partial configuration fails the release instead of silently downgrading it.
Secrets are used only by the Release workflow on `main`, never in pull requests.
The workflow imports signing material into a temporary keychain, enables hardened
runtime and secure timestamps, submits with `notarytool`, staples the accepted
ticket, and checks Gatekeeper acceptance before publishing. The keychain and
certificate export are deleted even after failure. Never commit certificate
exports or place secret values in workflow files or issue comments.

The workflow does not export or upload a developer's local signing keys. To keep
signing local, download a universal CI build, sign the app with an existing
Developer ID identity, and run `package-release.sh` with an existing
`ACC_NOTARY_PROFILE` (and optional `ACC_NOTARY_KEYCHAIN`). This packages and
notarizes the already-built app without compiling. Upload the resulting archive
and checksum to a draft release before publication.

Apple requires Developer ID signing and notarization for the normal downloaded
app experience. See [Apple's notarization workflow](https://developer.apple.com/documentation/security/customizing-the-notarization-workflow)
and [GitHub's release management](https://docs.github.com/en/repositories/releasing-projects-on-github/managing-releases-in-a-repository).

## Verify the published download

Download the release assets, then run from their directory:

```sh
shasum -a 256 -c SHA256SUMS.txt
ditto -x -k Acc-macOS.zip unpacked
codesign --verify --deep --strict unpacked/Acc.app
lipo unpacked/Acc.app/Contents/MacOS/AccMenuBar -verify_arch arm64
lipo unpacked/Acc.app/Contents/MacOS/AccMenuBar -verify_arch x86_64
```

For a notarized release, also run `xcrun stapler validate unpacked/Acc.app` and
`spctl --assess --type execute unpacked/Acc.app`. Check the actual published
asset, not just the build directory. Keep provider sign-in and cancellation,
Keychain approval, login registration, and running-client adoption as separate
interactive checks in the [verification matrix](VERIFICATION.md).
