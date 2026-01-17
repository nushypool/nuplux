#!/usr/bin/env bash
# nuplux one-command installer (Ubuntu/WSL-friendly)
set -e

echo "Starting nuplux installer..." >&2

# Save whether we're interactive BEFORE any stdin manipulation
IS_INTERACTIVE=0
[ -t 0 ] && [ -t 1 ] && IS_INTERACTIVE=1

# If stdin isn't a TTY (e.g. curl | bash), don't block on reads
if [ ! -t 0 ]; then
  exec </dev/null
fi

APP_NAME="nuplux"
CONF_DIR="$HOME/.config/$APP_NAME"
ENABLE_FLAG="$CONF_DIR/enabled"
LOCAL_BIN="$HOME/.local/bin"
AUTO_BEGIN="# >>> ${APP_NAME} autostart >>>"
AUTO_END="# <<< ${APP_NAME} autostart <<<"

SCRIPTS_DIR="$CONF_DIR/scripts"
CACHE_DIR="$HOME/.cache/$APP_NAME"

THEME_FILE="$CONF_DIR/theme.conf"
TMUX_TEMPLATE="$CONF_DIR/tmux.conf.template"
TMUX_CONF="$CONF_DIR/tmux.conf"
TMUX_SESSION="main"

# Quiet by default (set QUIET=0 to see logs)
QUIET="${QUIET:-1}"
log() { [ "$QUIET" -eq 0 ] && printf '%s\n' "$*" >&2; }
info() { printf '%s\n' "$*" >&2; }

need_cmd() { command -v "$1" >/dev/null 2>&1; }

download() {
  local url="$1" dest="$2"
  if need_cmd curl; then
    curl -fsSL "$url" -o "$dest"
  elif need_cmd wget; then
    wget -qO "$dest" "$url"
  else
    info "ERROR: need curl or wget to download $url"
    exit 1
  fi
}

echo "Setting up paths..." >&2

SCRIPT_PATH="${BASH_SOURCE[0]:-$0}"
SCRIPT_DIR=""
[ -f "$SCRIPT_PATH" ] && SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd || pwd)"

echo "Script dir: $SCRIPT_DIR" >&2

LOCAL_ASSETS_DIR="${SCRIPT_DIR:+$SCRIPT_DIR/files}"
REMOTE_ASSETS_URL="${NUX_ASSETS_URL:-https://raw.githubusercontent.com/nushypool/nuplux/main/files}"
USE_LOCAL_ASSETS=0

if [ -n "$LOCAL_ASSETS_DIR" ] && [ -f "$LOCAL_ASSETS_DIR/config/theme.conf" ]; then
  USE_LOCAL_ASSETS=1
fi

asset_source_desc="$REMOTE_ASSETS_URL"
[ "$USE_LOCAL_ASSETS" -eq 1 ] && asset_source_desc="$LOCAL_ASSETS_DIR"
echo "Using assets from: $asset_source_desc" >&2

fetch_asset() {
  local rel="$1" dest="$2"
  mkdir -p "$(dirname "$dest")"

  if [ "$USE_LOCAL_ASSETS" -eq 1 ]; then
    cp "$LOCAL_ASSETS_DIR/$rel" "$dest"
  else
    download "$REMOTE_ASSETS_URL/$rel" "$dest"
  fi
}

fetch_exec() {
  local rel="$1" dest="$2"
  fetch_asset "$rel" "$dest"
  chmod +x "$dest"
}

echo "Creating directories..." >&2

mkdir -p "$CONF_DIR" "$SCRIPTS_DIR" "$LOCAL_BIN" "$CACHE_DIR"

echo "Checking dependencies..." >&2

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

echo "Installing config files..." >&2

# ---- Install config + scripts from repo assets
# Theme: Do not overwrite if user already customized it
if [ ! -f "$THEME_FILE" ]; then
  fetch_asset "config/theme.conf" "$THEME_FILE"
fi

fetch_asset "config/tmux.conf.template" "$TMUX_TEMPLATE"
fetch_exec "config/scripts/win-paste.sh" "$SCRIPTS_DIR/win-paste.sh"
fetch_exec "config/scripts/copy-to-clipboard.sh" "$SCRIPTS_DIR/copy-to-clipboard.sh"
fetch_exec "config/scripts/reconnect-agents.sh" "$SCRIPTS_DIR/reconnect-agents.sh"
fetch_exec "config/scripts/apt-updates.sh" "$SCRIPTS_DIR/apt-updates.sh"
fetch_exec "config/scripts/disk.sh" "$SCRIPTS_DIR/disk.sh"
fetch_exec "config/scripts/netspeed.sh" "$SCRIPTS_DIR/netspeed.sh"
fetch_exec "config/scripts/battery.sh" "$SCRIPTS_DIR/battery.sh"
fetch_exec "config/scripts/uptime.sh" "$SCRIPTS_DIR/uptime.sh"
fetch_exec "config/scripts/cpu_percentage.sh" "$SCRIPTS_DIR/cpu_percentage.sh"
fetch_exec "config/scripts/ram_percentage.sh" "$SCRIPTS_DIR/ram_percentage.sh"

