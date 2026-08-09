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

echo "Auth switch safety checks passed."
