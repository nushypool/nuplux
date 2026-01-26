#!/usr/bin/env bash
set -e
have() { command -v "$1" >/dev/null 2>&1; }

msg=""
if have gpgconf; then
  gpg_sock="$(gpgconf --list-dirs agent-socket 2>/dev/null || true)"
  gpg_ssh_sock="$(gpgconf --list-dirs agent-ssh-socket 2>/dev/null || true)"

  if [ -n "${gpg_sock:-}" ]; then
    tmux set-environment -g GPG_AGENT_INFO "" 2>/dev/null || true
    tmux set-environment -g GPG_TTY "" 2>/dev/null || true
    tmux set-environment -g GPG_AGENT_SOCK "$gpg_sock" 2>/dev/null || true
    msg="gpg ok"
  fi

  if [ -n "${gpg_ssh_sock:-}" ]; then
    tmux set-environment -g SSH_AUTH_SOCK "$gpg_ssh_sock" 2>/dev/null || true
    if [ -n "$msg" ]; then msg="$msg, ssh->gpg"; else msg="ssh->gpg"; fi
  fi
fi

[ -n "${msg:-}" ] || msg="agents refreshed"
tmux display-message "Ctrl+F5: $msg"
