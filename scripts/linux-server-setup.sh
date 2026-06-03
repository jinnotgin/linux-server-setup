#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

update_system() {
  echo "Updating apt package lists and upgrading packages..."
  $SUDO apt-get update -y
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
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

  $SUDO usermod -aG sudo "$username"
  echo "$username ALL=(ALL) ALL" | $SUDO tee /etc/sudoers.d/"$username" >/dev/null
  $SUDO chmod 440 /etc/sudoers.d/"$username"
}
harden_ssh() {
  echo "Hardening SSH configuration..."
  local sshd_config=/etc/ssh/sshd_config
  $SUDO cp "$sshd_config" "${sshd_config}.bak.$(date +%Y%m%d%H%M%S)"

  read -r -p "SSH port to use (default: 226): " ssh_port
  ssh_port=${ssh_port:-226}
  if [[ ! "$ssh_port" =~ ^[0-9]+$ ]]; then
    echo "Invalid SSH port; keeping existing." >&2
    ssh_port=""
  fi

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

  if [[ -n "$ssh_port" ]]; then
    SSH_PORT_SELECTED="$ssh_port"
    if grep -qE '^#?Port ' "$sshd_config"; then
      $SUDO sed -i -E "s/^#?Port .*/Port $ssh_port/" "$sshd_config"
    else
      echo "Port $ssh_port" | $SUDO tee -a "$sshd_config" >/dev/null
    fi
    echo "SSH will listen on port $ssh_port (remember to adjust firewall)."
  fi

  $SUDO systemctl restart sshd
}
install_common_packages() {
  echo "Installing base dependencies..."
  $SUDO apt-get install -y \
    ca-certificates curl gnupg lsb-release software-properties-common ufw sudo jq uuid-runtime
}
install_tailscale() {
  echo "Installing Tailscale and enabling SSH + exit-node advertising..."
  if ! command -v curl >/dev/null 2>&1; then
    $SUDO apt-get update -y
    $SUDO apt-get install -y curl
  fi

  curl -fsSL https://tailscale.com/install.sh | $SUDO sh
  $SUDO systemctl enable --now tailscaled

  # Pre-set preferences as requested
  $SUDO tailscale set --ssh --advertise-exit-node

  read -r -p "Tailscale auth key (tskey-..., leave blank to skip bringing the node up now): " tailscale_key
  if [[ -n "$tailscale_key" ]]; then
    $SUDO tailscale up --auth-key="$tailscale_key" --advertise-exit-node
  else
    echo "Skipped 'tailscale up'; run 'sudo tailscale up --auth-key=... --advertise-exit-node' later."
  fi
}
configure_ufw() {
  echo "Configuring UFW (with Docker-friendly rules)..."
  $SUDO apt-get install -y ufw

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

  $SUDO ufw default deny incoming
  $SUDO ufw default allow outgoing

  local ssh_ports=("22")
  if [[ -n "$SSH_PORT_SELECTED" && "$SSH_PORT_SELECTED" != "22" ]]; then
    ssh_ports+=("$SSH_PORT_SELECTED")
  fi
  for p in "${ssh_ports[@]}"; do
    $SUDO ufw allow "$p"/tcp
    $SUDO ufw route allow proto tcp from any to any port "$p"
  done
  $SUDO ufw allow ssh
  $SUDO ufw allow http
  $SUDO ufw route allow proto tcp from any to any port 80
  $SUDO ufw allow https
  $SUDO ufw route allow proto tcp from any to any port 443

  # Public proxy ports:
  # - 2053/tcp: gateway router
  # - 6443/tcp: CDN proxy
  # - 8443/tcp+udp: Hysteria2 WARP
  # - 8444/tcp+udp: Hysteria2
  # - 20011/tcp, 30011/tcp: VLESS direct WARP variants
  $SUDO ufw allow 2053/tcp
  $SUDO ufw route allow proto tcp from any to any port 2053
  $SUDO ufw allow 6443/tcp
  $SUDO ufw route allow proto tcp from any to any port 6443
  $SUDO ufw allow 8443/tcp
  $SUDO ufw allow 8443/udp
  $SUDO ufw route allow proto tcp from any to any port 8443
  $SUDO ufw route allow proto udp from any to any port 8443
  $SUDO ufw allow 8444/tcp
  $SUDO ufw allow 8444/udp
  $SUDO ufw route allow proto tcp from any to any port 8444
  $SUDO ufw route allow proto udp from any to any port 8444
  $SUDO ufw allow 20011/tcp
  $SUDO ufw allow 30011/tcp
  $SUDO ufw route allow proto tcp from any to any port 20011
  $SUDO ufw route allow proto tcp from any to any port 30011

  # If Tailscale is installed, allow all traffic on the tailscale0 interface
  if command -v tailscale >/dev/null 2>&1; then
    if ip link show tailscale0 >/dev/null 2>&1; then
      echo "Tailscale detected; allowing traffic on tailscale0 interface..."
      $SUDO ufw allow in on tailscale0
      $SUDO ufw allow out on tailscale0
    else
      echo "Tailscale installed but tailscale0 interface not yet active."
      echo "Run 'sudo ufw allow in on tailscale0 && sudo ufw allow out on tailscale0 && sudo ufw reload' after 'tailscale up'."
    fi
  fi

  $SUDO ufw --force enable
  $SUDO ufw reload
}

run_linux_server_setup() {
  echo "--- General Linux server setup ---"
  read -r -p "Run system updates, locale, timezone, and sudo user setup? (y/N): " DO_SYSTEM
  read -r -p "Harden SSH/root login? (y/N): " DO_HARDEN
  read -r -p "Install Tailscale with SSH + exit-node enabled? (y/N): " DO_TAILSCALE
  read -r -p "Configure UFW firewall (HTTP/HTTPS + SSH with Docker rules)? (y/N): " DO_UFW

  if [[ "$DO_SYSTEM" =~ ^[Yy]$ || "$DO_HARDEN" =~ ^[Yy]$ || "$DO_TAILSCALE" =~ ^[Yy]$ || "$DO_UFW" =~ ^[Yy]$ ]]; then
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
    read -r -p "Username to use for server ownership/settings (default: $TARGET_USER): " input_user
    TARGET_USER=${input_user:-$TARGET_USER}
    if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
      read -r -p "User '$TARGET_USER' does not exist. Create it now? (y/N): " create_user_choice
      if [[ "$create_user_choice" =~ ^[Yy]$ ]]; then
        prompt_sudo
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

  if [[ "$DO_TAILSCALE" =~ ^[Yy]$ ]]; then
    install_tailscale
  fi

  if [[ "$DO_UFW" =~ ^[Yy]$ ]]; then
    configure_ufw
  fi

  echo "Linux server setup complete. You may need to re-login for group changes to take effect."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_linux_server_setup "$@"
fi
