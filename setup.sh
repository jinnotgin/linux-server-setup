#!/usr/bin/env bash
set -euo pipefail

# Determine whether to prefix commands with sudo
if [[ $(id -u) -eq 0 ]]; then
  SUDO=""
else
  SUDO="sudo"
fi

TARGET_USER="$(whoami)"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE_DIR="$SCRIPT_DIR/docker-templates"
GENERATED_DIR="$SCRIPT_DIR/generated"
BACKUP_DIR="/opt/portainer/backups"
RCLONE_REMOTE="portainer_gdrive"
COMPOSE_OUTPUTS=()

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

update_system() {
  echo "Updating apt package lists and upgrading packages..."
  $SUDO apt-get update -y
  $SUDO DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
}

configure_locale_timezone() {
  echo "Configuring locale to en_US.UTF-8 and timezone to Asia/Singapore..."
  $SUDO apt-get install -y locales tzdata
  $SUDO locale-gen en_US.UTF-8
  $SUDO update-locale LANG=en_US.UTF-8
  $SUDO timedatectl set-timezone Asia/Singapore
}

ensure_user() {
  local username="$1"

  if id -u "$username" >/dev/null 2>&1; then
    echo "User '$username' already exists. Ensuring sudo access..."
  else
    echo "Creating user '$username'..."
    $SUDO adduser --disabled-password --gecos "" "$username"
    echo "Set a password for '$username' (needed for sudo access):"
    $SUDO passwd "$username"
  fi

  $SUDO usermod -aG sudo "$username"
  echo "$username ALL=(ALL) ALL" | $SUDO tee /etc/sudoers.d/"$username" >/dev/null
  $SUDO chmod 440 /etc/sudoers.d/"$username"
}

harden_ssh() {
  echo "Hardening SSH configuration..."
  local sshd_config=/etc/ssh/sshd_config
  $SUDO cp "$sshd_config" "${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"

  $SUDO sed -i -E \
    -e 's/^#?PermitRootLogin.*/PermitRootLogin no/' \
    -e 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' \
    -e 's/^#?PermitEmptyPasswords.*/PermitEmptyPasswords no/' \
    -e 's/^#?ChallengeResponseAuthentication.*/ChallengeResponseAuthentication no/' \
    -e 's/^#?X11Forwarding.*/X11Forwarding no/' \
    "$sshd_config"

  if ! grep -q '^Protocol 2' "$sshd_config"; then
    echo 'Protocol 2' | $SUDO tee -a "$sshd_config" >/dev/null
  fi

  $SUDO systemctl restart sshd
}

install_common_packages() {
  echo "Installing base dependencies..."
  $SUDO apt-get install -y \
    ca-certificates curl gnupg lsb-release software-properties-common ufw sudo jq
}

