#!/usr/bin/env bash
# nuplux one-command installer (Ubuntu/WSL-friendly)
set -e

APP_NAME="nuplux"
CONF_DIR="$HOME/.config/$APP_NAME"
ENABLE_FLAG="$CONF_DIR/enabled"
LOCAL_BIN="$HOME/.local/bin"
AUTO_BEGIN="# >>> ${APP_NAME} autostart >>>"
AUTO_END="# <<< ${APP_NAME} autostart <<<"

SCRIPTS_DIR="$CONF_DIR/scripts"
PLUGINS_DIR="$CONF_DIR/plugins"
CACHE_DIR="$HOME/.cache/$APP_NAME"

TMUX_CONF="$CONF_DIR/tmux.conf"
TMUX_SESSION="main"

# Quiet by default (set QUIET=0 to see logs)
QUIET="${QUIET:-1}"
log() { [ "$QUIET" -eq 0 ] && printf '%s\n' "$*"; }
info() { printf '%s\n' "$*"; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

mkdir -p "$CONF_DIR" "$SCRIPTS_DIR" "$PLUGINS_DIR" "$LOCAL_BIN" "$CACHE_DIR"

# ---- Dependencies
if ! need_cmd tmux; then
  log "Installing tmux..."
  if need_cmd apt-get; then
    sudo apt-get update -qq >/dev/null 2>&1 || true
    sudo apt-get install -y -qq tmux git xclip >/dev/null 2>&1 || sudo apt-get install -y -qq tmux git >/dev/null 2>&1
  elif need_cmd dnf; then
    sudo dnf install -y tmux git xclip >/dev/null 2>&1 || sudo dnf install -y tmux git >/dev/null 2>&1
  elif need_cmd yum; then
    sudo yum install -y tmux git xclip >/dev/null 2>&1 || sudo yum install -y tmux git >/dev/null 2>&1
  else
    info "ERROR: Could not find a supported package manager (apt/dnf/yum)."
    exit 1
  fi
fi

# ---- Windows clipboard paste helper (no trailing newline; UTF-8 safe)
cat > "$SCRIPTS_DIR/win-paste.sh" <<'EOF'
#!/usr/bin/env bash
set -e

# Paste from Windows/System clipboard WITHOUT adding trailing newline.
# UTF-8 safe (fixes Cyrillic in WSL<->PowerShell).
# Keeps internal newlines; strips only CR and final LF.

if command -v powershell.exe >/dev/null 2>&1; then
  powershell.exe -NoProfile -Command "\
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); \
    \$t = Get-Clipboard -Raw; \
    if (\$null -ne \$t) { [Console]::Out.Write(\$t) }" \
  | tr -d '\r' | sed -z 's/\n$//'
  exit 0
fi

if command -v xclip >/dev/null 2>&1; then
  xclip -selection clipboard -o 2>/dev/null | tr -d '\r' | sed -z 's/\n$//'
  exit 0
fi

if command -v xsel >/dev/null 2>&1; then
  xsel --clipboard --output 2>/dev/null | tr -d '\r' | sed -z 's/\n$//'
  exit 0
fi

exit 0
EOF
chmod +x "$SCRIPTS_DIR/win-paste.sh"

# ---- Copy helper (OSC52 for remote; PowerShell for local WSL; UTF-8 safe)
cat > "$SCRIPTS_DIR/copy-to-clipboard.sh" <<'EOF'
#!/usr/bin/env bash
set -e
buf="$(cat)"

# Local WSL -> Windows clipboard via PowerShell: force UTF-8 input/output
if command -v powershell.exe >/dev/null 2>&1 && [ -z "${SSH_CLIENT:-}" ] && [ -z "${SSH_TTY:-}" ]; then
  printf "%s" "$buf" | powershell.exe -NoProfile -Command "\
    [Console]::InputEncoding  = [System.Text.UTF8Encoding]::new(); \
    [Console]::OutputEncoding = [System.Text.UTF8Encoding]::new(); \
    \$text = [Console]::In.ReadToEnd(); \
    Set-Clipboard -Value \$text"
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
EOF
chmod +x "$SCRIPTS_DIR/copy-to-clipboard.sh"

# ---- Reconnect GPG/SSH agent sockets (Ctrl+F5)
cat > "$SCRIPTS_DIR/reconnect-agents.sh" <<'EOF'
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
EOF
chmod +x "$SCRIPTS_DIR/reconnect-agents.sh"

# ---- APT updates count (cached)
cat > "$SCRIPTS_DIR/apt-updates.sh" <<EOF
#!/usr/bin/env bash
set -e

CACHE_DIR="$CACHE_DIR"
CACHE_FILE="\$CACHE_DIR/apt-updates.count"
TS_FILE="\$CACHE_DIR/apt-updates.ts"

TTL_MIN=10
TTL_SEC=\$((TTL_MIN * 60))

mkdir -p "\$CACHE_DIR"
now=\$(date +%s)

if [ -f "\$CACHE_FILE" ] && [ -f "\$TS_FILE" ]; then
  last=\$(cat "\$TS_FILE" 2>/dev/null || echo 0)
  if [ \$((now - last)) -lt "\$TTL_SEC" ]; then
    cat "\$CACHE_FILE"
    exit 0
  fi
fi

count="0"
if [ -x /usr/lib/update-notifier/apt-check ]; then
  out="\$(/usr/lib/update-notifier/apt-check 2>/dev/null || true)"   # "<updates>;<security>"
  n="\${out%%;*}"
  n="\${n//[^0-9]/}"
  count="\${n:-0}"
elif command -v apt >/dev/null 2>&1; then
  count="\$(LC_ALL=C apt list --upgradable 2>/dev/null | awk 'NR>1{c++} END{print c+0}')"
fi

printf "%s" "\$count" > "\$CACHE_FILE"
printf "%s" "\$now" > "\$TS_FILE"
printf "%s" "\$count"
EOF
chmod +x "$SCRIPTS_DIR/apt-updates.sh"

# ---- Disk usage helper
cat > "$SCRIPTS_DIR/disk.sh" <<'EOF'
#!/usr/bin/env bash
df -h / | awk 'NR==2 {printf "%s/%s (%s)", $3, $2, $5}'
EOF
chmod +x "$SCRIPTS_DIR/disk.sh"

# ---- Network speed (cached)
cat > "$SCRIPTS_DIR/netspeed.sh" <<EOF
#!/usr/bin/env bash
set -e

CACHE_DIR="$CACHE_DIR"
CACHE_FILE="\$CACHE_DIR/netspeed.txt"
TS_FILE="\$CACHE_DIR/netspeed.ts"

TTL_SEC=2

mkdir -p "\$CACHE_DIR"
now=\$(date +%s)

if [ -f "\$CACHE_FILE" ] && [ -f "\$TS_FILE" ]; then
  last=\$(cat "\$TS_FILE" 2>/dev/null || echo 0)
  if [ \$((now - last)) -lt "\$TTL_SEC" ]; then
    cat "\$CACHE_FILE"
    exit 0
  fi
fi

iface=\$(ip route 2>/dev/null | awk '/default/ {print \$5; exit}')
if [ -z "\$iface" ]; then
  out="No net"
  printf "%s" "\$out" > "\$CACHE_FILE"
  printf "%s" "\$now" > "\$TS_FILE"
  printf "%s" "\$out"
  exit 0
fi

rx1=\$(cat /sys/class/net/"\$iface"/statistics/rx_bytes 2>/dev/null || echo 0)
tx1=\$(cat /sys/class/net/"\$iface"/statistics/tx_bytes 2>/dev/null || echo 0)
sleep 1
rx2=\$(cat /sys/class/net/"\$iface"/statistics/rx_bytes 2>/dev/null || echo 0)
tx2=\$(cat /sys/class/net/"\$iface"/statistics/tx_bytes 2>/dev/null || echo 0)

rx=\$(( (rx2 - rx1) / 1024 ))
tx=\$(( (tx2 - tx1) / 1024 ))

out="↓\${rx}K ↑\${tx}K"
printf "%s" "\$out" > "\$CACHE_FILE"
printf "%s" "\$now" > "\$TS_FILE"
printf "%s" "\$out"
EOF
chmod +x "$SCRIPTS_DIR/netspeed.sh"

# ---- Battery helper (optional)
cat > "$SCRIPTS_DIR/battery.sh" <<'EOF'
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
EOF
chmod +x "$SCRIPTS_DIR/battery.sh"

# ---- Uptime helper
cat > "$SCRIPTS_DIR/uptime.sh" <<'EOF'
#!/usr/bin/env bash
uptime | awk '{print $(NF-2)}' | sed 's/,//'
EOF
chmod +x "$SCRIPTS_DIR/uptime.sh"

# ---- Write tmux config (stored in $CONF_DIR)
cat > "$TMUX_CONF" <<EOF
# ${APP_NAME} tmux configuration

set -g default-terminal "screen-256color"
set -g history-limit 50000

# Enable mouse only in WSL (PowerShell available); disable on remote SSH for reliable client-side paste.
if-shell -b 'command -v powershell.exe >/dev/null 2>&1' 'set -g mouse on' 'set -g mouse off'

# Helps with timing/escape parsing and avoids stray terminal replies on some clients.
set -sg escape-time 50

set -g detach-on-destroy off

# Border lines: single (no "double-line gap")
run-shell -b 'tmux set-option -g pane-border-lines single 2>/dev/null || true'

# Byobu-like "thicker" borders (optical): blue fg + dark-blue bg
set -g pane-border-style fg=colour39,bg=colour17
set -g pane-active-border-style fg=colour39,bg=colour19

# Paste bindings only when Windows clipboard is available (WSL)
if-shell -b 'command -v powershell.exe >/dev/null 2>&1' \
  'unbind -n MouseDown3Pane; bind-key -n MouseDown3Pane run-shell -b "~/.config/${APP_NAME}/scripts/win-paste.sh | tmux load-buffer - && tmux paste-buffer"' \
  'unbind -n MouseDown3Pane'

if-shell -b 'command -v powershell.exe >/dev/null 2>&1' \
  'bind-key -n C-v run-shell -b "~/.config/${APP_NAME}/scripts/win-paste.sh | tmux load-buffer - && tmux paste-buffer"; bind-key -n S-Insert run-shell -b "~/.config/${APP_NAME}/scripts/win-paste.sh | tmux load-buffer - && tmux paste-buffer"' \
  'unbind -n C-v; unbind -n S-Insert'

# Status bar
set -g status on
set -g status-position bottom
set -g status-interval 2
run-shell -b "~/.config/${APP_NAME}/scripts/apt-updates.sh >/dev/null 2>&1 || true"

set -g status-style bg=colour235,fg=colour250
set -g status-left-length 30
set -g status-right-length 250

set -g status-left "#[fg=colour16,bg=colour254,bold] #h #[fg=colour254,bg=colour240]#[fg=colour231,bg=colour240] #S #[fg=colour240,bg=colour235]"
set -g status-right "#[fg=colour245]#[fg=colour231,bg=colour245] APT:#(~/.config/${APP_NAME}/scripts/apt-updates.sh) #[fg=colour237]#[fg=colour248,bg=colour237] Up:#(~/.config/${APP_NAME}/scripts/uptime.sh) #[fg=colour239]#[fg=colour250,bg=colour239] CPU:#{cpu_percentage} RAM:#{ram_percentage} #[fg=colour240]#[fg=colour231,bg=colour240] Load:#(cat /proc/loadavg|awk '{print \$1}') #[fg=colour241]#[fg=colour231,bg=colour241] Disk:#(~/.config/${APP_NAME}/scripts/disk.sh) #[fg=colour242]#[fg=colour231,bg=colour242] #(~/.config/${APP_NAME}/scripts/battery.sh) #[fg=colour33]#[fg=colour231,bg=colour33] Net:#(~/.config/${APP_NAME}/scripts/netspeed.sh) #[fg=colour254]#[fg=colour16,bg=colour254] %d-%b #[fg=colour231]#[fg=colour16,bg=colour231,bold] %H:%M:%S "

# Tabs
setw -g window-status-separator ""
setw -g window-status-format "#[fg=colour244,bg=colour235] #I:#W#F "
setw -g window-status-current-format "#[fg=colour235,bg=colour31]#[fg=colour117,bg=colour31] #I:#W#F #[fg=colour31,bg=colour235]"

# Indices
set -g base-index 1
setw -g pane-base-index 1
set -g renumber-windows on

# Messages
set -g message-style bg=colour31,fg=colour231,bold

# ===================== KEYBINDINGS =====================

bind-key -n F2 new-window -c "#{pane_current_path}"
bind-key -n F3 previous-window
bind-key -n F4 next-window
bind-key -n F5 source-file "~/.config/${APP_NAME}/tmux.conf" \\; display-message "Reloaded!"
bind-key -n F6 detach-client
bind-key -n S-F6 detach-client
bind-key -n F7 copy-mode
bind-key -n F8 command-prompt -p "(rename '#W')" "rename-window '%%'"
bind-key -n F12 lock-client

bind-key -n S-F2 split-window -v -c "#{pane_current_path}"
bind-key -n C-F2 split-window -h -c "#{pane_current_path}"
bind-key -n S-F3 select-pane -t :.-
bind-key -n S-F4 select-pane -t :.+
bind-key -n S-F5 kill-pane -a
bind-key -n C-F6 kill-pane
bind-key -n C-F5 run-shell -b "~/.config/${APP_NAME}/scripts/reconnect-agents.sh"

bind -n M-PageUp   copy-mode -e \\; send -X page-up
bind -n M-PageDown copy-mode -e \\; send -X page-down
bind -n M-Up       copy-mode -e \\; send -X cursor-up
bind -n M-Down     copy-mode -e \\; send -X cursor-down

bind-key -n S-Left  select-pane -L
bind-key -n S-Right select-pane -R
bind-key -n S-Up    select-pane -U
bind-key -n S-Down  select-pane -D

# Smaller resize steps
bind-key -n M-S-Left  resize-pane -L 2
bind-key -n M-S-Right resize-pane -R 2
bind-key -n M-S-Up    resize-pane -U 1
bind-key -n M-S-Down  resize-pane -D 1

# Copy mode (VI)
setw -g mode-keys vi
bind-key -T copy-mode-vi 'v' send -X begin-selection
bind-key -T copy-mode-vi 'y' send -X copy-pipe-and-cancel "~/.config/${APP_NAME}/scripts/copy-to-clipboard.sh"
bind-key -T copy-mode-vi Enter send -X copy-pipe-and-cancel "~/.config/${APP_NAME}/scripts/copy-to-clipboard.sh"
bind-key -T copy-mode-vi MouseDragEnd1Pane send -X copy-pipe-and-cancel "~/.config/${APP_NAME}/scripts/copy-to-clipboard.sh"

# Ctrl+C: copy only in copy-mode; normal Ctrl+C otherwise
bind-key -T copy-mode-vi C-c send-keys -X copy-pipe-and-cancel "~/.config/${APP_NAME}/scripts/copy-to-clipboard.sh"
bind-key -T copy-mode    C-c send-keys -X copy-pipe-and-cancel "~/.config/${APP_NAME}/scripts/copy-to-clipboard.sh"

# OSC52 clipboard support
set -g set-clipboard on
set -ga terminal-overrides ',*:Ms=\\E]52;c;%p2%s\\007'

bind | split-window -h -c "#{pane_current_path}"
bind - split-window -v -c "#{pane_current_path}"

# ==================== PLUGINS (optional) ====================
set -g @plugin 'tmux-plugins/tpm'
set -g @plugin 'tmux-plugins/tmux-sensible'
set -g @plugin 'tmux-plugins/tmux-resurrect'
set -g @plugin 'tmux-plugins/tmux-continuum'
set -g @plugin 'tmux-plugins/tmux-cpu'
set -g @plugin 'tmux-plugins/tmux-yank'
set -g @plugin 'tmux-plugins/tmux-open'
set -g @plugin 'tmux-plugins/tmux-prefix-highlight'

set -g @cpu_low_fg_color "#[fg=green]"
set -g @cpu_medium_fg_color "#[fg=yellow]"
set -g @cpu_high_fg_color "#[fg=red]"

run "~/.config/${APP_NAME}/plugins/tpm/tpm"
EOF

# ---- Install TPM into $CONF_DIR (no ~/.tmux/plugins)
if [ ! -d "$PLUGINS_DIR/tpm" ]; then
  if need_cmd git; then
    git clone -q https://github.com/tmux-plugins/tpm "$PLUGINS_DIR/tpm" >/dev/null 2>&1 || true
  fi
fi

# ---- nuplux command (real executable, not only alias)
cat > "$LOCAL_BIN/nuplux" <<EOF
#!/usr/bin/env bash
set -e
exec tmux -f "$TMUX_CONF" new-session -A -s "$TMUX_SESSION"
EOF
chmod +x "$LOCAL_BIN/nuplux"

# ---- enable/disable autostart
cat > "$LOCAL_BIN/nuplux-enable" <<EOF
#!/usr/bin/env bash
set -e
mkdir -p "$CONF_DIR"
: > "$ENABLE_FLAG"
echo "nuplux autostart: ENABLED"
echo "Open a new terminal tab/window."
EOF
chmod +x "$LOCAL_BIN/nuplux-enable"

cat > "$LOCAL_BIN/nuplux-disable" <<EOF
#!/usr/bin/env bash
set -e
rm -f "$ENABLE_FLAG" 2>/dev/null || true
echo "nuplux autostart: DISABLED"
EOF
chmod +x "$LOCAL_BIN/nuplux-disable"

# ---- Bashrc integration (managed block)
touch "$HOME/.bashrc"

# Ensure ~/.local/bin in PATH (once)
if ! grep -q 'export PATH="$HOME/.local/bin:$PATH"' "$HOME/.bashrc" 2>/dev/null; then
  echo 'export PATH="$HOME/.local/bin:$PATH"' >> "$HOME/.bashrc"
fi

# Remove existing managed block (prevents duplicates)
awk -v b="$AUTO_BEGIN" -v e="$AUTO_END" '
  $0==b {skip=1; next}
  $0==e {skip=0; next}
  skip!=1 {print}
' "$HOME/.bashrc" > "$HOME/.bashrc.tmp" && mv "$HOME/.bashrc.tmp" "$HOME/.bashrc"

cat >> "$HOME/.bashrc" <<EOF

$AUTO_BEGIN
# nuplux uses a file flag so you can toggle autostart (nuplux-enable / nuplux-disable).
if [ -f "$ENABLE_FLAG" ]; then
  alias nuplux='tmux -f "$TMUX_CONF"'
  case "\$-" in
    *i*)
      if command -v tmux >/dev/null 2>&1 && [ -z "\${TMUX:-}" ]; then
        case "\${TERM:-}" in
          dumb) : ;;
          *)
            # Flush any already-buffered junk (non-blocking) to avoid stray characters on attach.
            while IFS= read -r -t 0 -n 1 _junk; do :; done
            tmux -f "$TMUX_CONF" new-session -A -s "$TMUX_SESSION"
            ;;
        esac
      fi
      ;;
  esac
