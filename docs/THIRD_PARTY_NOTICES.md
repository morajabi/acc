# Third-party notices

Acc's independently structured provider adapters were informed by and adapt protocol details from **CodexBar**, copyright (c) 2026 Peter Steinberger, under the MIT license. The complete license is in [licenses/CodexBar.txt](licenses/CodexBar.txt).

Reference revision: `6480977b47f6e4ffd5dcaae1cb0c7fdf34ee449e`.

Relevant reference files:

- `Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexTokenRefresher.swift`
- `Sources/CodexBarCore/Providers/Codex/CodexOAuth/CodexOAuthUsageFetcher.swift`
- `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthCredentials.swift`
- `Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift`

Codex native Keychain naming was checked against the local OpenAI Codex source at `codex-rs/login/src/auth/storage.rs`. Claude Code's configuration-directory Keychain naming was checked against the published `@anthropic-ai/claude-code` 2.1.0 package. The current upstream Codex revision `ce0323f2f2d3b25e82806cd555237da3db4e1897` was also checked for native storage, default modes, credential shape, and OAuth refresh behavior. Provider implementation source is not vendored in this project.

The ChatGPT and Claude provider marks in `Resources/Providers/` are copied from CodexBar’s `ProviderIcon-codex.svg` and `ProviderIcon-claude.svg`. `Sources/AccMenuBar/ProviderIcon.swift` contains equivalent SwiftUI paths derived from those assets. The CodexBar MIT notice applies to these adaptations. Provider names and marks identify compatible services; Acc is an independent app.

Additional reference mappings: `ClaudeConfigPaths.swift`, `ClaudeScopedWeeklyLimitMapper.swift`, and `ClaudeOAuthUsageFetcher.swift` profile decoding. The UI and account-management architecture are independently implemented.

Noninteractive Keychain handling was also cross-checked against CodexBar’s `KeychainNoUIQuery.swift` and `KeychainSecurity.swift`; Acc serializes and restores the legacy process interaction policy around each query.
