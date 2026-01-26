#!/usr/bin/env bash
set -e

CACHE_DIR="${CACHE_DIR:-$HOME/.cache/nuplux}"
CACHE_FILE="$CACHE_DIR/netspeed.txt"
TS_FILE="$CACHE_DIR/netspeed.ts"

TTL_SEC=2

mkdir -p "$CACHE_DIR"
now=$(date +%s)

if [ -f "$CACHE_FILE" ] && [ -f "$TS_FILE" ]; then
  last=$(cat "$TS_FILE" 2>/dev/null || echo 0)
  if [ $((now - last)) -lt "$TTL_SEC" ]; then
    cat "$CACHE_FILE"
    exit 0
  fi
fi

iface=$(ip route 2>/dev/null | awk '/default/ {print $5; exit}')
if [ -z "$iface" ]; then
  out="No net"
  printf "%s" "$out" > "$CACHE_FILE"
  printf "%s" "$now" > "$TS_FILE"
  printf "%s" "$out"
  exit 0
fi

rx1=$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)
tx1=$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)
sleep 1
rx2=$(cat /sys/class/net/"$iface"/statistics/rx_bytes 2>/dev/null || echo 0)
tx2=$(cat /sys/class/net/"$iface"/statistics/tx_bytes 2>/dev/null || echo 0)

rx=$(( (rx2 - rx1) / 1024 ))
tx=$(( (tx2 - tx1) / 1024 ))

out="↓${rx}K ↑${tx}K"
printf "%s" "$out" > "$CACHE_FILE"
printf "%s" "$now" > "$TS_FILE"
printf "%s" "$out"
