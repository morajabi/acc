# Command-line interface

```sh
./dist/acc login codex --name Personal
./dist/acc login claude --name Work
./dist/acc add codex                         # save the currently signed-in login
./dist/acc add codex --file /path/to/auth.json
./dist/acc list --json
./dist/acc authorize claude                  # explicitly allow Keychain access if needed
./dist/acc current --json                    # detect native logins without saving them
./dist/acc current codex --usage              # read usage without rotating tokens
./dist/acc switch Personal
./dist/acc usage Personal
./dist/acc refresh Personal                  # refresh if due, then fetch enabled usage
./dist/acc refresh Personal --force          # explicitly rotate now
./dist/acc login codex --replace Personal    # reauthenticate the same identity
./dist/acc replace Personal --file /path/to/new-auth.json
./dist/acc detach Personal                   # leave provider signed in; pause Acc updates
./dist/acc resume Personal                   # resume automatic management
./dist/acc pending --json                    # completed logins awaiting import
./dist/acc login-resume <pending-id>          # retry without another browser login
./dist/acc login-resume <pending-id> --as-new # retain a different account as a new entry
./dist/acc login-discard <pending-id>
./dist/acc rename Personal 'Personal Plus'
./dist/acc remove Work                       # forget saved copy; leave active login intact
./dist/acc signout claude                    # save, then clear local active credentials
./dist/acc settings --usage off
./dist/acc settings --keep-fresh on
./dist/acc maintain                          # one maintenance pass
./dist/acc watch                             # maintenance every minute until stopped
```

Account arguments accept a unique name, UUID, or UUID prefix. `--store <directory>` or `ACC_HOME` changes Acc's storage directory. `CODEX_HOME` and `CLAUDE_CONFIG_DIR` select provider homes. `CLAUDE_SECURESTORAGE_CONFIG_DIR` can separately select Claude’s credential-file directory. Empty overrides use defaults; `HOME` is honored. Changing only `--store` does **not** isolate the provider homes; tests and demo runs set all of them.
