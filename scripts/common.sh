#!/usr/bin/env bash

# Shared defaults for the purpose-based setup scripts.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
TEMPLATE_DIR="$REPO_ROOT/docker-templates"
STACK_DIR="${STACK_DIR:-}"
SSH_PORT_SELECTED="${SSH_PORT_SELECTED:-}"
BACKUP_DIR="${BACKUP_DIR:-/opt/portainer/backups}"
RCLONE_REMOTE="${RCLONE_REMOTE:-portainer_gdrive}"
TARGET_USER="${TARGET_USER:-$(whoami)}"
COMPOSE_OUTPUTS=()
SETUP_LOG_FILE="${SETUP_LOG_FILE:-}"

if [[ $(id -u) -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

ensure_command() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}
prompt_sudo() {
  if [[ -n "$SUDO" ]]; then
    echo "Requesting sudo access (you may be prompted for your password)..."
    $SUDO -v
  fi
}
gen_uuid() {
  if command -v uuidgen >/dev/null 2>&1; then
    uuidgen
  elif command -v python3 >/dev/null 2>&1; then
    python3 - <<'PY'
import uuid
print(uuid.uuid4())
PY
  elif [[ -r /proc/sys/kernel/random/uuid ]]; then
    cat /proc/sys/kernel/random/uuid
  else
    echo "ffffffff-ffff-4fff-afff-$(printf '%012x' $RANDOM)"  # last-resort
  fi
}
gen_short_id() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 4
  else
    printf '%08x' "$RANDOM$RANDOM"
  fi
}
init_setup_log() {
  local name="$1" owner="${2:-$TARGET_USER}" owner_home log_dir timestamp
  timestamp=$(date +%Y%m%d-%H%M%S)
  owner_home=$(eval echo "~$owner" 2>/dev/null || echo "$HOME")
  log_dir="$owner_home/linux-server-setup-logs"
  if ! mkdir -p "$log_dir" 2>/dev/null; then
    log_dir="$HOME/linux-server-setup-logs"
    mkdir -p "$log_dir"
  fi
  SETUP_LOG_FILE="$log_dir/${name}-${timestamp}.md"
  {
    printf '# %s setup log\n\n' "$name"
    printf -- '- Generated: `%s`\n' "$(date -Iseconds)"
    printf -- '- Host: `%s`\n' "$(hostname 2>/dev/null || echo unknown)"
    printf -- '- User: `%s`\n\n' "$owner"
    printf '## Actions\n\n'
  } > "$SETUP_LOG_FILE"
}
append_setup_log() {
  [[ -n "$SETUP_LOG_FILE" ]] || return 0
  printf -- '- %s\n' "$1" >> "$SETUP_LOG_FILE"
}
finish_setup_log() {
  [[ -n "$SETUP_LOG_FILE" ]] || return 0
  printf '\n## Finished\n\n' >> "$SETUP_LOG_FILE"
  printf -- '- Completed: `%s`\n' "$(date -Iseconds)" >> "$SETUP_LOG_FILE"
  echo "Wrote setup log to $SETUP_LOG_FILE"
}
