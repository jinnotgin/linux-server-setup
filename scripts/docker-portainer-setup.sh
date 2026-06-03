#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

ensure_docker_user() {
  local username="$1"

  if id -u "$username" >/dev/null 2>&1; then
    echo "User '$username' already exists. Ensuring sudo access..."
    read -r -p "Change password for '$username'? (y/N): " change_pw
    if [[ "$change_pw" =~ ^[Yy]$ ]]; then
      $SUDO passwd "$username"
    fi
  else
    echo "Creating user '$username'..."
    $SUDO adduser --disabled-password --gecos "" "$username"
    echo "Set a password for '$username' (needed for sudo access):"
    $SUDO passwd "$username"
  fi

  $SUDO usermod -aG sudo "$username" || return 1
  echo "$username ALL=(ALL) ALL" | $SUDO tee /etc/sudoers.d/"$username" >/dev/null || return 1
  $SUDO chmod 440 /etc/sudoers.d/"$username" || return 1
}
install_docker() {
  echo "Installing Docker and Docker Compose..."
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  local distro codename
  distro=$(. /etc/os-release && echo "$ID")
  codename=$(lsb_release -cs)
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/${distro} ${codename} stable" | \
    $SUDO tee /etc/apt/sources.list.d/docker.list >/dev/null
  $SUDO apt-get update -y
  $SUDO apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  $SUDO systemctl enable --now docker
  $SUDO usermod -aG docker "$TARGET_USER" || true
}
install_portainer() {
  echo "Deploying Portainer..."
  $SUDO docker volume create portainer_data >/dev/null
  if $SUDO docker ps --format '{{.Names}}' | grep -q '^portainer$'; then
    echo "Portainer container already running."
  else
    $SUDO docker run -d \
      -p 8000:8000 -p 9443:9443 \
      --name portainer \
      --restart=unless-stopped \
      -v /var/run/docker.sock:/var/run/docker.sock \
      -v portainer_data:/data \
      portainer/portainer-ce:latest
  fi
}
install_docker_and_portainer() {
  install_docker
  install_portainer
}
configure_rclone() {
  echo "Ensuring rclone is installed..."
  apt_install_best_effort rclone
  if ! command -v rclone >/dev/null 2>&1; then
    echo "rclone is required for Portainer Google Drive backups." >&2
    return 1
  fi
  local user_home
  user_home=$(eval echo "~$TARGET_USER")
  local rclone_conf="$user_home/.config/rclone/rclone.conf"

  cat <<'NOTE'
Configure rclone with Google Drive OAuth (no service account).
- You will create a remote named "portainer_gdrive".
- Choose "Google Drive" as the storage provider.
- Use a desktop OAuth client ID and client secret from Google Cloud Console if you have one. Leaving both blank also works, but rclone's shared client is rate-limited.
- For a personal Google Drive, do not use a service account.
- For "scope", "drive.file" is recommended for backup-only use because it limits access to files rclone creates.
- On a headless server, answer "n" to auto config, run the displayed "rclone authorize" command on a computer with a browser, then paste the returned token back here.
NOTE

  read -r -p "Run interactive 'rclone config' now to create '${RCLONE_REMOTE}'? (y/N): " do_rclone_cfg
  if [[ "$do_rclone_cfg" =~ ^[Yy]$ ]]; then
    echo "Launching rclone config as $TARGET_USER (config: $rclone_conf)..."
    run_as_user "$TARGET_USER" rclone config
    if run_as_user "$TARGET_USER" rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}"; then
      echo "rclone remote '${RCLONE_REMOTE}' detected."
    else
      echo "rclone remote '${RCLONE_REMOTE}' not found; run 'rclone config' later to add it." >&2
    fi
  else
    echo "Skipping interactive rclone config. Add remote '${RCLONE_REMOTE}' later with 'rclone config'."
  fi
}
create_backup_artifacts() {
  echo "Setting up Portainer backup scripts and systemd timer..."
  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker is required for Portainer backup artifacts." >&2
    return 1
  fi
  $SUDO mkdir -p "$BACKUP_DIR"
  local default_host_label
  default_host_label=$(hostname -s 2>/dev/null || echo "starlight")
  read -r -p "Preferred host label for rclone backups (e.g. starlight): " BACKUP_HOST_LABEL
  BACKUP_HOST_LABEL=${BACKUP_HOST_LABEL:-$default_host_label}
  echo "Using '$BACKUP_HOST_LABEL' as the host label under portainer-backups/"
  local user_home rclone_conf
  user_home=$(eval echo "~$TARGET_USER")
  rclone_conf="$user_home/.config/rclone/rclone.conf"

  cat <<EOS | $SUDO tee /usr/local/bin/portainer-gdrive-backup.sh >/dev/null
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/opt/portainer/backups"
RCLONE_REMOTE="portainer_gdrive"
RCLONE_CONFIG="$rclone_conf"
HOST_LABEL="$BACKUP_HOST_LABEL"
REMOTE_DIR="portainer-backups/\${HOST_LABEL}"
KEEP_COUNT=10
TIMESTAMP=\$(date +%Y%m%d-%H%M%S)
ARCHIVE="\$BACKUP_DIR/portainer-\$TIMESTAMP.tar.gz"

mkdir -p "\$BACKUP_DIR"
docker run --rm -v portainer_data:/data -v "\$BACKUP_DIR":/backup alpine \
  sh -c "tar czf /backup/portainer-\$TIMESTAMP.tar.gz /data"

if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}"; then
  if rclone copy "\$ARCHIVE" "\${RCLONE_REMOTE}:/\${REMOTE_DIR}"; then
    python3 - "\${RCLONE_REMOTE}" "\${REMOTE_DIR}" "\${KEEP_COUNT}" <<'PY'