fi
$AUTO_END
EOF

# ---- Friendly final message + optional start
# Colors (auto-disable when not a TTY)
if [ -t 1 ]; then
  C_CYAN=$'\033[36m'
  C_GREEN=$'\033[32m'
  C_BOLD=$'\033[1m'
  C_RESET=$'\033[0m'
else
  C_CYAN=""; C_GREEN=""; C_BOLD=""; C_RESET=""
fi

cyan()  { info "${C_CYAN}${C_BOLD}$*${C_RESET}"; }
green() { info "${C_GREEN}$*${C_RESET}"; }

# ---- Friendly final message + optional start
info ""
cyan "                Nuplux is ready to use! 🎉"
cyan "****************************************************************"
info ""

info "Nuplux turns tmux into a Byobu-like workspace:"
info "  • modern status bar (updates, CPU/RAM, net speed, time)"
info "  • clipboard helpers (WSL + OSC52 for SSH)"
info "  • persistent session: you can close the terminal and keep working later"
info ""
info "Where things live:"
info "  • Config:  $TMUX_CONF"
info "  • Home:    $CONF_DIR"
info ""
green "Next steps:"
green "  • Start now:         nuplux"
green "  • Enable autostart:  nuplux-enable"
green "  • Disable autostart: nuplux-disable"
info ""

