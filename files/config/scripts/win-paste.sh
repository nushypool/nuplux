#!/usr/bin/env bash
set -e
# Paste from Windows/System clipboard.
# UTF-8 safe (fixes Cyrillic in WSL<->PowerShell).
# Only removes CR (carriage return), keeps newlines intact.

if command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command "\
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); \
    \$t = Get-Clipboard -Raw; \
    if (\$null -ne \$t) { [Console]::Out.Write(\$t) }" \
  | tr -d '\r'
  exit 0
fi

if command -v xclip >/dev/null 2>&1; then
  xclip -selection clipboard -o 2>/dev/null | tr -d '\r'
  exit 0
fi

if command -v xsel >/dev/null 2>&1; then
  xsel --clipboard --output 2>/dev/null | tr -d '\r'
  exit 0
fi

exit 0
