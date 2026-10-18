#!/usr/bin/env bash
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"

# Codex activation has two guarded force sites: manual activation and
# auto-switch after Desktop was confirmed closed. Count the argument appends
# only: user-facing guidance text may legitimately mention --force.
macos_force_count="$(grep -R -F -h -- 'append("--force")' \
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

# prove_saved_session_refresh exchanges single-use RTs. It may live only in
# src/usage.rs (definition + unit tests), plus exactly one call site: the
# explicit `dead-accounts --deep` check. That path is user-invoked, skips the
# live account, and persists the rotated snapshot immediately; every other call
# site (and any background sweep) is still a footgun.
while IFS= read -r match; do
  file="${match%%:*}"
  case "$file" in
    "$root_dir/src/usage.rs"|"$root_dir/src/app/service.rs") continue ;;
    *)
      echo "prove_saved_session_refresh must stay confined to src/usage.rs; found: $match" >&2
      exit 1
      ;;
  esac
done < <(grep -R -n -F --include='*.rs' 'prove_saved_session_refresh(' "$root_dir/src" || true)

service_file="$root_dir/src/app/service.rs"
service_calls=$(grep -c -F 'prove_saved_session_refresh(' "$service_file" || true)
deep_calls=$(awk '/fn deep_check_inactive_accounts/,/^    \}$/' "$service_file" \
  | grep -c -F 'prove_saved_session_refresh(' || true)
if [[ "$service_calls" != "1" || "$deep_calls" != "1" ]]; then
  echo "prove_saved_session_refresh may only be called from deep_check_inactive_accounts (found $service_calls call(s) in service.rs, $deep_calls inside the deep-check function)." >&2
  exit 1
fi

# The deep check must be reachable only when the caller asked for it.
deep_invocations=$(grep -c -F 'self.deep_check_inactive_accounts()' "$service_file" || true)
if [[ "$deep_invocations" != "1" ]]; then
  echo "deep_check_inactive_accounts must have exactly one call site (found $deep_invocations)." >&2
  exit 1
fi
if ! grep -B 3 -F 'self.deep_check_inactive_accounts()' "$service_file" | grep -F -q 'if deep {'; then
  echo "deep_check_inactive_accounts must be gated behind `if deep {` so it never runs in a background path." >&2
  exit 1
fi

if grep -F -A 2 'UsageSource::SavedAccessToken,' \
  "$root_dir/src/app/service.rs" | grep -F -q 'true'; then
  echo "Unsafe background refresh-token rotation detected for a saved account." >&2
  exit 1
fi

# `add-account-status` must keep reporting whether the login changed the live
# credentials; the exact expression may move, the reported field may not.
if ! grep -F -q '"auth_changed": auth_changed,' "$root_dir/src/cli.rs" \
  || ! grep -F -q 'app.add_account_session_auth_changed()?' "$root_dir/src/cli.rs"; then
  echo "add-account-status must report auth_changed from add_account_session_auth_changed()." >&2
  exit 1
fi

if grep -F -n 'Command::new("codex")' \
  "$root_dir/src/app/auto_start.rs"; then
  echo "Unsafe background Codex login detected for inactive accounts." >&2
  exit 1
fi

echo "Auth switch safety checks passed."
