# Credits

Codex Roster is an independent native macOS application. It does not include code, assets, account data, or credentials from the projects below.

## Original foundation

Codex Roster is a product rework of [Pimpmuckl/codex-account-switcher](https://github.com/Pimpmuckl/codex-account-switcher), whose original CLI foundation is licensed under MIT. Its original author is Jonathan Liebig; the upstream project remains credited in [AUTHORS.md](AUTHORS.md).

## CodexBar

We drew UI/UX inspiration from [steipete/CodexBar](https://github.com/steipete/CodexBar): compact provider-centred status surfaces, multi-window quota and reset-time presentation, explicit unavailable states, and a focused menu-bar experience. CodexBar is licensed under MIT; Codex Roster reimplements these ideas in its own SwiftUI and Rust code.

## cockpit-tools

We drew high-level product and UI/UX inspiration from [jlcodes99/cockpit-tools](https://github.com/jlcodes99/cockpit-tools): keeping providers separate, exposing account health alongside quota and reset information, and making quick actions intentional. cockpit-tools is licensed under CC BY-NC-SA 4.0. No cockpit-tools source code or visual assets were copied or incorporated into Codex Roster.

## Codex Profiles and Codex Switchboard

We reviewed [Ducksss/codex-profiles](https://github.com/Ducksss/codex-profiles) for its clear separation between named local profiles, project bindings, diagnostics, and account boundaries. Its decision not to read or copy credentials is an important privacy reference for any future profile-isolation feature.

We also reviewed [vyctorbrzezowski/codex-switchboard](https://github.com/vyctorbrzezowski/codex-switchboard) for its local-first menu-bar focus, account-health indicators, quota ordering, and explicit safety controls around switching. Codex Roster independently implements only the appropriate concepts: visible quota health, clear reset timing, and manual, user-initiated switching. No source code or assets from either project were incorporated.