install_docker() {
  echo "Installing Docker and Docker Compose..."
  $SUDO install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/$(. /etc/os-release && echo "$ID")/gpg | $SUDO gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/$(. /etc/os-release && echo "$ID") \"\$(lsb_release -cs)\" stable" | \
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

configure_rclone() {
  echo "Ensuring rclone is installed..."
  $SUDO apt-get install -y rclone
  read -r -p "Provide path to a Google Drive service account JSON for automated backups (leave blank to skip): " sa_path
  if [[ -n "$sa_path" ]]; then
    if [[ ! -f "$sa_path" ]]; then
      echo "Service account file not found at $sa_path" >&2
      exit 1
    fi
    read -r -p "Enter optional Google Drive folder ID for backups (leave blank to use root): " folder_id
    $SUDO rclone config create "$RCLONE_REMOTE" drive scope=drive service_account_file="$sa_path" config_is_local=true ${folder_id:+root_folder_id=$folder_id} --non-interactive || true
  else
    echo "Skipping rclone remote creation. You can configure '$RCLONE_REMOTE' later with 'rclone config'."
  fi
}

create_backup_artifacts() {
  echo "Setting up Portainer backup scripts and systemd timer..."
  $SUDO mkdir -p "$BACKUP_DIR"
  cat <<'EOS' | $SUDO tee /usr/local/bin/portainer-gdrive-backup.sh >/dev/null
#!/usr/bin/env bash
set -euo pipefail
BACKUP_DIR="/opt/portainer/backups"
RCLONE_REMOTE="portainer_gdrive"
TIMESTAMP=$(date +%Y%m%d-%H%M%S)
ARCHIVE="$BACKUP_DIR/portainer-$TIMESTAMP.tar.gz"

mkdir -p "$BACKUP_DIR"
docker run --rm -v portainer_data:/data -v "$BACKUP_DIR":/backup alpine \
  sh -c "tar czf /backup/portainer-$TIMESTAMP.tar.gz /data"

if command -v rclone >/dev/null 2>&1 && rclone listremotes 2>/dev/null | grep -q "^${RCLONE_REMOTE}"; then
  rclone copy "$ARCHIVE" "${RCLONE_REMOTE}:portainer-backups/"
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

render_template_file() {
  local src="$1" dest="$2"
  shift 2
  local content
  content="$(cat "$src")"
  while [[ $# -gt 0 ]]; do
    local key="$1"; shift
    local value="$1"; shift
    content="${content//{{$key}}/$value}"
  done
  printf "%s" "$content" > "$dest"
}

collect_domains() {
  local domains=()
  while true; do
    read -r -p "Enter a domain to include (leave blank to finish): " d
    [[ -z "$d" ]] && break
    domains+=("$d")
  done
  if [[ ${#domains[@]} -eq 0 ]]; then
    echo "At least one domain is required." >&2
    exit 1
  fi
  DOMAINS_ARRAY=("${domains[@]}")
  DOMAINS_ARGS="-d ${domains[*]/#/-d }"
  PRIMARY_DOMAIN="${domains[0]}"
}

generate_vless_clients() {
  local count
  read -r -p "How many VLESS accounts do you want? " count
  [[ -z "$count" ]] && count=1
  local clients=()
  for ((i=1; i<=count; i++)); do
    read -r -p "UUID for VLESS user $i (leave blank to auto-generate): " uuid
    if [[ -z "$uuid" ]]; then
      uuid=$(uuidgen)
    fi
    clients+=("{\"id\":\"$uuid\",\"flow\":\"xtls-rprx-vision\"}")
  done
  VLESS_CLIENTS="[$(IFS=,; echo "${clients[*]}")]"
}

generate_hysteria_users() {
  local count
  read -r -p "How many Hysteria2 users do you want? " count
  [[ -z "$count" ]] && count=1
  local users=()
  for ((i=1; i<=count; i++)); do
    read -r -p "Username for Hysteria user $i: " uname
    read -r -p "Password for $uname (leave blank to auto-generate): " pwd
    if [[ -z "$pwd" ]]; then
      pwd=$(openssl rand -hex 12)
    fi
    users+=("{\"name\":\"$uname\",\"password\":\"$pwd\"}")
  done
  HYSTERIA_USERS="[$(IFS=,; echo "${users[*]}")]"
}

ensure_proxy_network() {
  local net="proxy_net"
  if command -v docker >/dev/null 2>&1 && ! docker network inspect "$net" >/dev/null 2>&1; then
    echo "Creating shared proxy network '$net' for Nginx/Xray interop..."
    $SUDO docker network create "$net"
  fi
}

seed_nginx_site() {
  local dest="$GENERATED_DIR/nginx/www"
  mkdir -p "$dest"

  read -r -p "Download sample 2048 static site into Nginx web root? (y/N): " seed_site
  if [[ "$seed_site" =~ ^[Yy]$ ]]; then
    if command -v git >/dev/null 2>&1; then
      if [[ -n "$(ls -A "$dest" 2>/dev/null)" ]]; then
        echo "Directory $dest already has content; skipping download."
      else
        if git clone https://github.com/jinnotgin/2048.git "$dest"; then
          echo "Seeded Nginx web root with 2048 static site."
        else
          echo "Failed to clone sample site; leave or place your own content in $dest" >&2
        fi
      fi
    else
      echo "git not found; place your site content under $dest manually." >&2
    fi
  else
    if [[ ! -f "$dest/index.html" ]]; then
      cat <<'EOF' > "$dest/index.html"
<!DOCTYPE html>
<html lang="en">
<head>
  <meta charset="UTF-8">
  <title>Hello</title>
  <style>
    body { font-family: Arial, sans-serif; background: #0d1117; color: #e6edf3; display: flex; align-items: center; justify-content: center; height: 100vh; margin: 0; }
    .card { background: #161b22; padding: 24px 28px; border-radius: 12px; box-shadow: 0 8px 24px rgba(0,0,0,0.35); text-align: center; width: 420px; }
    a { color: #58a6ff; text-decoration: none; }
    a:hover { text-decoration: underline; }
  </style>
</head>
<body>
  <div class="card">
    <h1>Hello there</h1>
    <p>This is a placeholder page. Swap in your own files under <code>generated/nginx/www</code> when you're ready.</p>
  </div>
</body>
</html>
EOF
    fi
  fi
}

render_templates() {
  if [[ ! -d "$TEMPLATE_DIR" ]]; then
    echo "Template directory not found; skipping template rendering."
    return
  fi

  read -r -p "Do you want to render docker-compose templates now? (y/N): " render
  if [[ ! "$render" =~ ^[Yy]$ ]]; then
    return
  fi

  mkdir -p "$GENERATED_DIR"
  echo "Collecting domain information (supports multiple domains)..."
  collect_domains
  read -r -p "Contact email for certificates (used by Certbot/Nginx): " CERT_EMAIL

  generate_vless_clients
  generate_hysteria_users

  local tls_cert="/certs/live/${PRIMARY_DOMAIN}/fullchain.pem"
  local tls_key="/certs/live/${PRIMARY_DOMAIN}/privkey.pem"
  read -r -p "Path to TLS certificate (default: $tls_cert): " input_cert
  read -r -p "Path to TLS private key (default: $tls_key): " input_key
  TLS_CERT=${input_cert:-$tls_cert}
  TLS_KEY=${input_key:-$tls_key}

  # Render SSL renewal
  render_template_file "$TEMPLATE_DIR/ssl-renewal/docker-compose.yml.template" \
    "$GENERATED_DIR/ssl-renewal.yml" \
    DOMAINS "$DOMAINS_ARGS" CERT_EMAIL "$CERT_EMAIL"
  COMPOSE_OUTPUTS+=("$GENERATED_DIR/ssl-renewal.yml")

  # Render Nginx reverse proxy
  mkdir -p "$GENERATED_DIR/nginx"
  seed_nginx_site
  render_template_file "$TEMPLATE_DIR/nginx/nginx.conf.template" \
    "$GENERATED_DIR/nginx/nginx.conf" \
    PRIMARY_DOMAIN "$PRIMARY_DOMAIN" TLS_CERT_PATH "$TLS_CERT" TLS_KEY_PATH "$TLS_KEY" VLESS_UPSTREAM "xray-vless-ws:10000"
  render_template_file "$TEMPLATE_DIR/nginx/docker-compose.yml.template" \
    "$GENERATED_DIR/nginx/docker-compose.yml" \
    PRIMARY_DOMAIN "$PRIMARY_DOMAIN"
  COMPOSE_OUTPUTS+=("$GENERATED_DIR/nginx/docker-compose.yml")

  # Render VLESS
  mkdir -p "$GENERATED_DIR/vless-ws"
  render_template_file "$TEMPLATE_DIR/vless-ws/config.json.template" \
    "$GENERATED_DIR/vless-ws/config.json" \
    PRIMARY_DOMAIN "$PRIMARY_DOMAIN" VLESS_CLIENTS "$VLESS_CLIENTS"
  render_template_file "$TEMPLATE_DIR/vless-ws/docker-compose.yml.template" \
    "$GENERATED_DIR/vless-ws/docker-compose.yml" \
    PRIMARY_DOMAIN "$PRIMARY_DOMAIN"
  COMPOSE_OUTPUTS+=("$GENERATED_DIR/vless-ws/docker-compose.yml")

  # Render Hysteria2
  mkdir -p "$GENERATED_DIR/hysteria2"
  read -r -p "Masquerade site for Hysteria2 (default: https://news.ycombinator.com): " MASQ
  MASQ=${MASQ:-https://news.ycombinator.com}
  render_template_file "$TEMPLATE_DIR/hysteria2/config.yaml.template" \
    "$GENERATED_DIR/hysteria2/config.yaml" \
    PRIMARY_DOMAIN "$PRIMARY_DOMAIN" HYSTERIA_USERS "$HYSTERIA_USERS" TLS_CERT "$TLS_CERT" TLS_KEY "$TLS_KEY" MASQUERADE "$MASQ"
  render_template_file "$TEMPLATE_DIR/hysteria2/docker-compose.yml.template" \
    "$GENERATED_DIR/hysteria2/docker-compose.yml" \
    PRIMARY_DOMAIN "$PRIMARY_DOMAIN"
  COMPOSE_OUTPUTS+=("$GENERATED_DIR/hysteria2/docker-compose.yml")

  echo "Templates rendered under $GENERATED_DIR. Update ports/paths as needed and run 'docker compose up -d' inside each directory."
}

main() {
  echo "--- Initial setup choices ---"
  read -r -p "Run system updates, locale, timezone, and sudo user setup? (y/N): " DO_SYSTEM
  read -r -p "Harden SSH/root login? (y/N): " DO_HARDEN
  read -r -p "Install Docker and Portainer? (y/N): " DO_DOCKER
  read -r -p "Configure Portainer backups to Google Drive? (y/N): " DO_BACKUP

  local needs_privileged="${DO_SYSTEM,,}${DO_HARDEN,,}${DO_DOCKER,,}${DO_BACKUP,,}"
  if [[ "$needs_privileged" =~ y ]]; then
    prompt_sudo
  fi

  if [[ "$DO_SYSTEM" =~ ^[Yy]$ ]]; then
    read -r -p "Username to create/ensure sudo access for (default: $TARGET_USER): " input_user
    TARGET_USER=${input_user:-$TARGET_USER}
    update_system
    install_common_packages
    configure_locale_timezone
    ensure_user "$TARGET_USER"
  else
    read -r -p "Username to use for Docker group membership (default: $TARGET_USER): " input_user
    TARGET_USER=${input_user:-$TARGET_USER}
    if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
      read -r -p "User '$TARGET_USER' does not exist. Create it now? (y/N): " create_user_choice
      if [[ "$create_user_choice" =~ ^[Yy]$ ]]; then
        ensure_user "$TARGET_USER"
      else
        echo "User '$TARGET_USER' not found; continuing as current user '$(whoami)'."
        TARGET_USER="$(whoami)"
      fi
    fi
  fi

  if [[ "$DO_HARDEN" =~ ^[Yy]$ ]]; then
    harden_ssh
  fi

  if [[ "$DO_DOCKER" =~ ^[Yy]$ ]]; then
    install_docker
    install_portainer
  fi

  if [[ "$DO_BACKUP" =~ ^[Yy]$ ]]; then
    configure_rclone
    create_backup_artifacts
  fi

  render_templates

  if command -v docker >/dev/null 2>&1 && [[ ${#COMPOSE_OUTPUTS[@]} -gt 0 ]]; then
    ensure_proxy_network
    read -r -p "Run any rendered docker-compose stacks now? (y/N): " RUN_TEMPLATES
    if [[ "$RUN_TEMPLATES" =~ ^[Yy]$ ]]; then
      for compose_file in "${COMPOSE_OUTPUTS[@]}"; do
        if [[ -f "$compose_file" ]]; then
          read -r -p "Launch stack from $(realpath "$compose_file")? (y/N): " run_this
          if [[ "$run_this" =~ ^[Yy]$ ]]; then
            $SUDO docker compose -f "$compose_file" up -d
          fi
        fi
      done
    fi
  fi

  echo "Setup complete. You may need to re-login for group changes to take effect ($TARGET_USER -> docker/sudo)."
}

main "$@"
