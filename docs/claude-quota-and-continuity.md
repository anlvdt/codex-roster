# Claude quota and account continuity

Research checked against official Claude documentation on 2026-10-02.

## Quota and reset

- A Claude Desktop login alone does not sign the default Terminal CLI in. Run `claude auth status`; if `loggedIn` is false, run `claude auth login` with the desired account, then save that CLI account in Roster and refresh. A config-only identity is reported as `needs_auth`, with no usable quota. The local statusline feed requires an interactive CLI; Desktop background sessions do not supply it.
- Explicit `CLAUDE_CONFIG_DIR` scopes both credentials paths and the Claude Keychain service (SHA-256 directory suffix). The adapter reads and restores within that scope. It does not silently select another scoped account when the default CLI is signed out. Default statusline identity prefers `~/.claude.json`; explicit scopes prefer `<config-dir>/.claude.json`.

- Claude Code's documented `statusLine` input includes `rate_limits.five_hour` and `rate_limits.seven_day`, each with `used_percentage` and `resets_at` in Unix seconds. These are usage limits, separate from `context_window.used_percentage`.
- The fields are optional, plan/version dependent, and appear only after an API response. A missing field is unknown, never zero consumption. The CLI removes expired windows. The bridge requires both aggregate windows, rejects expired/invalid values, rounds consumption up, and expires evidence after two minutes. Idle redraws do not renew freshness.
- The app uses the returned timestamp, displays the local clock and date, and never assumes midnight or automatically restores 100% after the timer passes.
- The existing OAuth usage endpoint remains a fallback, with HTTP 429 backoff persisted independently of local quota updates. It is not a documented public subscription API. The documented statusline source avoids repeated usage requests while evidence is fresh. Model-specific limits are available only from that fallback; the local aggregate feed does not expose them. When a saved record has known model-specific limits, the app keeps the API path instead of replacing those caps with aggregate-only evidence.
- `claude-quota-bridge --install` connects the local feed. Existing statusline commands are forwarded the original stdin and their stdout is preserved. Settings are backed up. The bridge persists only email/account ID, observation time and quota windows, never OAuth tokens or transcript contents. Session IDs keep their first account binding so an old CLI cannot attribute its data to a newly selected account. Restart the CLI after connecting or switching.

## Switching without losing saved context

- Add account now launches the official `claude auth login --claudeai` browser flow from the app, with optional `--email`. A private temporary config directory isolates enrollment from the current CLI login. The app validates `loggedIn`, subscription authentication and the selected email, imports the encrypted snapshot, and removes the temporary directory/Keychain entry. Cancel and a ten-minute timeout terminate the login process. Repeat Add another account to enroll more logins. Existing saved accounts remain available; use Switch to activate one.
- Saving an identity without OAuth credentials is rejected. Desktop switching is opt-in by default. The notch holds open while Claude dialogs or sheets are presented, and lets those dialogs handle Escape, avoiding disabled confirmation buttons when the parent collapses.

- CLI transcripts are local and separate from account credentials. The existing switch path changes authentication, not `~/.claude/projects`.
- Open a fresh process in the original working directory with the exact session ID and `--resume --fork-session`. The fork retains the saved history and leaves the original conversation intact. Before launch, the app verifies `claude auth status` reports `loggedIn: true` and the selected email, and refuses credential/provider/gateway environment overrides.
- Automatic continuation requires a recent final main-session quota error; manual switching resumes without sending an unsolicited continuation prompt. Desktop login is separate from CLI login and retains the existing Desktop enrollment/verification flow.
- Resume restores stored conversation history and tool results. It cannot restore a tool that was still running, background processes, or every custom `--settings`, `--mcp-config`, `--plugin-dir`, `--add-dir` flag. Those may need to be restored by the user. Context compaction and expired prompt caches are separate from authentication; do not promise identical in-memory state or zero token cost after switching.

## Primary sources

- [Statusline schema, availability, reset semantics](https://code.claude.com/docs/en/statusline)
- [Session restoration and limitations](https://code.claude.com/docs/en/sessions)
- [Resume and fork flags](https://code.claude.com/docs/en/cli-reference)
- [Authentication](https://code.claude.com/docs/en/authentication)
- [Usage versus conversation length, shared account limits](https://support.claude.com/en/articles/11647753-how-do-usage-and-length-limits-work)

## Codex native paused queue (installed Desktop inspected 2026-10-02)

Desktop distinguishes queued acceptance from execution. Its interrupted queue shows
“Queue paused because you interrupted”; Resume is absent when `canSendNow` is false,
and the native coordinator checks pending turn starts before releasing the queue.
Queue waits for the current response; Steer affects the current turn
([OpenAI documentation](https://developers.openai.com/blog/mastering-codex-remote-for-engineering)).

Roster marks new continue messages with the exact thread ID and reads the native
`queued-follow-ups` state without modifying it. It reuses a sole marked message,
leaves user/legacy/mixed queues untouched, and stops retries on ambiguous CLI outcomes.
Only a unique enabled native Resume in the foreground focused thread can be pressed,
with matching marker, paused header, no Stop and no composer draft. Missing accessibility,
unknown queue schema, another language, another foreground window, pending/running turns,
and unrelated queues remain under native control: use Resume manually if paused.
AXPress success means the request was delivered, not that a turn started. There are
no Enter or screen-coordinate fallbacks. Native queue storage is an implementation
detail, so unknown formats fail closed. Batch navigation/cancellation and existing
usage-limit/manual-stop detection remain in place.

### Preventing unsolicited continue messages

A Roster relaunch is not a recovery trigger. Startup probes require the persisted
pending quota-recovery flag and a usable active account. Rollout `task_started`
means active/unknown interruption, so it never authorizes a continuation. Only an
explicit recent usage-limit error qualifies; a later start, successful completion
or manual abort supersedes that error. Before queueing, Roster performs another
read-only discovery and checks the exact thread is still eligible. Bare mid-flight
cuts without a quota error require manual continuation. This also rejects old
pending captures from earlier app versions.

## Live refresh behavior

The app reads connected local quota every ten seconds while the Claude tab or notch is enabled. OAuth fallback checks run every minute and refresh the active account after two minutes; inactive accounts retain fifteen-minute caching. New local aggregates can be displayed with older model caps, but that combined view stays unverified and does not renew model freshness. See the [2026-10-08 audit](claude-quota-audit-2026-10-08.md) for findings, source research, and limits.