import json
import subprocess
import sys

remote, remote_dir, keep_raw = sys.argv[1:]
keep = int(keep_raw)
target = f"{remote}:/{remote_dir}"

result = subprocess.run(
    ["rclone", "lsjson", "--files-only", "--fast-list", target],
    capture_output=True,
    text=True,
)
if result.returncode != 0:
    sys.exit(0)

try:
    entries = json.loads(result.stdout)
except json.JSONDecodeError:
    sys.exit(0)

files = [f for f in entries if not f.get("IsDir")]
files.sort(key=lambda f: f.get("ModTime") or "")
if len(files) <= keep:
    sys.exit(0)

for entry in files[:-keep]:
    name = entry.get("Path") or entry.get("Name")
    if not name:
        continue
    subprocess.run(["rclone", "delete", f"{target}/{name}"], check=False)
PY
  else
    echo "rclone upload failed; keeping local archive at \$ARCHIVE" >&2
  fi
else
  echo "rclone remote ${RCLONE_REMOTE} not found; skipping cloud upload" >&2
fi
EOS
  $SUDO chmod +x /usr/local/bin/portainer-gdrive-backup.sh

  cat <<'EOS' | $SUDO tee /etc/systemd/system/portainer-backup.service >/dev/null
[Unit]
Description=Portainer data backup to local archive and Google Drive
After=docker.service
Requires=docker.service

[Service]
Type=oneshot
ExecStart=/usr/local/bin/portainer-gdrive-backup.sh

[Install]
WantedBy=multi-user.target
EOS

  cat <<'EOS' | $SUDO tee /etc/systemd/system/portainer-backup.timer >/dev/null
[Unit]
Description=Run Portainer backup daily

[Timer]
OnCalendar=daily
Persistent=true

[Install]
WantedBy=timers.target
EOS

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable --now portainer-backup.timer
}

