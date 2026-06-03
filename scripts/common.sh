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
