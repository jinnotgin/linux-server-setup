#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
# shellcheck source=scripts/healthcheck-setup.sh
source "$SCRIPT_DIR/healthcheck-setup.sh"

update_system() {
  echo "Updating apt package lists and upgrading packages..."
  $SUDO apt-get update -y || return 1
  $SUDO env DEBIAN_FRONTEND=noninteractive apt-get upgrade -y || return 1
}
configure_locale_timezone() {
  echo "Configuring locale to en_US.UTF-8 and timezone to Asia/Singapore..."
  apt_install_best_effort locales tzdata
  $SUDO locale-gen en_US.UTF-8 || return 1
  $SUDO update-locale LANG=en_US.UTF-8 || return 1
  $SUDO timedatectl set-timezone Asia/Singapore || return 1
}
ensure_linux_user() {
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
harden_ssh() {
  echo "Hardening SSH configuration..."
  local sshd_config=/etc/ssh/sshd_config
  $SUDO cp "$sshd_config" "${sshd_config}.bak.$(date +%Y%m%d%H%M%S)" || return 1

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
    "$sshd_config" || return 1

  if ! grep -q '^Protocol 2' "$sshd_config"; then
    echo 'Protocol 2' | $SUDO tee -a "$sshd_config" >/dev/null || return 1
  fi

  if [[ -n "$ssh_port" ]]; then
    SSH_PORT_SELECTED="$ssh_port"
    if grep -qE '^#?Port ' "$sshd_config"; then
      $SUDO sed -i -E "s/^#?Port .*/Port $ssh_port/" "$sshd_config" || return 1
    else
      echo "Port $ssh_port" | $SUDO tee -a "$sshd_config" >/dev/null || return 1
    fi
    echo "SSH will listen on port $ssh_port (remember to adjust firewall)."
  fi

  $SUDO systemctl restart sshd || return 1
}
install_common_packages() {
  echo "Installing base dependencies..."
  apt_install_best_effort \
    ca-certificates curl gnupg lsb-release software-properties-common ufw sudo jq uuid-runtime btop
}
configure_tailscale_forwarding() {
  echo "Enabling IP forwarding for Tailscale subnet router/exit-node use..."
  local sysctl_file="/etc/sysctl.d/99-tailscale.conf"
  if [[ ! -d /etc/sysctl.d ]]; then
    sysctl_file="/etc/sysctl.conf"
  fi

  if [[ "$sysctl_file" == "/etc/sysctl.conf" ]]; then
    if ! grep -qE '^net\.ipv4\.ip_forward[[:space:]]*=' "$sysctl_file" 2>/dev/null; then
      echo 'net.ipv4.ip_forward = 1' | $SUDO tee -a "$sysctl_file" >/dev/null || return 1
    else
      $SUDO sed -i -E 's/^net\.ipv4\.ip_forward[[:space:]]*=.*/net.ipv4.ip_forward = 1/' "$sysctl_file" || return 1
    fi
    if ! grep -qE '^net\.ipv6\.conf\.all\.forwarding[[:space:]]*=' "$sysctl_file" 2>/dev/null; then
      echo 'net.ipv6.conf.all.forwarding = 1' | $SUDO tee -a "$sysctl_file" >/dev/null || return 1
    else
      $SUDO sed -i -E 's/^net\.ipv6\.conf\.all\.forwarding[[:space:]]*=.*/net.ipv6.conf.all.forwarding = 1/' "$sysctl_file" || return 1
    fi
  else
    printf 'net.ipv4.ip_forward = 1\nnet.ipv6.conf.all.forwarding = 1\n' | $SUDO tee "$sysctl_file" >/dev/null || return 1
  fi

  $SUDO sysctl -p "$sysctl_file" || return 1
}
configure_tailscale_udp_offloads() {
  echo "Configuring Linux UDP offload tuning for Tailscale..."
  apt_install_best_effort ethtool
  if ! have_command ethtool; then
    warn_continue "ethtool is unavailable; skipping Tailscale UDP offload tuning."
    return 0
  fi
  if ! have_command ip; then
    warn_continue "ip command is unavailable; skipping Tailscale UDP offload tuning."
    return 0
  fi

  local netdev
  netdev=$(ip -o route get 8.8.8.8 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
  if [[ -z "$netdev" ]]; then
    warn_continue "Could not determine default network interface; skipping Tailscale UDP offload tuning."
    return 0
  fi

  if ! $SUDO ethtool -K "$netdev" rx-udp-gro-forwarding on rx-gro-list off; then
    warn_continue "Could not apply Tailscale UDP offload tuning on \`$netdev\`; the interface or kernel may not support these flags."
    return 0
  fi

  $SUDO tee /usr/local/sbin/tailscale-udp-offload >/dev/null <<'EOF' || return 1
#!/bin/sh
set -eu

NETDEV=$(ip -o route get 8.8.8.8 2>/dev/null | awk '{for (i=1; i<=NF; i++) if ($i == "dev") {print $(i+1); exit}}')
if [ -z "$NETDEV" ]; then
  echo "Could not determine default network interface." >&2
  exit 1
fi

ethtool -K "$NETDEV" rx-udp-gro-forwarding on rx-gro-list off
EOF
  $SUDO chmod 755 /usr/local/sbin/tailscale-udp-offload || return 1

  if systemctl is-enabled networkd-dispatcher >/dev/null 2>&1; then
    $SUDO mkdir -p /etc/networkd-dispatcher/routable.d || return 1
    printf '#!/bin/sh\n\n/usr/local/sbin/tailscale-udp-offload\n' | \
      $SUDO tee /etc/networkd-dispatcher/routable.d/50-tailscale >/dev/null || return 1
    $SUDO chmod 755 /etc/networkd-dispatcher/routable.d/50-tailscale || return 1
    $SUDO /etc/networkd-dispatcher/routable.d/50-tailscale || return 1
    append_setup_log "Installed persistent Tailscale UDP offload script for \`$netdev\`."
  else
    $SUDO tee /etc/systemd/system/tailscale-udp-offload.service >/dev/null <<'EOF' || return 1
[Unit]
Description=Apply Tailscale UDP forwarding offload settings
Wants=network-online.target
After=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/tailscale-udp-offload

[Install]
WantedBy=multi-user.target
EOF
    $SUDO systemctl daemon-reload || return 1
    $SUDO systemctl enable tailscale-udp-offload.service || return 1
    $SUDO systemctl start tailscale-udp-offload.service || return 1
    append_setup_log "Installed persistent Tailscale UDP offload systemd service."
  fi
}
configure_tailscale_firewalld() {
  if have_command firewall-cmd && systemctl is-active firewalld >/dev/null 2>&1; then
    echo "firewalld detected; enabling masquerading for Tailscale subnet routing compatibility..."
    $SUDO firewall-cmd --permanent --add-masquerade || return 1
    $SUDO firewall-cmd --reload || return 1
  fi
}
install_tailscale() {
  echo "Installing Tailscale and enabling exit-node advertising..."
  if ! command -v curl >/dev/null 2>&1; then
    $SUDO apt-get update -y
    apt_install_best_effort curl
  fi
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl is required to install Tailscale." >&2
    return 1
  fi

  curl -fsSL https://tailscale.com/install.sh | $SUDO sh || return 1
  $SUDO systemctl enable --now tailscaled || return 1

  configure_tailscale_forwarding || return 1
  configure_tailscale_udp_offloads || return 1
  configure_tailscale_firewalld || return 1

  read -r -p "Enable Tailscale SSH? (y/N): " tailscale_ssh
  read -r -p "Subnet routes to advertise (comma-separated CIDRs, leave blank for none): " tailscale_routes

  local tailscale_args=(--advertise-exit-node)
  if [[ "$tailscale_ssh" =~ ^[Yy]$ ]]; then
    tailscale_args+=(--ssh)
  fi
  if [[ -n "$tailscale_routes" ]]; then
    tailscale_args+=(--advertise-routes="$tailscale_routes")
  fi

  $SUDO tailscale set "${tailscale_args[@]}" || return 1

  read -r -p "Tailscale auth key (tskey-..., leave blank to skip bringing the node up now): " tailscale_key
  if [[ -n "$tailscale_key" ]]; then
    $SUDO tailscale up --auth-key="$tailscale_key" "${tailscale_args[@]}" || return 1
  else
    local tailscale_followup_args="--advertise-exit-node"
    if [[ "$tailscale_ssh" =~ ^[Yy]$ ]]; then
      tailscale_followup_args="$tailscale_followup_args --ssh"
    fi
    if [[ -n "$tailscale_routes" ]]; then
      tailscale_followup_args="$tailscale_followup_args --advertise-routes=$tailscale_routes"
    fi
    echo "Skipped 'tailscale up'; run 'sudo tailscale up --auth-key=... $tailscale_followup_args' later."
    if [[ ! "$tailscale_ssh" =~ ^[Yy]$ ]]; then
      echo "Tailscale SSH was not enabled; add '--ssh' to that command later if you want it."
    fi
  fi
}
configure_ufw() {
  echo "Configuring UFW..."
  apt_install_best_effort ufw
  if ! have_command ufw; then
    echo "ufw is not installed; skipping firewall configuration." >&2
    return 1
  fi

  $SUDO ufw default deny incoming || return 1
  $SUDO ufw default allow outgoing || return 1

  local ssh_ports=("22")
  if [[ -n "$SSH_PORT_SELECTED" && "$SSH_PORT_SELECTED" != "22" ]]; then
    ssh_ports+=("$SSH_PORT_SELECTED")
  fi
  for p in "${ssh_ports[@]}"; do
    $SUDO ufw allow "$p"/tcp || return 1
  done
  $SUDO ufw allow ssh || return 1
  $SUDO ufw allow http || return 1
  $SUDO ufw allow https || return 1

  if command -v tailscale >/dev/null 2>&1; then
    if ip link show tailscale0 >/dev/null 2>&1; then
      echo "Tailscale detected; allowing traffic on tailscale0 interface..."
      $SUDO ufw allow in on tailscale0 || return 1
      $SUDO ufw allow out on tailscale0 || return 1
    else
      echo "Tailscale installed but tailscale0 interface not yet active."
      echo "Run 'sudo ufw allow in on tailscale0 && sudo ufw allow out on tailscale0 && sudo ufw reload' after 'tailscale up'."
    fi
  fi

  $SUDO ufw --force enable || return 1
  $SUDO ufw reload || return 1
}

run_linux_server_setup() {
  echo "--- General Linux server setup ---"
  read -r -p "Run system updates, locale, timezone, and sudo user setup? (y/N): " DO_SYSTEM
  read -r -p "Harden SSH/root login? (y/N): " DO_HARDEN
  read -r -p "Install Tailscale with SSH + exit-node enabled? (y/N): " DO_TAILSCALE
  read -r -p "Configure UFW firewall (SSH, HTTP, HTTPS)? (y/N): " DO_UFW
  read -r -p "Install host-level healthchecks.io uptime ping? (y/N): " DO_HEALTHCHECK

  if [[ "$DO_SYSTEM" =~ ^[Yy]$ || "$DO_HARDEN" =~ ^[Yy]$ || "$DO_TAILSCALE" =~ ^[Yy]$ || "$DO_UFW" =~ ^[Yy]$ || "$DO_HEALTHCHECK" =~ ^[Yy]$ ]]; then
    prompt_sudo
  fi

  if [[ "$DO_SYSTEM" =~ ^[Yy]$ ]]; then
    read -r -p "Username to create/ensure sudo access for (default: $TARGET_USER): " input_user
    TARGET_USER=${input_user:-$TARGET_USER}
    init_setup_log "linux-server" "$TARGET_USER"
    append_setup_log "Target user: \`$TARGET_USER\`."
    append_setup_log "System setup selected: \`$DO_SYSTEM\`."
    append_setup_log "SSH hardening selected: \`$DO_HARDEN\`."
    append_setup_log "Tailscale selected: \`$DO_TAILSCALE\`."
    append_setup_log "UFW selected: \`$DO_UFW\`."
    append_setup_log "Host healthcheck selected: \`$DO_HEALTHCHECK\`."
    run_step "System update" update_system
    run_step "Base dependency install" install_common_packages
    run_step "Locale/timezone configuration" configure_locale_timezone
    run_step "Sudo user setup" ensure_linux_user "$TARGET_USER"
  else
    read -r -p "Username to use for server ownership/settings (default: $TARGET_USER): " input_user
    TARGET_USER=${input_user:-$TARGET_USER}
    if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
      read -r -p "User '$TARGET_USER' does not exist. Create it now? (y/N): " create_user_choice
      if [[ "$create_user_choice" =~ ^[Yy]$ ]]; then
        prompt_sudo
        run_step "Sudo user setup" ensure_linux_user "$TARGET_USER"
        if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
          warn_continue "User '$TARGET_USER' still does not exist after setup attempt; continuing as current user '$(whoami)'."
          TARGET_USER="$(whoami)"
        fi
      else
        echo "User '$TARGET_USER' not found; continuing as current user '$(whoami)'."
        TARGET_USER="$(whoami)"
      fi
    fi
    init_setup_log "linux-server" "$TARGET_USER"
    append_setup_log "Target user: \`$TARGET_USER\`."
    append_setup_log "System setup selected: \`$DO_SYSTEM\`."
    append_setup_log "SSH hardening selected: \`$DO_HARDEN\`."
    append_setup_log "Tailscale selected: \`$DO_TAILSCALE\`."
    append_setup_log "UFW selected: \`$DO_UFW\`."
    append_setup_log "Host healthcheck selected: \`$DO_HEALTHCHECK\`."
  fi

  if [[ "$DO_HARDEN" =~ ^[Yy]$ ]]; then
    run_step "SSH hardening" harden_ssh
    append_setup_log "Selected SSH port after hardening step: \`${SSH_PORT_SELECTED:-existing}\`."
  fi

  if [[ "$DO_TAILSCALE" =~ ^[Yy]$ ]]; then
    run_step "Tailscale install" install_tailscale
  fi

  if [[ "$DO_UFW" =~ ^[Yy]$ ]]; then
    run_step "UFW configuration" configure_ufw
  fi

  if [[ "$DO_HEALTHCHECK" =~ ^[Yy]$ ]]; then
    read -r -p "healthchecks.io ping URL: " HEALTHCHECK_URL
    run_step_strict "Host healthcheck install" install_host_healthcheck "$HEALTHCHECK_URL"
  fi

  finish_setup_log
  echo "Linux server setup complete. You may need to re-login for group changes to take effect."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_linux_server_setup "$@"
fi
