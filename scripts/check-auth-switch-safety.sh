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

if grep -F -n 'refresh_snapshot_if_access_token_stale(&snapshot)' \
  "$root_dir/src/app/service.rs"; then
  echo "Unsafe inactive snapshot refresh detected during activation." >&2
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
