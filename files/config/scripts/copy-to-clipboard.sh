#!/usr/bin/env bash
set -e

buf="$(cat)"

# Local WSL -> Windows clipboard via clip.exe (simplest and most reliable)
if command -v clip.exe >/dev/null 2>&1 && [ -z "${SSH_CLIENT:-}" ] && [ -z "${SSH_TTY:-}" ]; then
  printf "%s" "$buf" | clip.exe
  exit 0
fi

# Fallback: try PowerShell if clip.exe not available
if command -v powershell.exe >/dev/null 2>&1 && [ -z "${SSH_CLIENT:-}" ] && [ -z "${SSH_TTY:-}" ]; then
  # Create a temp file to avoid shell escaping issues
  tmpfile=$(mktemp)
  printf "%s" "$buf" > "$tmpfile"
  powershell.exe -NoProfile -Command "Get-Content -Raw -Encoding UTF8 '$tmpfile' | Set-Clipboard"
  rm -f "$tmpfile"
  exit 0
fi

# Remote -> local clipboard via OSC52 (terminal must support OSC52)
buflen=$(printf "%s" "$buf" | wc -c)
maxlen=74994
if [ "$buflen" -gt "$maxlen" ]; then
  echo "Clipboard: selection too long to copy" >&2
  exit 1
fi

encoded=$(printf "%s" "$buf" | base64 | tr -d '\n')
tty=${SSH_TTY:-$(tmux display-message -p '#{client_tty}' 2>/dev/null || true)}

if [ -n "${tty:-}" ]; then
  printf "\033]52;c;%s\a" "$encoded" > "$tty"
else
  printf "\033]52;c;%s\a" "$encoded"
fi
