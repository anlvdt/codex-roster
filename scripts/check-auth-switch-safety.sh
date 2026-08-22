#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"

# macOS centralizes its two allowed force flags: the activation helper and the
# auto-switch apply path after Desktop was confirmed closed. Any extra literal
# is an unsafe ad-hoc bypass and must fail CI.
macos_force_count="$(grep -R -F -h -- '--force' \
  "$root_dir/macos/NextAccount/Sources/NextAccount" | wc -l | tr -d ' ')"
if [[ "$macos_force_count" -ne 2 ]]; then
  echo "Expected exactly two guarded macOS --force append sites; found $macos_force_count." >&2
  exit 1
fi

activation_arguments_block="$(sed -n \
  '/enum AccountActivationSafety/,/enum NewAccountLoginState/p' \
  "$root_dir/macos/NextAccount/Sources/NextAccount/AccountStore.swift")"
if ! grep -F -q 'if forceDesktop {' <<<"$activation_arguments_block" \
  || ! grep -F -q 'arguments.append("--force")' <<<"$activation_arguments_block"; then
  echo "The centralized macOS activation helper lost its forceDesktop guard." >&2
  exit 1
fi

auto_switch_block="$(sed -n \
  '/private func checkAutoSwitchWhenExhausted/,/private func reloadAccountsAfterSwitch/p' \
  "$root_dir/macos/NextAccount/Sources/NextAccount/AccountStore.swift")"
if ! grep -F -q 'if didCloseDesktop {' <<<"$auto_switch_block" \
  || ! grep -F -q 'applyArguments.append("--force")' <<<"$auto_switch_block"; then
  echo "The macOS auto-switch force flag must remain guarded by didCloseDesktop." >&2
  exit 1
fi

grep -F -q 'ensure_activation_processes_stopped(&warnings)?;' \
  "$root_dir/src/app/service.rs"

if sed -n '/pub fn begin_add_account_session/,/pub fn save_added_account_session/p' \
  "$root_dir/src/app/service.rs" | grep -F -q 'ensure_activation_processes_stopped'; then
  echo "Login must not be treated as an account switch that requires closing Desktop." >&2
  exit 1
fi

if grep -E -n 'closeDesktopForLoginIfNeeded|loginDesktopRelaunch|_loginRelaunch' \
  "$root_dir/macos/NextAccount/Sources/NextAccount/AccountStore.swift"; then
  echo "Desktop close/relaunch lifecycle detected in an add/re-login flow." >&2
  exit 1
fi

activation_block="$(sed -n \
  '/fn activate_with_expected_active/,/fn refresh_current_saved_account_before_activation/p' \
  "$root_dir/src/app/service.rs")"

for invariant in \
  'let _auth_lock = AuthLock::acquire' \
  'self.refresh_current_saved_account_before_activation()?' \
  'self.load_activation_target(account_id)?' \
  'restore_snapshot_with_retry'
do
  if ! grep -F -q "$invariant" <<<"$activation_block"; then
    echo "Activation refresh safety invariant missing: $invariant" >&2
    exit 1
  fi
done

if grep -F -q 'refresh_snapshot_if_access_token_stale(&snapshot)' <<<"$activation_block"; then
  echo "Activation must leave OAuth refresh-token ownership to official Codex." >&2
  exit 1
fi

if grep -F -A 2 'UsageSource::SavedAccessToken,' \
  "$root_dir/src/app/service.rs" | grep -F -q 'true'; then
  echo "Unsafe background refresh-token rotation detected for a saved account." >&2
  exit 1
fi

grep -F -q '"auth_changed": app.add_account_session_auth_changed()?' \
  "$root_dir/src/cli.rs"

if grep -F -n 'Command::new("codex")' \
  "$root_dir/src/app/auto_start.rs"; then
  echo "Unsafe background Codex login detected for inactive accounts." >&2
  exit 1
fi

echo "Auth switch safety checks passed."