configure_ufw_docker() {
  echo "Adding Docker-friendly UFW rules..."
  apt_install_best_effort ufw
  if ! have_command ufw; then
    echo "ufw is not installed; skipping Docker firewall configuration." >&2
    return 1
  fi

  if ! $SUDO grep -q "BEGIN UFW AND DOCKER" /etc/ufw/after.rules 2>/dev/null; then
    cat <<'EOS' | $SUDO tee -a /etc/ufw/after.rules >/dev/null
# BEGIN UFW AND DOCKER
*filter
:ufw-user-forward - [0:0]
:ufw-docker-logging-deny - [0:0]
:DOCKER-USER - [0:0]
-A DOCKER-USER -j ufw-user-forward

-A DOCKER-USER -m conntrack --ctstate RELATED,ESTABLISHED -j RETURN
-A DOCKER-USER -m conntrack --ctstate INVALID -j DROP
-A DOCKER-USER -i docker0 -o docker0 -j ACCEPT

-A DOCKER-USER -j RETURN -s 10.0.0.0/8
-A DOCKER-USER -j RETURN -s 172.16.0.0/12
-A DOCKER-USER -j RETURN -s 192.168.0.0/16

-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 10.0.0.0/8
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 172.16.0.0/12
-A DOCKER-USER -j ufw-docker-logging-deny -m conntrack --ctstate NEW -d 192.168.0.0/16

-A DOCKER-USER -j RETURN

-A ufw-docker-logging-deny -m limit --limit 3/min --limit-burst 10 -j LOG --log-prefix "[UFW DOCKER BLOCK] "
-A ufw-docker-logging-deny -j DROP

COMMIT
# END UFW AND DOCKER
EOS
  fi

  # Now that the DOCKER-USER chain is in place, add route rules for base ports
  local ssh_ports=("22")
  if [[ -n "${SSH_PORT_SELECTED:-}" && "$SSH_PORT_SELECTED" != "22" ]]; then
    ssh_ports+=("$SSH_PORT_SELECTED")
  fi
  for p in "${ssh_ports[@]}"; do
    $SUDO ufw route allow proto tcp from any to any port "$p"
  done
  $SUDO ufw route allow proto tcp from any to any port 80
  $SUDO ufw route allow proto tcp from any to any port 443

  # Portainer management ports
  $SUDO ufw allow 8000/tcp
  $SUDO ufw allow 9443/tcp
  $SUDO ufw route allow proto tcp from any to any port 8000
  $SUDO ufw route allow proto tcp from any to any port 9443

  $SUDO ufw reload
}

run_docker_portainer_setup() {
  echo "--- Docker + Portainer CE setup ---"
  read -r -p "Username to use for Docker group membership (default: $TARGET_USER): " input_user
  TARGET_USER=${input_user:-$TARGET_USER}
  if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    read -r -p "User '$TARGET_USER' does not exist. Create it now? (y/N): " create_user_choice
    if [[ "$create_user_choice" =~ ^[Yy]$ ]]; then
      prompt_sudo
      run_step "Docker user setup" ensure_docker_user "$TARGET_USER"
      if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
        warn_continue "User '$TARGET_USER' still does not exist after setup attempt; continuing as current user '$(whoami)'."
        TARGET_USER="$(whoami)"
      fi
    else
      echo "User '$TARGET_USER' not found; continuing as current user '$(whoami)'."
      TARGET_USER="$(whoami)"
    fi
  fi

  read -r -p "Install Docker Engine, Docker Compose plugin, and Portainer CE? (Y/n): " DO_DOCKER
  read -r -p "Add Docker-friendly UFW rules and open Portainer ports (8000, 9443)? (y/N): " DO_UFW_DOCKER
  read -r -p "Configure Portainer backups to Google Drive with rclone? (y/N): " DO_BACKUP
  init_setup_log "docker-portainer" "$TARGET_USER"
  append_setup_log "Target user: \`$TARGET_USER\`."
  append_setup_log "Docker + Portainer selected: \`${DO_DOCKER:-Y}\`."
  append_setup_log "Docker-friendly UFW selected: \`$DO_UFW_DOCKER\`."
  append_setup_log "Portainer backup selected: \`$DO_BACKUP\`."

  if [[ -z "$DO_DOCKER" || "$DO_DOCKER" =~ ^[Yy]$ || "$DO_UFW_DOCKER" =~ ^[Yy]$ || "$DO_BACKUP" =~ ^[Yy]$ ]]; then
    prompt_sudo
  fi

  if [[ -z "$DO_DOCKER" || "$DO_DOCKER" =~ ^[Yy]$ ]]; then
    run_step_strict "Docker and Portainer install" install_docker_and_portainer
  fi

  if [[ "$DO_UFW_DOCKER" =~ ^[Yy]$ ]]; then
    run_step_strict "Docker-friendly UFW configuration" configure_ufw_docker
  fi

  if [[ "$DO_BACKUP" =~ ^[Yy]$ ]]; then
    run_step_strict "rclone configuration" configure_rclone
    run_step_strict "Portainer backup timer setup" create_backup_artifacts
    append_setup_log "Backup directory: \`$BACKUP_DIR\`."
  fi

  finish_setup_log
  echo "Docker + Portainer setup complete. Re-login so $TARGET_USER picks up docker group membership."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_docker_portainer_setup "$@"
fi
