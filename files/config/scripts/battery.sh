#!/usr/bin/env bash
for b in /sys/class/power_supply/BAT*; do
  [ -d "$b" ] || continue
  cap=$(cat "$b/capacity" 2>/dev/null || echo "")
  stat=$(cat "$b/status" 2>/dev/null || echo "")
  [ -n "$cap" ] || continue
  icon="🔋"
  [ "$stat" = "Charging" ] && icon="⚡"
  echo "${icon}${cap}%"
  exit 0
done
exit 0
