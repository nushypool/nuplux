#!/usr/bin/env bash
set -e

CACHE_DIR="${CACHE_DIR:-$HOME/.cache/nuplux}"
CACHE_FILE="$CACHE_DIR/apt-updates.count"
TS_FILE="$CACHE_DIR/apt-updates.ts"

TTL_MIN=10
TTL_SEC=$((TTL_MIN * 60))

mkdir -p "$CACHE_DIR"
now=$(date +%s)

if [ -f "$CACHE_FILE" ] && [ -f "$TS_FILE" ]; then
  last=$(cat "$TS_FILE" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt "$TTL_SEC" ]; then
    cat "$CACHE_FILE"
    exit 0
  fi
fi

count="0"
if [ -x /usr/lib/update-notifier/apt-check ]; then
  out=$(/usr/lib/update-notifier/apt-check 2>/dev/null || true)   # "<updates>;<security>"
  n="${out%%;*}"
  n="${n//[^0-9]/}"
  count="${n:-0}"
elif command -v apt >/dev/null 2>&1; then
  count="$(LC_ALL=C apt list --upgradable 2>/dev/null | awk 'NR>1{c++} END{print c+0}')"
fi

printf "%s" "$count" > "$CACHE_FILE"
printf "%s" "$now" > "$TS_FILE"
printf "%s" "$count"
