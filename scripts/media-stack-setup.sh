#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"

render_template_file() {
  local src="$1" dest="$2"
  shift 2
  if (( $# % 2 != 0 )); then
    echo "render_template_file received an odd number of key/value args" >&2
    return 1
  fi
  python3 - "$src" "$dest" "$@" <<'PY'
import sys
src, dest, *pairs = sys.argv[1:]
data = open(src, encoding="utf-8").read()
if len(pairs) % 2:
    sys.exit("Odd number of key/value args")
for i in range(0, len(pairs), 2):
    key, val = pairs[i], pairs[i+1]
    data = data.replace(f"{{{{{key}}}}}", val)
with open(dest, "w", encoding="utf-8") as f:
    f.write(data)
PY
}

setup_smb_mount() {
  read -r -p "NAS hostname (used as mount label and in extra_hosts, e.g. santa): " NAS_HOSTNAME
  NAS_HOSTNAME=${NAS_HOSTNAME:-nas}

  read -r -p "NAS IP address (used for SMB mount and container name resolution, e.g. 100.114.237.128): " NAS_IP
  if [[ -z "$NAS_IP" ]]; then
    echo "NAS IP is required for SMB mounting." >&2
    exit 1
  fi

  read -r -p "SMB share name on the NAS (e.g. Videos): " SMB_SHARE
  if [[ -z "$SMB_SHARE" ]]; then
    echo "SMB share name is required." >&2
    exit 1
  fi

  read -r -p "SMB username: " SMB_USER
  read -r -s -p "SMB password: " SMB_PASSWORD
  echo

  local default_mount="/mnt/$NAS_HOSTNAME"
  read -r -p "Mount point on this host (default: $default_mount): " SMB_MOUNT_POINT
  SMB_MOUNT_POINT=${SMB_MOUNT_POINT:-$default_mount}

  read -r -p "Videos subdirectory within the share (leave blank if the share root is the videos folder): " VIDEOS_SUBDIR
  if [[ -n "$VIDEOS_SUBDIR" ]]; then
    MEDIA_VIDEOS_PATH="$SMB_MOUNT_POINT/$VIDEOS_SUBDIR"
  else
    MEDIA_VIDEOS_PATH="$SMB_MOUNT_POINT"
  fi

  prompt_sudo

  $SUDO apt-get install -y cifs-utils

  # Store credentials in a root-only file
  local creds_file="/etc/smb-credentials-$NAS_HOSTNAME"
  printf 'username=%s\npassword=%s\n' "$SMB_USER" "$SMB_PASSWORD" | $SUDO tee "$creds_file" > /dev/null
  $SUDO chmod 600 "$creds_file"

  $SUDO mkdir -p "$SMB_MOUNT_POINT"

  local TARGET_UID TARGET_GID
  TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || id -u)
  TARGET_GID=$(id -g "$TARGET_USER" 2>/dev/null || id -g)

  echo "Mounting //$NAS_IP/$SMB_SHARE at $SMB_MOUNT_POINT..."
  $SUDO mount -t cifs "//$NAS_IP/$SMB_SHARE" "$SMB_MOUNT_POINT" \
    -o "credentials=$creds_file,uid=$TARGET_UID,gid=$TARGET_GID,file_mode=0755,dir_mode=0755"

  local fstab_line="//$NAS_IP/$SMB_SHARE  $SMB_MOUNT_POINT  cifs  credentials=$creds_file,uid=$TARGET_UID,gid=$TARGET_GID,file_mode=0755,dir_mode=0755,_netdev  0  0"
  if grep -qF "$SMB_MOUNT_POINT" /etc/fstab 2>/dev/null; then
    echo "fstab already has an entry for $SMB_MOUNT_POINT; skipping."
  else
    echo "$fstab_line" | $SUDO tee -a /etc/fstab > /dev/null
    echo "Added fstab entry for $SMB_MOUNT_POINT."
  fi

  NAS_EXTRA_HOSTS=$'    extra_hosts:\n      - "'"$NAS_HOSTNAME:$NAS_IP"$'"'
}

configure_ufw_media() {
  echo "Opening UFW port 443/tcp for nginx-media..."
  $SUDO apt-get install -y ufw

  local use_route=false
  if $SUDO grep -q "BEGIN UFW AND DOCKER" /etc/ufw/after.rules 2>/dev/null; then
    use_route=true
  fi

  $SUDO ufw allow 443/tcp
  if [[ "$use_route" == true ]]; then
    $SUDO ufw route allow proto tcp from any to any port 443
  fi

  $SUDO ufw reload
}

run_media_stack_setup() {
  echo "--- Media stack setup ---"

  read -r -p "Username that should own media service files (default: $TARGET_USER): " input_user
  TARGET_USER=${input_user:-$TARGET_USER}
  if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "User '$TARGET_USER' not found; continuing as current user '$(whoami)'."
    TARGET_USER="$(whoami)"
  fi

  local USER_HOME
  USER_HOME=$(eval echo "~$TARGET_USER")
  local STACK_DIR="$USER_HOME/media-stack"

  local TARGET_UID TARGET_GID
  TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || id -u)
  TARGET_GID=$(id -g "$TARGET_USER" 2>/dev/null || id -g)

  read -r -p "PUID for linuxserver containers (default: $TARGET_UID): " PUID
  PUID=${PUID:-$TARGET_UID}
  read -r -p "PGID for linuxserver containers (default: $TARGET_GID): " PGID
  PGID=${PGID:-$TARGET_GID}

  # Media path: SMB mount or manual path
  local MEDIA_VIDEOS_PATH="" NAS_EXTRA_HOSTS=""
  read -r -p "Set up SMB/CIFS network mount for media? (y/N): " DO_SMB
  if [[ "$DO_SMB" =~ ^[Yy]$ ]]; then
    setup_smb_mount
  else
    read -r -p "Path to videos directory on this host (e.g. /mnt/media/Videos): " MEDIA_VIDEOS_PATH
    if [[ -z "$MEDIA_VIDEOS_PATH" ]]; then
      echo "Videos path is required." >&2
      exit 1
    fi
    NAS_EXTRA_HOSTS=""
  fi

  # Domain and cert details
  read -r -p "Domain for Jellyfin HTTPS access (e.g. starlight.example.com): " MEDIA_DOMAIN
  if [[ -z "$MEDIA_DOMAIN" ]]; then
    echo "Domain is required." >&2
    exit 1
  fi

  read -r -p "Cloudflare API token for DNS-01 cert issuance: " CLOUDFLARE_API_TOKEN
  CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN:-"<token here>"}

  read -r -p "Contact email for certificates: " CERTBOT_EMAIL
  if [[ -z "$CERTBOT_EMAIL" ]]; then
    echo "Certbot email is required." >&2
    exit 1
  fi

  read -r -p "Open UFW port 443/tcp for nginx-media? (y/N): " DO_UFW_MEDIA
  if [[ "$DO_UFW_MEDIA" =~ ^[Yy]$ && -z "${SUDO+x}" ]]; then
    prompt_sudo
  elif [[ "$DO_UFW_MEDIA" =~ ^[Yy]$ ]]; then
    prompt_sudo
  fi
  init_setup_log "media-stack" "$TARGET_USER"
  append_setup_log "Target user: \`$TARGET_USER\`."
  append_setup_log "Stack directory: \`$STACK_DIR\`."
  append_setup_log "Media domain: \`$MEDIA_DOMAIN\`."
  append_setup_log "Videos path: \`$MEDIA_VIDEOS_PATH\`."
  append_setup_log "SMB mount selected: \`$DO_SMB\`."
  append_setup_log "UFW 443 selected: \`$DO_UFW_MEDIA\`."

  # Create directory structure
  local NGINX_DIR="$STACK_DIR/nginx"
  local HOST_SSL_DIR="$STACK_DIR/ssl"
  mkdir -p \
    "$STACK_DIR/jellyfin/config" \
    "$STACK_DIR/jellyfin/cache" \
    "$STACK_DIR/radarr/config" \
    "$STACK_DIR/sonarr/config" \
    "$STACK_DIR/prowlarr/config" \
    "$STACK_DIR/profilarr/config" \
    "$NGINX_DIR" \
    "$HOST_SSL_DIR"

  local MEDIA_TEMPLATE_DIR="$TEMPLATE_DIR/media-stack"

  # Render nginx.conf
  local NGINX_CONF_PATH="$NGINX_DIR/nginx.conf"
  render_template_file "$MEDIA_TEMPLATE_DIR/nginx/nginx.conf.template" \
    "$NGINX_CONF_PATH" \
    MEDIA_DOMAIN "$MEDIA_DOMAIN"

  # Render docker-compose.yml
  render_template_file "$MEDIA_TEMPLATE_DIR/docker-compose.yml.template" \
    "$STACK_DIR/docker-compose.yml" \
    JELLYFIN_CONFIG_DIR "$STACK_DIR/jellyfin/config" \
    JELLYFIN_CACHE_DIR  "$STACK_DIR/jellyfin/cache" \
    RADARR_CONFIG_DIR   "$STACK_DIR/radarr/config" \
    SONARR_CONFIG_DIR   "$STACK_DIR/sonarr/config" \
    PROWLARR_CONFIG_DIR "$STACK_DIR/prowlarr/config" \
    PROFILARR_CONFIG_DIR "$STACK_DIR/profilarr/config" \
    MEDIA_VIDEOS_PATH   "$MEDIA_VIDEOS_PATH" \
    PUID                "$PUID" \
    PGID                "$PGID" \
    RADARR_EXTRA_HOSTS  "$NAS_EXTRA_HOSTS" \
    SONARR_EXTRA_HOSTS  "$NAS_EXTRA_HOSTS" \
    CLOUDFLARE_API_TOKEN "$CLOUDFLARE_API_TOKEN" \
    CERTBOT_EMAIL       "$CERTBOT_EMAIL" \
    CERTBOT_DOMAIN      "$MEDIA_DOMAIN" \
    NGINX_CONF_PATH     "$NGINX_CONF_PATH" \
    HOST_SSL_DIR        "$HOST_SSL_DIR"

  if [[ -d "$STACK_DIR" ]]; then
    ${SUDO:-} chown -R "$TARGET_USER:$TARGET_USER" "$STACK_DIR"
  fi

  echo "Media stack files rendered under $STACK_DIR."
  append_setup_log "Rendered media stack compose: \`$STACK_DIR/docker-compose.yml\`."
  append_setup_log "Rendered nginx config: \`$NGINX_CONF_PATH\`."

  if [[ "$DO_UFW_MEDIA" =~ ^[Yy]$ ]]; then
    configure_ufw_media
    append_setup_log "Opened UFW port 443/tcp for nginx-media."
  fi

  echo "To launch: import $STACK_DIR/docker-compose.yml into Portainer as a stack."
  finish_setup_log
  echo "Media stack setup complete."
}

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  run_media_stack_setup "$@"
fi
