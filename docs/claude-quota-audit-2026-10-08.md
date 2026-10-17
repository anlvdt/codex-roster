# Claude live quota audit — 2026-10-08

## Findings and changes

The macOS monitor previously refreshed every five minutes and the CLI retained OAuth snapshots for fifteen minutes, including the active account. On this machine the local statusline bridge was not connected. This combination explains quota that appears static during a Claude Code session.

The monitor now reads the local feed every ten seconds while the Claude tab or notch is enabled. `providers refresh-usage claude --local-only` cannot invoke quota HTTP requests or token refresh. The regular API check runs every minute, refreshing an active account after two minutes and inactive accounts after fifteen minutes. Local observation runs independently of OAuth requests and auto-switch work. Manual refresh continues to respect HTTP 429 cooldowns.

The existing **Connect CLI quota** button in the quota guide installs the bridge, backs up settings, and forwards an existing statusline. Start a new Claude Code process after connecting. Quota becomes available after an API response; idle redraws do not create new observations. There is no supported subscription push stream, so “live” means reading new Claude Code observations shortly after a response, with bounded OAuth polling as fallback. No synthetic prompts are sent.

When OAuth has supplied model caps, newer local aggregate percentages are displayed alongside those caps. The combined view is marked stale and retains the model-cap check timestamp; it is never persisted as fully verified switching evidence. An older local observation does not replace a newer OAuth snapshot. Missing, expired, or differently bound local observations are ignored.

The OAuth parser also now reads `limits[]` weekly model scopes, including generic model names, and prioritizes them over legacy fields. Invalid/duplicate applicable caps fail conservatively; surface-specific limits are excluded. Rust selection and Swift utilization both include generic model caps. `Retry-After` accepts integer seconds and HTTP dates with the existing bounded fallback.

## Primary research

- [Official Claude Code statusline documentation](https://code.claude.com/docs/en/statusline): optional `rate_limits`, response-triggered evidence, and statusline configuration. Aggregate windows cannot independently prove model-specific headroom.
- [CodexBar scoped weekly mapper](https://github.com/steipete/CodexBar/blob/844b0e19bbbbc5d8739b7344b22abec667cfbbc9/Sources/CodexBarCore/Providers/Claude/ClaudeScopedWeeklyLimitMapper.swift) and [OAuth fetcher](https://github.com/steipete/CodexBar/blob/844b0e19bbbbc5d8739b7344b22abec667cfbbc9/Sources/CodexBarCore/Providers/Claude/ClaudeOAuth/ClaudeOAuthUsageFetcher.swift): generic scoped limits and HTTP-date retry handling. Inspected commit `844b0e19bbbbc5d8739b7344b22abec667cfbbc9`, MIT.
- [cc-switch subscription parser](https://github.com/farion1231/cc-switch/blob/c5233fe7efad220fbeba5004da8713c615ee5266/src-tauri/src/services/subscription.rs): observed weekly-scoped schema and exclusion of surface limits. Inspected commit `c5233fe7efad220fbeba5004da8713c615ee5266`, MIT.
- [HTTP Retry-After specification](https://www.rfc-editor.org/rfc/rfc9110.html#section-10.2.3).

These implementations provide observational evidence for the private OAuth endpoint, not an official API contract. Implementation here is independently written; no upstream code was copied.

## Deferred finding

The saved-account cooldown gate does not cover unsaved live identities or direct adapter callers. Moving that gate to request identity with cross-process serialization requires a separate change. The new fast local polling path does not use those request paths. Normal saved-account polling retains the existing cooldown gate.
