#!/usr/bin/env bash
# Reclaim disk space from local build artifacts. Dry-run by default; pass
# --apply to delete. Never touches source, target/, git history, or the current
# build/CodexRoster.app bundle.
set -euo pipefail

root_dir="$(cd "$(dirname "$0")/.." && pwd)"
build_dir="$root_dir/build"
apply=0
[[ "${1:-}" == "--apply" ]] && apply=1

if [[ ! -d "$build_dir" ]]; then
  echo "No build directory at $build_dir"
  exit 0
fi

mapfile_compat() { while IFS= read -r line; do printf '%s\n' "$line"; done; }

targets=()
# Old packaged zips and stale app bundles from previous builds.
while IFS= read -r path; do
  targets+=("$path")
done < <(find "$build_dir" -maxdepth 1 -type f \( -name '*.zip' \) -print)

while IFS= read -r path; do
  targets+=("$path")
done < <(find "$build_dir" -maxdepth 1 -type d \( -name 'AgentDock*' -o -name 'Codex Roster.backup-*' -o -name 'CodexRoster.backup-*' \) -print)

if [[ ${#targets[@]} -eq 0 ]]; then
  echo "Nothing to clean."
  exit 0
fi

echo "Candidates:"
for path in "${targets[@]}"; do
  size=$(du -sh "$path" 2>/dev/null | cut -f1)
  echo "  $size  ${path#$root_dir/}"
done

if [[ "$apply" -ne 1 ]]; then
  echo
  echo "Dry run. Re-run with --apply to delete the entries above."
  exit 0
fi

for path in "${targets[@]}"; do
  rm -rf -- "$path"
done
echo "Removed ${#targets[@]} entries."
