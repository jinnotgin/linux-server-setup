#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

install_host_healthcheck() {
  local healthcheck_url="$1"
  if [[ ! "$healthcheck_url" =~ ^https?:// ]]; then
    echo "Healthcheck URL must start with http:// or https://." >&2
    return 1
  fi
  if [[ "$healthcheck_url" == *"'"* ]]; then
    echo "Healthcheck URL cannot contain single quotes." >&2
    return 1
  fi

  echo "Installing host-level healthcheck timer..."
  $SUDO apt-get install -y curl

  $SUDO install -m 0755 -d /etc/linux-server-setup
  printf "HEALTHCHECK_URL='%s'\n" "$healthcheck_url" | $SUDO tee /etc/linux-server-setup/healthcheck.env >/dev/null
  $SUDO chmod 600 /etc/linux-server-setup/healthcheck.env

  cat <<'EOS' | $SUDO tee /etc/systemd/system/linux-server-healthcheck.service >/dev/null
[Unit]
Description=Ping healthchecks.io for host uptime
After=network-online.target
Wants=network-online.target

[Service]
Type=oneshot
EnvironmentFile=/etc/linux-server-setup/healthcheck.env
ExecStart=/usr/bin/curl -fsS --max-time 10 -o /dev/null ${HEALTHCHECK_URL}
EOS

  cat <<'EOS' | $SUDO tee /etc/systemd/system/linux-server-healthcheck.timer >/dev/null
[Unit]
Description=Run host uptime healthcheck ping every 5 minutes

[Timer]
OnBootSec=2min
OnUnitActiveSec=5min
RandomizedDelaySec=30s
Persistent=true

[Install]
WantedBy=timers.target
EOS

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now linux-server-healthcheck.timer
  append_setup_log "Installed host-level healthcheck timer: \`linux-server-healthcheck.timer\`."
  append_setup_log "Stored healthcheck URL in \`/etc/linux-server-setup/healthcheck.env\`."
}

run_healthcheck_setup() {
  echo "--- Host healthcheck setup ---"
  read -r -p "Username for setup log ownership (default: $TARGET_USER): " input_user
  TARGET_USER=${input_user:-$TARGET_USER}
  if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "User '$TARGET_USER' not found; continuing as current user '$(whoami)'."
    TARGET_USER="$(whoami)"
  fi

  init_setup_log "healthcheck" "$TARGET_USER"
  read -r -p "healthchecks.io ping URL: " HEALTHCHECK_URL
  if [[ -z "$HEALTHCHECK_URL" ]]; then
    echo "Healthcheck URL is required." >&2
    exit 1
  fi

  prompt_sudo
  install_host_healthcheck "$HEALTHCHECK_URL"
  finish_setup_log
  echo "Host healthcheck setup complete."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_healthcheck_setup "$@"
fi
