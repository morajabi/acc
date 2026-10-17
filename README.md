# Acc

Keep your **Codex and Claude Code accounts fresh**, see remaining usage, and switch between them from the macOS menu bar.

Acc checks saved accounts in the background, renews their authentication before expiry, and shows when it last renewed and when it will try next. It also works as a regular Mac window and a command-line tool, backed by an independent Swift core.

<p align="center">
  <img src="docs/images/accounts.png" width="410" alt="Acc with synthetic Personal and Work accounts, remaining usage, and renewal dates">
</p>

## What it does

- Recognizes the current local Codex and Claude Code subscription.
- Adds accounts through browser sign-in, the current login, or an imported credential file.
- Switches accounts, renews credentials, signs in again, replaces, renames, detaches, or removes saved accounts.
- Shows remaining 5-hour and weekly usage when the provider supplies those windows.
- Keeps authentication fresh independently of usage polling, with configurable renewal timing.
- Shows access-token expiry, next renewal, recent attempts, and failures that need attention.
- Opens at login by default, subject to macOS approval. Respects an explicit opt-out.
- Offers a resizable menu panel, a regular window with native toolbar and keyboard shortcuts, and separate Settings.

**Switching updates the provider's local login.** Restart an already-running provider client to ensure it loads the selected account. Acc does not restart clients or interrupt conversations. Claude desktop and web sessions are separate from Claude Code and are not switched.

## Build and run

Requires **macOS 14+** and **Swift 6.2+**. Install Xcode or the matching command-line tools, then:

```sh
git clone https://github.com/morajabi/acc.git
cd acc
swift test
./scripts/build-app.sh
open /Applications/Acc.app
```

Every app build installs the complete signed bundle to `/Applications/Acc.app`. Quit and reopen Acc after rebuilding. The script uses the single available Developer ID identity, or ad-hoc signing if none or several are available. Set `ACC_SIGN_IDENTITY` to choose an identity explicitly (`-` selects ad-hoc signing). A stable signing identity helps preserve Keychain access across builds. These local builds are not notarized.

Choose **Settings → General → Show Acc in → Window and Dock** for window mode, or quit and launch with:

```sh
open /Applications/Acc.app --args --window
```

Closing the Accounts window keeps background maintenance running. Quit stops it. The saved presentation preference is used on the next ordinary launch; `--window` overrides it for that launch.

## Add and manage accounts

Open **+ → Sign In with Browser…** to add another account without switching your current login. Install the corresponding [Codex](https://github.com/openai/codex) or [Claude Code](https://code.claude.com/docs/en/overview) CLI first; Acc also detects the CLI bundled with the Codex app. The provider handles browser consent in an isolated configuration directory. A completed login that cannot be imported remains available to resume without repeating consent.

Alternatively, choose **Save Account** on the detected current login or **+ → Import from File…**. For a protected Keychain item, choose **Allow Keychain Access** and approve the macOS prompt. Background checks never open permission dialogs.

Each account's **…** menu contains its management actions:

| Action | Effect |
| --- | --- |
| Switch | Use this login in the selected provider and resume its management |
| Renew Now | Request new credentials and save the result |
| Sign In Again / Replace from File | Replace this saved login while retaining its name and identity |
| Detach from Acc | Keep the saved copy and native login; pause Acc's automatic updates |
| Remove from Acc | Forget Acc's saved copy; leave the provider signed in |
| Sign Out Locally | Save the outgoing login, then clear the provider's local credentials |

The regular window supports **⌘N** for browser sign-in, **⌘O** for import, **⌘R** to check accounts, **⌘1 / ⌘2** for providers, and **⌘,** for Settings.

## Keeping authentication fresh

Defaults are the earlier of **five days since renewal** or **five days before Codex access-token expiry**. Claude renews **ten minutes before expiry**, with the same five-day maximum age. Short-lived Codex tokens renew halfway through their lifetime. Settings exposes these intervals and the handling of unavailable native stores and unknown renewal outcomes.

Acc checks every minute, on wake and reconnect, and with a macOS background activity. It must be running to do this. Sleep, power-off, provider revocation, and provider availability remain outside its control. Launch-at-login status is shown in Settings, including any approval needed.

**An old refresh token is not a backup after rotation.** Acc durably records returned credentials before publishing them to the native provider store. If a response is lost, the server may have consumed the old token without Acc receiving the new one. Acc records that uncertainty and pauses automatic replay by default. See [authentication and recovery](docs/AUTHENTICATION.md) for the full behavior, including migrating from Auth Guard.

**The account store is local, private, and unencrypted.** OAuth secrets are stored in `~/Library/Application Support/Acc/accounts.json` with owner-only permissions. Never share this file. Account summaries and CLI JSON omit credentials. There is no telemetry. See [security](SECURITY.md).

## CLI and core

```sh
./dist/acc list
./dist/acc login codex --name Personal
./dist/acc switch Personal
./dist/acc refresh Personal --force
./dist/acc detach Personal
./dist/acc watch
```

[CLI reference](docs/CLI.md) covers all commands, storage overrides, JSON output, and isolated testing.

`AccCore` contains credential parsing, renewal, persistence, provider adapters, and account management. It imports no SwiftUI or AppKit and has no third-party package dependencies. HTTP and native credential stores are injectable. The app and CLI use the same `AccountService`.

## Development and verification

```sh
swift test
./scripts/build-app.sh
python3 scripts/smoke-test.py
./scripts/preview-app.sh
```

Preview opens a separate app with synthetic accounts and no credential access, network calls, or login registration. It supports switching, renaming, detaching, removing, and resetting preview accounts. [Contributing](CONTRIBUTING.md) describes layout renders and development conventions.

The [verification matrix](docs/VERIFICATION.md) distinguishes automated fixtures, live provider checks, and remaining interactive acceptance. Provider integration endpoints can change; absent usage windows are shown as unavailable rather than invented.

## License and acknowledgements

[MIT](LICENSE). Provider protocol details and marks were adapted from [CodexBar](https://github.com/steipete/CodexBar), with its license retained in [third-party notices](docs/THIRD_PARTY_NOTICES.md). OpenAI's [Codex source](https://github.com/openai/codex) and prior Codex Auth Guard work informed storage and renewal behavior. Acc's app icon is original vector artwork.

Acc is an independent app and is not affiliated with OpenAI or Anthropic. Provider names and marks identify compatible services.
