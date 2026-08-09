#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"

unsafe_patterns=(
  'arguments.append("--force")'
  'RunCommandAsync("activate", account.Id.ToString(), "--force")'
  'applyArgs.Add("--force")'
  'activate_with_running_policy(account_id, true)'
)

scoped_files=(
  "$root_dir/macos/NextAccount/Sources/NextAccount/AccountStore.swift"
  "$root_dir/windows/CodexRoster.Windows/ViewModels/RosterViewModel.cs"
  "$root_dir/src/tray.rs"
)

for pattern in "${unsafe_patterns[@]}"; do
  if grep -F -n -- "$pattern" "${scoped_files[@]}"; then
    echo "Unsafe forced account switch detected: $pattern" >&2
    exit 1
  fi
done

grep -F -q 'ensure_activation_processes_stopped(&warnings)?;' \
  "$root_dir/src/app/service.rs"

if sed -n '/pub fn begin_add_account_session/,/pub fn save_added_account_session/p' \
  "$root_dir/src/app/service.rs" | grep -F -q 'ensure_activation_processes_stopped'; then
  echo "Login must not be treated as an account switch that requires closing Desktop." >&2
  exit 1
fi

if grep -E -n 'closeDesktopForLoginIfNeeded|loginDesktopRelaunch|_loginRelaunch' \
  "$root_dir/macos/NextAccount/Sources/NextAccount/AccountStore.swift" \
  "$root_dir/windows/CodexRoster.Windows/ViewModels/RosterViewModel.cs"; then
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
