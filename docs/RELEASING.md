# Releasing Acc

GitHub Actions performs all compilation. The release workflow runs the tests,
builds a universal Apple silicon/Intel app, installs and verifies the signed
bundle on the runner, exercises offline CLI workflows, and packages the app.
Public assets are **Acc-macOS.zip** and **SHA256SUMS.txt**.

## Publish a version

1. Update the version in `Resources/Info.plist`, the CLI, and `AppVersion`'s
   fallback. Increment `CFBundleVersion`.
2. Merge the reviewed changes to `main` and verify CI. Download the CI artifact
   for interactive acceptance; use synthetic accounts for screenshots.
3. Create and push the matching tag, for example:

   ```sh
   git tag v0.2.0
   git push origin v0.2.0
   ```

The **Release** workflow publishes only after all its checks pass. It creates a
draft first, attaches the app and checksum, then makes the release public. The tag
must match the app version. A public release is never overwritten; use a new
version for a fix.

To retry a failed release, choose **Actions → Release → Run workflow**, enter the
existing tag, and leave **draft** selected to review it before publishing. The
same operation is available through the CLI:

```sh
gh workflow run release.yml -f tag=v0.2.0 -F draft=true
```

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
Secrets are used only on the tag/manual release path, never in pull requests.
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
lipo -verify_arch arm64 x86_64 unpacked/Acc.app/Contents/MacOS/AccMenuBar
```

For a notarized release, also run `xcrun stapler validate unpacked/Acc.app` and
`spctl --assess --type execute unpacked/Acc.app`. Check the actual published
asset, not just the build directory. Keep provider sign-in and cancellation,
Keychain approval, login registration, and running-client adoption as separate
interactive checks in the [verification matrix](VERIFICATION.md).
