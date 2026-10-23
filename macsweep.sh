#!/usr/bin/env bash
# macsweep — a free, original Mac cleanup tool. No dependencies, no decompiling.
# Reclaims disk by clearing regenerable caches/logs/trash and reporting big/old files.
# SAFE BY DEFAULT: scans and reports only. Pass --clean to actually delete.
set -euo pipefail

CLEAN=0
ASSUME_YES=0
for arg in "$@"; do
  case "$arg" in
    --clean) CLEAN=1 ;;
    --yes|-y) ASSUME_YES=1 ;;
    -h|--help)
      echo "usage: macsweep.sh [--clean] [--yes]"
      echo "  (no args)  scan + report sizes only (safe)"
      echo "  --clean    actually delete the junk categories"
      echo "  --yes      skip the confirmation prompt (with --clean)"
      exit 0 ;;
    *) echo "unknown arg: $arg (try --help)" >&2; exit 2 ;;
  esac
done

human() { du -sh "$1" 2>/dev/null | head -1 | cut -f1 || true; }
bytes() { local k; k=$(du -sk "$1" 2>/dev/null | head -1 | awk '{print $1}') || true; echo "${k:-0}"; }  # KB

# Junk categories: only *contents* of these dirs are removed, never the dir itself,
# and never anything outside $HOME. All of these regenerate automatically.
TARGETS=(
  "User app caches|$HOME/Library/Caches"
  "User logs|$HOME/Library/Logs"
  "Crash reports|$HOME/Library/Application Support/CrashReporter"
  "Saved app state|$HOME/Library/Saved Application State"
  "Trash|$HOME/.Trash"
  "Xcode DerivedData|$HOME/Library/Developer/Xcode/DerivedData"
  "Xcode device logs|$HOME/Library/Developer/Xcode/iOS DeviceSupport"
  "npm cache|$HOME/.npm/_cacache"
  "yarn cache|$HOME/Library/Caches/Yarn"
)

echo "=== macsweep scan ==="
total_kb=0
present=()
for entry in "${TARGETS[@]}"; do
  label="${entry%%|*}"; path="${entry#*|}"
  [ -d "$path" ] || continue
  kb=$(bytes "$path"); total_kb=$((total_kb + kb))
  printf "%-22s %8s  %s\n" "$label" "$(human "$path")" "$path"
  present+=("$entry")
done
printf "%-22s %8s\n" "RECLAIMABLE TOTAL" "$(echo "$total_kb" | awk '{printf "%.1fG", $1/1024/1024}')"

echo
echo "=== 15 largest files under \$HOME (report only, nothing deleted) ==="
find "$HOME" -type f -size +100M 2>/dev/null \
  | xargs -I{} du -h "{}" 2>/dev/null | sort -rh | head -15 || true

echo
echo "=== Downloads older than 90 days (report only) ==="
find "$HOME/Downloads" -maxdepth 1 -mtime +90 2>/dev/null \
  | sed "s|$HOME/|~/|" | head -30 || true

if [ "$CLEAN" -eq 0 ]; then
  echo
  echo "Scan only. Re-run with --clean to delete the junk categories above."
  exit 0
fi

echo
echo "About to empty the contents of ${#present[@]} junk categories above."
if [ "$ASSUME_YES" -eq 0 ]; then
  read -r -p "Proceed? [y/N] " ans
  [[ "$ans" =~ ^[Yy]$ ]] || { echo "aborted."; exit 0; }
fi

for entry in "${present[@]}"; do
  label="${entry%%|*}"; path="${entry#*|}"
  # guard: must be a real dir inside $HOME
  case "$path" in "$HOME"/*) : ;; *) echo "skip (outside HOME): $path"; continue ;; esac
  # delete contents only, tolerate files in use
  find "$path" -mindepth 1 -maxdepth 1 -exec rm -rf {} + 2>/dev/null || true
  echo "cleared: $label"
done
echo "done. Some caches rebuild on next app launch — that's normal."
