# Credits

Codex Roster is an independent native macOS application built for the Codex community. It is not affiliated with, endorsed by, or reviewed by OpenAI. “Codex”, “ChatGPT”, “OpenAI”, and related marks belong to OpenAI and are used only to describe compatibility.

Except for the original MIT foundation explicitly identified below, Codex Roster does not include source code, visual assets, account data, credentials, or state from the referenced projects.

## Reference audit — 2026-09-22

Synced with the About → References & licenses panel in the macOS app on 2026-09-22.

| Source | Revision reviewed | Role in Codex Roster | License / boundary |
| --- | --- | --- | --- |
| [Pimpmuckl/codex-account-switcher](https://github.com/Pimpmuckl/codex-account-switcher) | `v0.1.10` / `7e27ed0` | Original CLI foundation | MIT |
| [steipete/CodexBar](https://github.com/steipete/CodexBar) | `v0.60.3` / `9db4480` reviewed 2026-09-16 | Menu-bar, quota-state, reset recovery, workspace credit-balance, daily spend estimation, provider usage-schema, and incremental local-history research | MIT; independently reimplemented |
| [jlcodes99/cockpit-tools](https://github.com/jlcodes99/cockpit-tools) | `v1.3.34` / release reviewed 2026-08-31 | High-level product, credential-safety, and account-lifecycle research | CC BY-NC-SA 4.0 as declared in its README; no source/assets copied |
| [Ducksss/codex-profiles](https://github.com/Ducksss/codex-profiles) | `v0.9.1` / `76dfc39` | Profile, workspace, diagnostics, and local-state boundary research | MIT; no source imported |
| [vyctorbrzezowski/codex-switchboard](https://github.com/vyctorbrzezowski/codex-switchboard) | `v1.0.10` / `296c0b3` | Local-first switching, smart-order ranking, and shared-auth safety research | MIT; independently implemented |
| [codex-resets.com](https://codex-resets.com/) | Live `/api/v1/status` · `/api/v1/resets` checked 2026-09-22 | Source of truth for Codex reset commitment, scheduled/latest reset, and public reset events | Public website/API; attribution required (“Data from Codex Resets”); no account data sent |
| [codex-reset.com](https://codex-reset.com/) | Live `/api/forecast` · `/api/timeline` · `/api/juice` · `/api/status-history` checked 2026-09-22 | Codex Reset forecast probabilities (24h/48h), Watch `signal_percent`, timeline, juice, status-history | Public website/API; no source/assets copied and no account data sent |
| [damejan80/tokentab](https://github.com/damejan80/tokentab) | `80358bc` reviewed 2026-09-01 | Local Codex session-log and aggregate-report research | MIT; independently reimplemented |
| [getagentseal/codeburn](https://github.com/getagentseal/codeburn) | `v0.9.24` / `desktop-v0.9.24` reviewed 2026-09-16 | Codex cache-accounting, subagent sidechain handling, cumulative-token fallback, and session-file validation research | MIT; independently reimplemented |
| [vibe-cafe/vibe-usage](https://github.com/vibe-cafe/vibe-usage) | `@vibe-cafe/vibe-usage@0.10.21` reviewed 2026-09-05 | Optional VibeCafe collector/API integration for 7-day tokens, estimated cost, sessions, and active time | MIT; public endpoint/response format integrated independently, no upstream source imported |
| [donvito/agent-monitor](https://github.com/donvito/agent-monitor) | `main` reviewed 2026-09-16 | Codex subagent hierarchy extraction (`thread_source`, `parent_thread_id`) and token USD pricing rate research | MIT; independently reimplemented |

The reviewed updates were applied selectively. Roster preserves the stricter local-first rule from current switching research: it does not refresh inactive accounts' OAuth refresh tokens in the background.

## Agent Monitor

We reviewed [donvito/agent-monitor](https://github.com/donvito/agent-monitor) for local Codex (and other agent) session trees, subagent parent links, and per-model token/USD breakdowns. Codex Roster independently reimplements only the Codex-relevant pieces already present in session metadata (`thread_source`, `parent_thread_id`) and local USD rate estimates. No dashboard UI, traces, or session contents were copied. Agent Monitor is MIT licensed.

## Tokentab and CodeBurn

We reviewed [Tokentab](https://github.com/damejan80/tokentab) and [CodeBurn](https://github.com/getagentseal/codeburn) for local, session-log based token accounting. Codex Roster independently reimplements only the appropriate Codex-specific ideas: incremental session parsing, model/project grouping, archived-session inclusion, cache-read/cache-write accounting, and cumulative usage fallback. No source code, pricing data, UI assets, prompts, or session contents were copied. Both projects are MIT licensed.

## Original foundation

Codex Roster is a product rework of [Pimpmuckl/codex-account-switcher](https://github.com/Pimpmuckl/codex-account-switcher), whose original CLI foundation is licensed under MIT. Its original author is Jonathan Liebig; the upstream project remains credited in [AUTHORS.md](AUTHORS.md).

## CodexBar

We drew UI/UX inspiration from [steipete/CodexBar](https://github.com/steipete/CodexBar): compact provider-centred status surfaces, multi-window quota and reset-time presentation, explicit unavailable states, and a focused menu-bar experience. CodexBar is licensed under MIT; Codex Roster reimplements these ideas in its own SwiftUI and Rust code.

## cockpit-tools

We drew high-level product and UI/UX inspiration from [jlcodes99/cockpit-tools](https://github.com/jlcodes99/cockpit-tools): keeping providers separate, exposing account health alongside quota and reset information, and making quick actions intentional. cockpit-tools is licensed under CC BY-NC-SA 4.0. No cockpit-tools source code or visual assets were copied or incorporated into Codex Roster.

## Codex Profiles and Codex Switchboard

We reviewed [Ducksss/codex-profiles](https://github.com/Ducksss/codex-profiles) for its clear separation between named local profiles, project bindings, diagnostics, and account boundaries. Its decision not to read or copy credentials is an important privacy reference for any future profile-isolation feature. Codex Profiles is MIT licensed.

We also reviewed [vyctorbrzezowski/codex-switchboard](https://github.com/vyctorbrzezowski/codex-switchboard) for its local-first menu-bar focus, account-health indicators, quota ordering, and explicit safety controls around switching. Codex Roster independently implements only the appropriate concepts: visible quota health, clear reset timing, and manual, user-initiated switching. Codex Switchboard is MIT licensed. No source code or assets from either project were incorporated.

## Public Codex reset outlook

Codex Roster consumes the public [Codex Resets](https://codex-resets.com/) API (`/api/v1/status`, `/api/v1/resets`) as the source of truth for commitment / scheduled / latest Codex reset events. Live UI (notch chip, Operations outlook, menu-bar signal) shows that schedule/status only — not 24h/48h or Watch `%` — and credits “Data from [Codex Resets](https://codex-resets.com/)”. [codex-reset.com](https://codex-reset.com/) forecast / timeline / juice endpoints remain available for optional detail surfaces. Requests never include account identifiers, credentials, saved sessions, or quota data. Public reset posts remain advisory; authenticated per-account quota returned by Codex is the final confirmation that a reset or banked credit reached an account.

## VibeCafe usage integration

Codex Roster optionally interoperates with [VibeCafe's `@vibe-cafe/vibe-usage`](https://github.com/vibe-cafe/vibe-usage) collector and its public usage API contract. The integration reads the configured VibeCafe endpoint, requests the official seven-day usage response, and presents aggregate tokens, estimated cost, session count, and active time separately from OpenAI quota and banked-reset credits. The upstream package is MIT licensed; Codex Roster implements the integration independently and does not import `vibe-usage` source code or UI assets.
