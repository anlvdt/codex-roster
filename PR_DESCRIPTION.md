Claude account management is now available in the macOS console and notch, with saved-account labels, deletion, usage refresh, auto-switch controls, and continuation of recently rate-limited sessions. This change also fixes credential races and recovery failures that could restore stale tokens, lose saved credentials, or overwrite a concurrent manual account switch.

Changes:
- Add the Claude roster UI, background monitoring, notch navigation, and supporting provider CLI commands.
- Serialize refresh and activation under the auth lock, reload snapshots after waiting, and recheck the active account before auto-switch refresh/apply.
- Preserve original Codex auth files during failed restores and retain recovery backups when rollback fails; block force activation for interactive Codex CLI processes.
- Create Claude credential/config files with private permissions and remove stale complementary credential storage when switching.
- Recover provider indexes during replacement, persist deletion metadata before deleting secrets, and avoid quarantining accounts for expired access-token responses.
- Include external-provider snapshots and labels in encrypted manual and automatic backups, with validation and propagated errors.
- Price daily token usage with each event's model, fix POSIX apostrophe quoting in the updater, and update the auth-switch safety check.

Validation:
- 66 selected Rust regression tests passed; all 9 auto-switch tests passed again after the final ordering adjustment.
- `cargo check --offline`, `cargo test --offline --no-run`, and `cargo clippy --offline --all-targets -- -D warnings` passed.
- `cargo fmt --check`, `git diff --check`, and `scripts/check-auth-switch-safety.sh` passed.
- Swift updater/language typechecking and 5 shell-quoting round-trip fixtures passed.
- GitNexus change analysis confirmed the affected flows are within credential switching, provider persistence, backups, usage accounting, and the related UI. It reports CRITICAL risk due to the breadth of shared auth and persistence code.

Validation limits: the complete Rust test suite and full SwiftPM application build were not run. Tests that can touch real provider credentials, Keychain, or live OAuth were excluded; full SwiftPM validation was constrained by sandbox writes. Runtime validation of the full Claude UI and session continuation remains for macOS review.

🤖 Generated with [Claude Code](https://claude.com/claude-code)
