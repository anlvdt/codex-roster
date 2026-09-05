# Credits

Codex Roster is an independent native macOS application built for the Codex community. It is not affiliated with, endorsed by, or reviewed by OpenAI. “Codex”, “ChatGPT”, “OpenAI”, and related marks belong to OpenAI and are used only to describe compatibility.

Except for the original MIT foundation explicitly identified below, Codex Roster does not include source code, visual assets, account data, credentials, or state from the referenced projects.

## Reference audit — 2026-09-01

| Source | Revision reviewed | Role in Codex Roster | License / boundary |
| --- | --- | --- | --- |
| [Pimpmuckl/codex-account-switcher](https://github.com/Pimpmuckl/codex-account-switcher) | `v0.1.10` / `7e27ed0` | Original CLI foundation | MIT |
| [steipete/CodexBar](https://github.com/steipete/CodexBar) | `v0.56.1` / release reviewed 2026-08-31 | Menu-bar, quota-state, reset recovery, activity detection, and incremental local-history research | MIT; independently reimplemented |
| [jlcodes99/cockpit-tools](https://github.com/jlcodes99/cockpit-tools) | `v1.3.34` / release reviewed 2026-08-31 | High-level product, credential-safety, and account-lifecycle research | CC BY-NC-SA 4.0 as declared in its README; no source/assets copied |
| [Ducksss/codex-profiles](https://github.com/Ducksss/codex-profiles) | `v0.9.1` / `76dfc39` | Profile, workspace, diagnostics, and local-state boundary research | MIT; no source imported |
| [vyctorbrzezowski/codex-switchboard](https://github.com/vyctorbrzezowski/codex-switchboard) | `v1.0.10` / `296c0b3` | Local-first switching and shared-auth safety research | MIT; independently implemented |
| [codex-reset.com](https://codex-reset.com/) | Live `/api/feed` schema v1 checked 2026-08-31 | Public Tibo-post normalization research for long X posts that X truncates | Public website/API; no source/assets copied and no account data sent |
| [damejan80/tokentab](https://github.com/damejan80/tokentab) | `80358bc` reviewed 2026-09-01 | Local Codex session-log and aggregate-report research | MIT; independently reimplemented |
| [getagentseal/codeburn](https://github.com/getagentseal/codeburn) | `f4e9ece` reviewed 2026-09-01 | Codex cache-accounting, cumulative-token fallback, and session-file validation research | MIT; independently reimplemented |
| [vibe-cafe/vibe-usage](https://github.com/vibe-cafe/vibe-usage) | `@vibe-cafe/vibe-usage@0.10.21` reviewed 2026-09-05 | Optional VibeCafe collector/API integration for 7-day tokens, estimated cost, sessions, and active time | MIT; public endpoint/response format integrated independently, no upstream source imported |

The reviewed updates were applied selectively. Roster preserves the stricter local-first rule from current switching research: it does not refresh inactive accounts' OAuth refresh tokens in the background.

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

## Public reset signal source

Codex Roster reads [Tibo / @thsottiaux on X](https://x.com/thsottiaux) and uses the independent [Codex Reset radar](https://codex-reset.com/) as a public-text normalization source when X truncates a long post. Classification remains local to Roster. Requests to either source do not include account identifiers, credentials, saved sessions, or quota data. Public posts remain advisory; authenticated per-account quota returned by Codex is the final confirmation that a reset or banked credit reached an account.

## VibeCafe usage integration

Codex Roster optionally interoperates with [VibeCafe's `@vibe-cafe/vibe-usage`](https://github.com/vibe-cafe/vibe-usage) collector and its public usage API contract. The integration reads the configured VibeCafe endpoint, requests the official seven-day usage response, and presents aggregate tokens, estimated cost, session count, and active time separately from OpenAI quota and banked-reset credits. The upstream package is MIT licensed; Codex Roster implements the integration independently and does not import `vibe-usage` source code or UI assets.