# ---- Optional: reload .bashrc (prompt)
if [ -t 0 ]; then
  read -r -p "Reload ~/.bashrc now? [Y/n] " _ans
  _ans="${_ans:-Y}"
  if [[ "$_ans" =~ ^[Yy]$ ]]; then
    # shellcheck disable=SC1090
    . "$HOME/.bashrc"
  fi
fi

# ---- Final behavior: if in tmux -> reload config; else -> start nuplux (only when interactive)
if [ -n "${TMUX:-}" ]; then
  tmux source-file "$TMUX_CONF"
  tmux display-message "Reloaded: $TMUX_CONF"
else
  if [ -t 0 ] && [ -t 1 ]; then
    "$LOCAL_BIN/nuplux"
  fi
fi

# Ask to start nuplux now (interactive only)
if [ -t 0 ] && [ -t 1 ]; then
  read -r -p "Start Nuplux now? [Y/n] " _start
  _start="${_start:-Y}"
  if [[ "$_start" =~ ^[Yy]$ ]]; then
    if [ -n "${TMUX:-}" ]; then
      tmux source-file "$TMUX_CONF"
      tmux display-message "Reloaded: $TMUX_CONF"
    else
      "$LOCAL_BIN/nuplux"
    fi
  else
    info "No problem — you can run 'nuplux' anytime."
  fi
fi

