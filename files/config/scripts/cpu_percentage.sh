#!/usr/bin/env bash
set -euo pipefail

# Prints: CPU:19%[icon]
# Also supports:
#   --icon     -> [icon]
#   --percent  -> 19%
#   --raw      -> 19
#
# Customize via env:
#   CPU_LOW_PCT=20 CPU_HIGH_PCT=80
#   CPU_LOW_ICON="=" CPU_MED_ICON="≡" CPU_HIGH_ICON="≣"

state="/tmp/tmux_cpu_prev_${USER}"

LOW_PCT="${CPU_LOW_PCT:-20}"
HIGH_PCT="${CPU_HIGH_PCT:-80}"

LOW_ICON="${CPU_LOW_ICON:-=}"
MED_ICON="${CPU_MED_ICON:-≡}"
HIGH_ICON="${CPU_HIGH_ICON:-≣}"

read -r _ user nice system idle iowait irq softirq steal _ _ < /proc/stat

idle_all=$((idle + iowait))
total=$((user + nice + system + idle + iowait + irq + softirq + steal))

if [[ -f "$state" ]]; then
  read -r prev_total prev_idle < "$state" || true
else
  prev_total=0
  prev_idle=0
fi

echo "$total $idle_all" > "$state"

dt=$((total - prev_total))
di=$((idle_all - prev_idle))

if (( dt <= 0 )); then
  usage=0
else
  usage=$(( (100 * (dt - di)) / dt ))
  (( usage < 0 )) && usage=0
  (( usage > 100 )) && usage=100
fi

if (( usage < LOW_PCT )); then
  icon="$LOW_ICON"
elif (( usage >= HIGH_PCT )); then
  icon="$HIGH_ICON"
else
  icon="$MED_ICON"
fi

case "${1:-}" in
  --icon)    printf "%s" "$icon" ;;
  --percent) printf "%d%%" "$usage" ;;
  --raw)     printf "%d" "$usage" ;;
  *)         printf "%d%%[%s]" "$usage" "$icon" ;;
esac
