# Verification

Checked on 2026-10-17. This matrix distinguishes compatibility evidence from execution evidence. Automated checks use synthetic credentials, temporary provider homes, mock HTTP responses, and a mock Keychain. They do not send inference requests, sign in to real accounts, or rotate the user's credentials.

## Reference sources

- [CodexBar at `6480977`](https://github.com/steipete/CodexBar/tree/6480977b47f6e4ffd5dcaae1cb0c7fdf34ee449e): Codex/Claude OAuth requests, native credential shapes, usage windows, scoped weekly mapping, profile decoding, and provider marks.
- [Current upstream Codex at `ce0323f`](https://github.com/openai/codex/tree/ce0323f2f2d3b25e82806cd555237da3db4e1897): `codex-rs/login/src/auth/storage.rs`, `manager.rs`, `token_data.rs`, and `codex-rs/config/src/types.rs`.
- Prior Codex Auth Guard work: refresh response merging, durable private writes, and isolated browser login. Its execution acknowledgements and process-name blocking were not adopted.
- [Claude Code authentication documentation](https://code.claude.com/docs/en/authentication): Keychain/file fallback and configuration-directory scoping.
- [Claude Code CLI reference](https://code.claude.com/docs/en/cli-reference): `claude auth login`, logout, and status.
- Published `@anthropic-ai/claude-code` **2.1.0**: configuration-directory hash, Keychain service/account naming, and Keychain-to-file fallback. This older package is a pinned implementation reference, not a claim about the installed CLI version. Newer separate credential-directory behavior was checked against CodexBar.

Codex requests use the public OAuth client ID and JSON refresh body used by Codex itself. CodexBar also supplies an optional scope field; Acc follows Codex's request shape. Claude refresh uses form encoding and its public client ID. Usage uses bearer authentication, Codex's workspace header, and Claude's OAuth beta header. Acc does not implement browser-cookie scraping, dashboard automation, or CodexBar's unrelated providers/cost features.

## Workflow matrix

| Path | Implemented behavior | Verification |
| --- | --- | --- |
| First launch / current login | Detect both native subscriptions without saving credentials or refreshing tokens; show unsaved active login and optional usage | Core discovery/no-write tests; real CLI smoke discovery; rendered empty/active states |
| Add current login | Save the native OAuth credential, deduplicate by user and workspace, keep active login | Core tests and CLI smoke |
| Import file | Parse native Codex/Claude JSON, identify Claude when local identity is absent, reject unsupported auth modes | Parser/profile/identity tests; CLI import and invalid-file paths |
| Browser sign-in | Run the provider CLI in isolated config/credential directories with inherited auth overrides removed | Fake Codex and Claude subprocess tests; CLI smoke; official CLI arguments checked |
| Cancel / timeout | Cancel owned subprocess, wait for exit, remove its isolated store; CLI handles SIGINT/SIGTERM | Task-cancellation, accelerated-timeout, and CLI signal/child-cleanup tests; real installed Codex/Claude cancellation with unchanged native credentials |
| Complete a deferred sign-in | Persist recovery metadata before launching the provider; hide running attempts; resume, add as new, or discard after interruption | Busy-store, wrong-identity, interrupted-intent, storage-failure, cancellation, resume/discard tests and CLI smoke |
| Switch | Capture outgoing unsaved OAuth login; renew target if due; publish target without changing provider settings/history | Core switching/expiry/external-switch tests; CLI smoke |
| Renew | Explicit force renewal, automatic expiry renewal, bounded 401 recovery, retained optional token fields | Mock HTTP/lifecycle tests; live Codex and Claude renewals with accepted subsequent usage requests |
| Replace / reauthenticate | Preserve saved record ID/name; require same identity; update active native login if applicable | Replacement, identity-mismatch, failed-publication recovery tests; CLI smoke |
| Detach / resume | Keep provider login intact, pause all automatic work for that saved record; normal provider login/logout remains available | Core detach/resume/external-login tests; CLI smoke; rendered detached state |
| Remove | Forget only Acc's saved copy | Core removal/no-recapture tests and CLI smoke |
| Sign out locally | Preserve outgoing saved account, clear native credentials and Claude account metadata, preserve unrelated settings | Core/native-store tests and CLI smoke |
| Remaining usage | 5-hour/weekly windows when present; reset times; stale cache; additional/scoped model limits | Fixture parsers, rate-limit/401/server-error tests, reset-boundary and foreground scheduling regressions; live usage updates |
| Usage disabled | No automatic usage calls; renewal remains independent | Settings and maintenance tests |
| Keep-fresh disabled / detached | No automatic rotation; detached records skip both polling and renewal | Offline/paused tests |
| Concurrent Acc processes | File lock prevents overlapping refreshes; cancelled work releases ownership | Process-lock and overlap tests; CLI cancellation smoke |
| External provider changes | Reconcile new native tokens before renewal and before retry gates; preserve an external switch during refresh | Reconciliation/backoff/CAS tests |
| Failed native publication | Save a successful rotation first; retry publication without another rotation, including partial multi-store writes | Lifecycle tests |
| Native UI | Provider tabs/marks, active usage, alternate switch actions, menus, pending login actions, settings window | Compiled shipping views; light/dark renders of active, Claude, unsaved current, empty, error, Keychain-needed, detached, pending, signing-in, and settings states |
| Launch at login | Request registration by default on first launch through `SMAppService`; show actual status and required approval | Installed app toggled off/on; macOS registration and Login Items UI verified; enabled after relaunch |
| Regular window mode | `--window` opens Accounts with Dock presence and no status item; `--demo` supplies synthetic accounts | Live normal window, native zoom/restore, close/reopen, continued process after closing, and demo accounts verified |

## Native storage matrix

| Source | Handling |
| --- | --- |
| Codex default / `file` | `$CODEX_HOME/auth.json`, defaulting to `$HOME/.codex/auth.json`; default verified in Codex source |
| Codex `keyring` | `Codex Auth` service, `cli\|` plus first 16 hex characters of SHA-256 of canonical home path; strict Keychain error propagation |
| Codex `auto` | Keychain first, then file fallback; successful Keychain publication removes stale fallback; a known active Keychain item cannot be silently replaced only in the file |
| Claude Keychain | `Claude Code-credentials`, or a suffix from the first eight SHA-256 hex characters of the NFC-normalized credential-directory override; `CLAUDE_SECURESTORAGE_CONFIG_DIR` takes precedence over `CLAUDE_CONFIG_DIR`; account uses `USER` or OS username |
| Claude file fallback | `.credentials.json` in the selected credential directory; readable fallback supported when Keychain is locked |
| Claude metadata | Existing `<config>/.config.json` takes precedence, then custom `<config>/.claude.json`, then `$HOME/.claude.json`; preserve unrelated settings and same-account metadata |
| Separate Claude credential directory | `CLAUDE_SECURESTORAGE_CONFIG_DIR`; isolated browser login sets it alongside `CLAUDE_CONFIG_DIR` |
| Unsupported modes | Explicitly reject Codex external-token, API-key, PAT, and agent-identity auth as managed ChatGPT OAuth; ephemeral modes are not written |
| Vault integrity | Private permissions, atomic same-directory replacement, symlink rejection at write targets, corrupt vaults reported rather than treated as empty |

Native storage behavior is exercised against temporary files and an injected Keychain. App account lists, CLI JSON, errors, and diagnostic descriptions contain no tokens. The private account store does contain OAuth secrets and is not encrypted.

## Automated checks

The v0.2 series uses 104 Swift tests, the offline CLI smoke suite, a release build,
bundle signature verification, and plist validation. The CLI suite exercises
real subprocess supervision with fake provider CLIs, signal cancellation, pending
login recovery, and shutdown. Static renders cover 28 layouts across light and
dark appearances, including short and tall panels, a regular window, empty,
paused, pending, uncertain, and sign-in-needed states.
Static renders check layout; README screenshots capture the actual native
popover with synthetic accounts, including its system material and active controls.

Compilation and tests run in GitHub Actions. The downloaded artifact can be
installed and checked locally without compiling:

```sh
codesign --verify --deep --strict /Applications/Acc.app
plutil -lint /Applications/Acc.app/Contents/Info.plist
./dist/Acc.app/Contents/MacOS/AccMenuBar --render-previews /tmp/acc-previews
./scripts/preview-app.sh
```

## Live checks on 2026-10-17

The installed v0.1.1 app and shared core were exercised with owner-authorized
accounts. Private account identities, credentials, and machine-specific evidence
are not included in this repository.

- An inactive Codex account completed one renewal, advanced its expiry, and
  accepted a subsequent usage request.
- An active Codex account completed one renewal; the saved and native credential
  copies matched afterward, active identity stayed unchanged, and usage succeeded.
- An active Claude account completed one renewal through the app; native
  publication completed and a subsequent usage request succeeded. User-approved
  Keychain access survived the next signed build and relaunch. The CLI has its own
  Keychain authorization decision.
- Open at login was toggled off and on in the installed app. The macOS record and
  Login Items UI reflected the changes; registration stayed enabled after relaunch.
- The live panel was dragged from 580 to 754 points, then to its 360-point minimum.
  The footer remained anchored and the last account remained reachable by scrolling.
  Accessible size adjustments worked, and a 600-point height survived relaunch.
- Regular window mode showed a Dock icon and standard window controls. Native
  zoom/restore worked. Closing the window kept maintenance running, and reopening
  restored the Accounts window.

The v0.1.2 interface pass additionally checks native toolbar/menu commands,
keyboard provider selection, Settings, and switch/rename/detach/resume using
synthetic preview accounts. Switching between menu-bar and window presentation
from Settings opened and hid the expected window without a restart. The installed
v0.1.2 app showed live usage and renewal deadlines for both providers after
relaunch, with Open at login enabled. The interface follows Apple's guidance for
[macOS](https://developer.apple.com/design/human-interface-guidelines/designing-for-macos),
[toolbars](https://developer.apple.com/design/human-interface-guidelines/toolbars),
[menus](https://developer.apple.com/design/human-interface-guidelines/menus), and
[Settings](https://developer.apple.com/design/human-interface-guidelines/settings).

The v0.2.0 CI artifact was installed in Applications with the owner's existing
Developer ID identity. Native SwiftUI Settings opened through Command–Comma and
the popover's Settings menu, including reopening an existing Settings window.
Window/menu-bar presentation changes worked. The native popover's accessible
height controls resized its content while keeping the footer visible. The
installed app retained enabled launch-at-login registration and showed the
migrated one-hour Claude renewal lead. Live usage changed after background
polling without rotating native credentials.

The public [v0.2.1 release](https://github.com/morajabi/acc/releases/tag/v0.2.1)
passed all 104 tests, offline CLI workflows, and universal bundle checks in
[GitHub Actions](https://github.com/morajabi/acc/actions/runs/39054794686).
Its downloaded ZIP was 1,948,705 bytes and matched both the published SHA-256
checksum and GitHub's asset digest. The extracted app verified as version
0.2.1 (7), with arm64 and x86_64 slices targeting macOS 14. The public bundle
is ad-hoc signed and unnotarized. That downloaded app was signed locally with
the owner's existing identity, installed in Applications, and relaunched in
window mode. Both providers showed current usage; native Settings confirmed
launch at login remained enabled and Claude's one-hour renewal lead was retained.

Real cancellation checks used **Codex 0.162.0-alpha.13** and **Claude Code
2.1.292**. Each CLI ran under a separate test vault and temporary provider homes;
neither test used the installed app's saved account store. Cancelling Acc returned
exit status 130, stopped the owned provider process, removed the pending sign-in
directory, and saved no account. Initial runs left native credential/configuration
file hashes and Claude Keychain metadata unchanged. Both cancellation paths passed
again with the final v0.2 core, including removal of the prewritten recovery intent.
Native file modification times predated those final attempts; the Claude Keychain
entry remained unchanged. The OpenAI browser sign-in page was observed; completed
browser consent for either provider remains separate evidence.

An intervening native Codex token update was adopted by Acc without another Acc
renewal attempt. The saved credential and tracked native fingerprint matched;
pending-publication and refresh-in-flight flags were clear. The exact external
writer was not identified.

## Limits of this evidence

- Actual browser consent with both installed provider CLIs and switching two real
  subscriptions followed by provider-client restart remain interactive acceptance
  checks. Fake CLI tests do not prove browser consent or running-client adoption.
- A real macOS logout/reboot was not performed. Registration evidence does not
  prove launch after every OS update or login configuration.
- Native window zoom and the previous panel's dragging were verified. The new
  native popover's accessible resize controls work; direct dragging currently
  encounters a computer-control window-targeting error. Corner dragging of the
  standard window also remains unverified through that tool.
- Tests do not prove months of unattended operation or recoverability after a
  provider returns new tokens but its response is lost. Unknown outcomes pause
  replay by default. Old credentials cannot undo a consumed refresh token.
- Provider clients do not honor Acc's process lock. Reconciliation and conditional
  native writes reduce races but cannot eliminate simultaneous external renewal.
- API keys, external or ephemeral credentials, custom endpoints, managed policies,
  and Claude desktop/web sessions are outside the OAuth account-switching scope.

Generated verification artifacts stay under ignored `dist/verification/`.
Screenshots committed to this repository contain only synthetic display data.
