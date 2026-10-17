# Security

Report vulnerabilities through [GitHub private vulnerability reporting](https://github.com/morajabi/acc/security/advisories/new).
Do not post credentials or authentication documents in public issues. Describe
the affected version, expected behavior, reproduction using synthetic data, and
impact. Include only redacted diagnostics.

## Storage and trust

Acc stores OAuth credentials in a **local, unencrypted JSON file** under
`~/Library/Application Support/Acc/`. The directory is restricted to its owner
(`0700`), files use `0600`, and writes are atomic. This protects against ordinary
cross-user access; it does not protect against software running as your user,
administrators, disk access, or copies made by backup software. Native provider
storage may also use the macOS Keychain.

Account-list output excludes tokens. The app has no telemetry or remote logging.
OAuth and usage requests go to the corresponding provider. Browser sign-in runs
the locally installed provider CLI in an isolated configuration directory.

Successful rotations are saved before publication to native stores. Unknown
outcomes pause automatic replay by default. These mechanisms reduce local data
loss; they cannot undo a provider rotation, restore a revoked token, or coordinate
an exchange made simultaneously by a separate provider client. Do not run two
credential keepers against the same token lineage.

See [authentication behavior](docs/AUTHENTICATION.md) for the recovery model and
[verification](docs/VERIFICATION.md) for coverage and limits.
