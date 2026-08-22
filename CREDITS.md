# Credits

Codex Roster is an independent native macOS application built for the Codex community. It is not affiliated with, endorsed by, or reviewed by OpenAI. “Codex”, “ChatGPT”, “OpenAI”, and related marks belong to OpenAI and are used only to describe compatibility.

Except for the original MIT foundation explicitly identified below, Codex Roster does not include source code, visual assets, account data, credentials, or state from the referenced projects.

## Reference audit — 2026-08-22

| Source | Revision reviewed | Role in Codex Roster | License / boundary |
| --- | --- | --- | --- |
| [Pimpmuckl/codex-account-switcher](https://github.com/Pimpmuckl/codex-account-switcher) | `v0.1.10` / `7e27ed0` | Original CLI foundation | MIT |
| [steipete/CodexBar](https://github.com/steipete/CodexBar) | `main` / `27c7f33` (0.54.1 changelog; latest published release checked: 0.54.0) | Menu-bar, quota-state, and reset-time UX research | MIT; independently reimplemented |
| [jlcodes99/cockpit-tools](https://github.com/jlcodes99/cockpit-tools) | `v1.3.24` / `34d8701` | High-level product and UI/UX research | CC BY-NC-SA 4.0 as declared in its README; no source/assets copied |
| [Ducksss/codex-profiles](https://github.com/Ducksss/codex-profiles) | `main` / `e8ca967` (package 0.8.0) | Profile, workspace, and local-state boundary research | MIT; no source imported |
| [vyctorbrzezowski/codex-switchboard](https://github.com/vyctorbrzezowski/codex-switchboard) | `v1.0.10` / `296c0b3` | Local-first switching and shared-auth safety research | MIT; independently implemented |
| [duolahypercho/codex-router](https://github.com/duolahypercho/codex-router) | `v0.4.0-beta.4` / `2376def` | Automated lifecycle through its documented CLI and verified official installer | MIT; separate installation and state |

The reviewed updates were applied selectively. Roster follows Router's documented status, provider-selection, guided-setup, and maintenance command boundaries and preserves the stricter local-first rule from current switching research: it does not refresh inactive accounts' OAuth refresh tokens in the background. Roster now coordinates provider visibility in its macOS UI, while Router-owned credentials, routing, catalog curation, provider spend, and provider quota remain outside Roster's data model.

## Original foundation

Codex Roster is a product rework of [Pimpmuckl/codex-account-switcher](https://github.com/Pimpmuckl/codex-account-switcher), whose original CLI foundation is licensed under MIT. Its original author is Jonathan Liebig; the upstream project remains credited in [AUTHORS.md](AUTHORS.md).

## CodexBar

We drew UI/UX inspiration from [steipete/CodexBar](https://github.com/steipete/CodexBar): compact provider-centred status surfaces, multi-window quota and reset-time presentation, explicit unavailable states, and a focused menu-bar experience. CodexBar is licensed under MIT; Codex Roster reimplements these ideas in its own SwiftUI and Rust code.

## cockpit-tools

We drew high-level product and UI/UX inspiration from [jlcodes99/cockpit-tools](https://github.com/jlcodes99/cockpit-tools): keeping providers separate, exposing account health alongside quota and reset information, and making quick actions intentional. cockpit-tools is licensed under CC BY-NC-SA 4.0. No cockpit-tools source code or visual assets were copied or incorporated into Codex Roster.

## Codex Profiles and Codex Switchboard

We reviewed [Ducksss/codex-profiles](https://github.com/Ducksss/codex-profiles) for its clear separation between named local profiles, project bindings, diagnostics, and account boundaries. Its decision not to read or copy credentials is an important privacy reference for any future profile-isolation feature. Codex Profiles is MIT licensed.

We also reviewed [vyctorbrzezowski/codex-switchboard](https://github.com/vyctorbrzezowski/codex-switchboard) for its local-first menu-bar focus, account-health indicators, quota ordering, and explicit safety controls around switching. Codex Roster independently implements only the appropriate concepts: visible quota health, clear reset timing, and manual, user-initiated switching. Codex Switchboard is MIT licensed. No source code or assets from either project were incorporated.

## Codex Router

Codex Roster integrates with [duolahypercho/codex-router](https://github.com/duolahypercho/codex-router) through its documented command-line boundary. On macOS, Roster may download the official `v0.4.0-beta.4` installer and executes it only after verifying the pinned SHA-256 checksum. Roster automates dependency preparation, native-only setup, service repair, status checks, maintenance updates, and provider visibility. Its in-app provider picker delegates credential entry and OAuth to Router's guided secure flow, preserves already-enabled providers and native GPT, and never reads provider secrets. Codex Router remains the source of truth for external models, provider credentials, routing policy, and curated catalogs. No Codex Router source code, visual assets, secrets, or state files are incorporated into Roster. Codex Router is MIT licensed.

## Public reset signal source

Codex Roster reads the public profile of [Tibo / @thsottiaux on X](https://x.com/thsottiaux) directly and classifies reset, scheduled-reset, and banked-reset wording locally. It does not send account identifiers, credentials, saved sessions, or quota data to X. Public posts remain advisory; authenticated per-account quota returned by Codex is the final confirmation that a reset or banked credit reached an account.