fetch_exec "bin/nuplux" "$LOCAL_BIN/nuplux"
fetch_exec "bin/nuplux-enable" "$LOCAL_BIN/nuplux-enable"
fetch_exec "bin/nuplux-disable" "$LOCAL_BIN/nuplux-disable"

# ---- Generate tmux.conf from template before installing plugins
echo "Generating tmux configuration..." >&2

# Simple theme variable replacement (inline, no nuplux command needed)
if [ -f "$THEME_FILE" ] && [ -f "$TMUX_TEMPLATE" ]; then
  # Read theme variables and apply them to template
  cp "$TMUX_TEMPLATE" "$TMUX_CONF"
  
  # Apply theme substitutions if theme.conf exists
  while IFS='=' read -r key value; do
    # Skip comments and empty lines
    [[ "$key" =~ ^#.*$ ]] && continue
    [[ -z "$key" ]] && continue
    
    # Remove leading/trailing whitespace
    key=$(echo "$key" | xargs)
    value=$(echo "$value" | xargs)
    
    # Replace @NUX_KEY@ with value in tmux.conf
    sed -i "s|@${key}@|${value}|g" "$TMUX_CONF"
  done < "$THEME_FILE"
fi

echo "Configuring bashrc..." >&2

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
  # Always run the nuplux command so it can render tmux.conf from theme.conf before starting tmux.
  alias nuplux="\$HOME/.local/bin/nuplux"
  case "\$-" in
    *i*)
      if command -v tmux >/dev/null 2>&1 && [ -z "\${TMUX:-}" ]; then
        case "\${TERM:-}" in
          dumb) : ;;
          *)
            # Flush any already-buffered junk (non-blocking) to avoid stray characters on attach.
            while IFS= read -r -t 0 -n 1 _junk; do :; done
            "\$HOME/.local/bin/nuplux"
            ;;
        esac
      fi
      ;;
  esac
fi
$AUTO_END
EOF

# ---- Friendly final message + optional start

# Colors (only use if output is to a terminal)
if [ -t 1 ]; then
  CYAN='\033[36m'
  GREEN='\033[32m'
  BOLD='\033[1m'
  RESET='\033[0m'
else
  CYAN=''
  GREEN=''
  BOLD=''
  RESET=''
fi

echo "" >&2
echo -e "${CYAN}${BOLD}================================================================${RESET}" >&2
echo -e "${CYAN}${BOLD}                Nuplux is ready to use! 🎉${RESET}" >&2
echo -e "${CYAN}${BOLD}================================================================${RESET}" >&2
echo "" >&2
echo "Nuplux turns tmux into a Byobu-like workspace:" >&2
echo "  • modern status bar (updates, CPU/RAM, net speed, time)" >&2
echo "  • clipboard helpers (WSL + OSC52 for SSH)" >&2
echo "  • persistent session: you can close the terminal and keep working later" >&2
echo "" >&2
echo "Where things live:" >&2
echo "  • Config:  $TMUX_CONF" >&2
echo "  • Theme:   $THEME_FILE" >&2
echo "  • Home:    $CONF_DIR" >&2
echo "" >&2
echo -e "${GREEN}Next steps:${RESET}" >&2
echo -e "${GREEN}  • Start now:         nuplux${RESET}" >&2
echo -e "${GREEN}  • Enable autostart:  nuplux-enable${RESET}" >&2
echo -e "${GREEN}  • Disable autostart: nuplux-disable${RESET}" >&2
echo "" >&2

# Ask reload .bashrc (default: Yes) just before asking to start (interactive only)
if [ "$IS_INTERACTIVE" -eq 1 ]; then
  read -r -p "Reload ~/.bashrc now? [Y/n] " _ans
  _ans="${_ans:-y}"
  if [[ "$_ans" =~ ^[Yy]$ ]]; then
    # shellcheck disable=SC1090
    . "$HOME/.bashrc"
  fi
fi

# Ask to start nuplux now (interactive only)
if [ "$IS_INTERACTIVE" -eq 1 ]; then
  read -r -p "Start Nuplux now? [Y/n] " _start
  _start="${_start:-Y}"
  if [[ "$_start" =~ ^[Yy]$ ]]; then
    if [ -n "${TMUX:-}" ]; then
      tmux source-file "$TMUX_CONF"
      tmux display-message "Reloaded: $TMUX_CONF"
    else
      # Start tmux in background briefly to let plugins initialize
      tmux -f "$TMUX_CONF" new-session -d -s "init_session" 2>/dev/null || true
      sleep 1
      # Source plugins explicitly
      tmux -f "$TMUX_CONF" run-shell "~/.config/nuplux/plugins/tpm/scripts/source_plugins.sh" 2>/dev/null || true
      sleep 1
      # Kill the init session
      tmux kill-session -t "init_session" 2>/dev/null || true
      # Now start normally
      "$LOCAL_BIN/nuplux"
    fi
  else
    echo "No problem — you can run 'nuplux' anytime." >&2
  fi
fi