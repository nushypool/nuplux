#!/usr/bin/env bash
set -euo pipefail

# Prints: RAM:47%[icon]
# Also supports:
#   --icon     -> [icon]
#   --percent  -> 47%
#   --raw      -> 47
#
# Customize via env:
#   RAM_LOW_PCT=40 RAM_HIGH_PCT=85
#   RAM_LOW_ICON="▁" RAM_MED_ICON="▅" RAM_HIGH_ICON="█"

LOW_PCT="${RAM_LOW_PCT:-40}"
HIGH_PCT="${RAM_HIGH_PCT:-85}"

LOW_ICON="${RAM_LOW_ICON:-=}"
MED_ICON="${RAM_MED_ICON:-≡}"
HIGH_ICON="${RAM_HIGH_ICON:-≣}"

used=$(
  awk '
  /^MemTotal:/ {t=$2}
  /^MemAvailable:/ {a=$2}
  END {
    if (t>0) {
      u=(t-a)*100/t
      printf "%.0f", u
    } else {
      printf "0"
    }
  }' /proc/meminfo
)

# clamp
if [[ -z "${used:-}" ]]; then used=0; fi
if (( used < 0 )); then used=0; fi
if (( used > 100 )); then used=100; fi

if (( used < LOW_PCT )); then
  icon="$LOW_ICON"
elif (( used >= HIGH_PCT )); then
  icon="$HIGH_ICON"
else
  icon="$MED_ICON"
fi

case "${1:-}" in
  --icon)    printf "%s" "$icon" ;;
  --percent) printf "%d%%" "$used" ;;
  --raw)     printf "%d" "$used" ;;
  *)         printf "%d%%[%s]" "$used" "$icon" ;;
esac
