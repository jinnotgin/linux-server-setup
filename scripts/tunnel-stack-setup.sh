#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/common.sh
source "$SCRIPT_DIR/common.sh"
TUNNEL_STACK_RENDERED=0

render_template() {
  local src="$1"
  shift
  if (( $# % 2 != 0 )); then
    echo "render_template received an odd number of key/value args" >&2
    return 1
  fi
  python3 - "$src" "$@" <<'PY'
import sys
src, *pairs = sys.argv[1:]
data = open(src, encoding="utf-8").read()
if len(pairs) % 2:
    sys.exit("Odd number of key/value args")
for i in range(0, len(pairs), 2):
    key, val = pairs[i], pairs[i+1]
    data = data.replace(f"{{{{{key}}}}}", val)
print(data, end="")
PY
}
render_template_file() {
  local src="$1" dest="$2"
  shift 2
  render_template "$src" "$@" > "$dest"
}
read_snippet() {
  local path="$1"
  if [[ -f "$path" ]]; then
    cat "$path"
  fi
}
collect_domains_with_roles() {
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

  if [[ ${#domains[@]} -eq 1 ]]; then
    local choice
    read -r -p "Single domain '${domains[0]}' detected. Use it for CDN (VLESS+WS via Cloudflare) or Direct (Hysteria2 + Vision + XHTTP Reality)? [cdn/direct]: " choice
    case "$choice" in
      [Cc][Dd][Nn]|"") CDN_DOMAIN="${domains[0]}"; DIRECT_DOMAIN="";;
      [Dd][Ii][Rr][Ee][Cc][Tt]) DIRECT_DOMAIN="${domains[0]}"; CDN_DOMAIN="";;
      *) echo "Invalid choice. Use 'cdn' or 'direct'." >&2; exit 1;;
    esac
  else
    echo "You entered: ${domains[*]}"
    read -r -p "Pick the CDN domain for VLESS+WS (Cloudflare-friendly). Leave blank to skip CDN: " CDN_DOMAIN
    read -r -p "Pick the Direct domain for Hysteria2 + Vision + XHTTP Reality (no CDN). Leave blank to skip direct: " DIRECT_DOMAIN

    if [[ -n "$CDN_DOMAIN" && ! " ${domains[*]} " =~ " ${CDN_DOMAIN} " ]]; then
      echo "CDN domain '$CDN_DOMAIN' not in provided list." >&2
      exit 1
    fi
    if [[ -n "$DIRECT_DOMAIN" && ! " ${domains[*]} " =~ " ${DIRECT_DOMAIN} " ]]; then
      echo "Direct domain '$DIRECT_DOMAIN' not in provided list." >&2
      exit 1
    fi
  fi

  if [[ -z "${CDN_DOMAIN:-}" && -z "${DIRECT_DOMAIN:-}" ]]; then
    echo "At least one role (CDN or Direct) must be selected." >&2
    exit 1
  fi

  DOMAINS_ARRAY=()
  [[ -n "${CDN_DOMAIN:-}" ]] && DOMAINS_ARRAY+=("$CDN_DOMAIN")
  if [[ -n "${DIRECT_DOMAIN:-}" && "$DIRECT_DOMAIN" != "$CDN_DOMAIN" ]]; then
    DOMAINS_ARRAY+=("$DIRECT_DOMAIN")
  fi
  DOMAINS_ARGS="${DOMAINS_ARRAY[*]/#/-d }"
  DOMAINS_CSV="$(IFS=','; echo "${DOMAINS_ARRAY[*]}")"
  PRIMARY_DOMAIN="${CDN_DOMAIN:-$DIRECT_DOMAIN}"
  CERT_BASE_DOMAIN="${DOMAINS_ARRAY[0]}"
}
generate_vless_clients() {
  local label="$1" flow="$2" out_var="$3" ids_out_var="$4"
  local count
  read -r -p "How many VLESS accounts for ${label}? " count
  [[ -z "$count" ]] && count=1
  local clients=() ids=()
  for ((i=1; i<=count; i++)); do
    local uuid
    uuid=$(gen_uuid)
    clients+=("{\"id\":\"$uuid\"${flow:+,\"flow\":\"$flow\"}}")
    ids+=("$uuid")
  done
  printf -v "$out_var" "[%s]" "$(IFS=,; echo "${clients[*]}")"
  printf -v "$ids_out_var" "%s" "$(IFS=', '; echo "${ids[*]}")"
}
generate_hysteria_password() {
  if command -v openssl >/dev/null 2>&1; then
    HYSTERIA_PASSWORD=$(openssl rand -hex 12)
  else
    HYSTERIA_PASSWORD=$(gen_uuid | tr -d '-')
  fi
}
generate_reality_keys() {
  local priv="" pub=""
  REALITY_HAS_KEYS=false

  # helper: run a command that outputs x25519 keys and parse fields (newer Xray uses Password as public key)
  parse_keys() {
    local output="$1" p pb
    p=$(echo "$output" | awk -F': *' '/PrivateKey|Private key/ {print $2; exit}')
    pb=$(echo "$output" | awk -F': *' '/PublicKey|Public key|Password/ {print $2; exit}')
    echo "$p" "$pb"
  }

  # Try docker-based xray
  if command -v docker >/dev/null 2>&1; then
    # Newer images support bare `x25519`; fall back to `xray x25519`
    if output=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 2>/dev/null); then
      read -r priv pub <<<"$(parse_keys "$output")"
    elif output=$(docker run --rm ghcr.io/xtls/xray-core:latest xray x25519 2>/dev/null); then
      read -r priv pub <<<"$(parse_keys "$output")"
    fi
    if [[ -n "$priv" && -z "$pub" ]]; then
      pub=$(docker run --rm ghcr.io/xtls/xray-core:latest x25519 -i "$priv" 2>/dev/null | awk -F': *' '/PublicKey|Public key|Password/ {print $2; exit}')
      if [[ -z "$pub" ]]; then
        pub=$(docker run --rm ghcr.io/xtls/xray-core:latest xray x25519 -i "$priv" 2>/dev/null | awk -F': *' '/PublicKey|Public key|Password/ {print $2; exit}')
      fi
    fi
    if [[ -n "$priv" && -n "$pub" ]]; then
      REALITY_HAS_KEYS=true
    fi
  fi

  if [[ $REALITY_HAS_KEYS == false ]]; then
    priv=${priv:-"REPLACE_WITH_PRIVATE_KEY"}
    pub=${pub:-"REPLACE_WITH_PUBLIC_KEY"}
  fi

  REALITY_PRIVATE_KEY="$priv"
  REALITY_PUBLIC_KEY="$pub"
}
ensure_proxy_network() {
  local net="proxy_net"
  if command -v docker >/dev/null 2>&1 && ! docker network inspect "$net" >/dev/null 2>&1; then
    echo "Creating shared proxy network '$net' for Nginx/Xray interop..."
    $SUDO docker network create "$net"
  fi
}
seed_nginx_site() {
  local dest="$1"
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
    <p>This is a placeholder page. Swap in your own files under <code>~/tunnel-stack/nginx/www</code> when you're ready.</p>
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

  local USER_HOME
  USER_HOME=$(eval echo "~$TARGET_USER")
  STACK_DIR="$USER_HOME/tunnel-stack"
  mkdir -p "$STACK_DIR"
  local TARGET_UID TARGET_GID
  TARGET_UID=$(id -u "$TARGET_USER" 2>/dev/null || id -u)
  TARGET_GID=$(id -g "$TARGET_USER" 2>/dev/null || id -g)
  echo "Collecting domain information (supports multiple domains)..."
  collect_domains_with_roles
  read -r -p "Contact email for certificates (used by Certbot/Nginx): " CERT_EMAIL
  read -r -p "Cloudflare API token for DNS-01 certificate issuance (leave blank to write placeholder): " CLOUDFLARE_API_TOKEN
  CLOUDFLARE_API_TOKEN=${CLOUDFLARE_API_TOKEN:-"<token here>"}

  local generated_at
  generated_at=$(date -Iseconds)
  local cdn_section="" direct_section="" warp_section=""
  local files_rows=""
  local README_TEMPLATE_DIR="$TEMPLATE_DIR/tunnel-stack/readme"


  local render_cdn="n" render_direct="n"
  if [[ -n "${CDN_DOMAIN:-}" ]]; then
    read -r -p "Generate CDN VLESS+WS stack for $CDN_DOMAIN (Cloudflare-friendly)? (y/N): " render_cdn
  fi
  if [[ -n "${DIRECT_DOMAIN:-}" ]]; then
    read -r -p "Generate Direct stack (Hysteria2 + Vision + XHTTP Reality) for $DIRECT_DOMAIN? (y/N): " render_direct
  fi
  read -r -p "Generate Cloudflare WARP SOCKS5/HTTP proxy? (y/N): " render_warp
  local render_warp_variants="n"
  if [[ "$render_warp" =~ ^[Yy]$ ]]; then
    read -r -p "Also render WARP variants (direct + WARP endpoints) for proxy stacks? (y/N): " render_warp_variants
  fi
  local SNIPPET_DIR="$TEMPLATE_DIR/snippets"

  if [[ ! "$render_cdn" =~ ^[Yy]$ && ! "$render_direct" =~ ^[Yy]$ && ! "$render_warp" =~ ^[Yy]$ ]]; then
    echo "No stacks selected for rendering."
    return
  fi

  local SSL_DIR="$STACK_DIR/ssl"
  mkdir -p "$SSL_DIR" "$SSL_DIR/logs"
  local final_compose="$STACK_DIR/docker-compose.yml"
  local COMPOSE_TEMPLATE_DIR="$TEMPLATE_DIR/tunnel-stack"
  local SERVICE_TEMPLATE_DIR="$COMPOSE_TEMPLATE_DIR/services"
  local compose_services=""

  # Certificate renewal (covers all selected domains) via Cloudflare DNS-01.
  compose_services+=$(render_template "$SERVICE_TEMPLATE_DIR/certbot.yml.template" \
    HOST_SSL_DIR "$SSL_DIR" \
    CLOUDFLARE_API_TOKEN "$CLOUDFLARE_API_TOKEN" \
    CERT_EMAIL "$CERT_EMAIL" \
    DOMAINS_CSV "$DOMAINS_CSV" \
    CERT_BASE_DOMAIN "$CERT_BASE_DOMAIN")
  compose_services+=$'\n\n'

  # CDN / VLESS over WS (Cloudflare OK)
  if [[ "$render_cdn" =~ ^[Yy]$ ]]; then
    local tls_cert_cdn="/certs/live/${CERT_BASE_DOMAIN}/fullchain.pem"
    local tls_key_cdn="/certs/live/${CERT_BASE_DOMAIN}/privkey.pem"
    read -r -p "Path to TLS certificate for CDN domain (default inside container: $tls_cert_cdn; host dir: $SSL_DIR): " input_cert
    read -r -p "Path to TLS private key for CDN domain (default inside container: $tls_key_cdn; host dir: $SSL_DIR): " input_key
    tls_cert_cdn=${input_cert:-$tls_cert_cdn}
    tls_key_cdn=${input_key:-$tls_key_cdn}

    generate_vless_clients "VLESS over WebSocket" "" VLESS_WS_CLIENTS VLESS_WS_IDS
    local nginx_dir="$STACK_DIR/nginx"
    local vless_cdn_dir="$STACK_DIR/vless-cdn"
    mkdir -p "$nginx_dir" "$vless_cdn_dir"

    local ws_warp_inbound="" warp_outbound="" routing_block="" ws_offset_location=""
    if [[ "$render_warp_variants" =~ ^[Yy]$ ]]; then
      ws_warp_inbound=$(read_snippet "$SNIPPET_DIR/vless-cdn-ws-warp-inbound.json")
      warp_outbound=$(read_snippet "$SNIPPET_DIR/vless-warp-outbound.json")
      routing_block=$(read_snippet "$SNIPPET_DIR/vless-cdn-routing.json")
      ws_offset_location=$'\n'"$(read_snippet "$SNIPPET_DIR/nginx-ws-offset-location.conf")"$'\n'
    fi

    local nginx_port="6443"

    seed_nginx_site "$nginx_dir/www"
    render_template_file "$TEMPLATE_DIR/nginx/nginx.conf.template" \
      "$nginx_dir/nginx.conf" \
      WS_OFFSET_LOCATION "$ws_offset_location" \
      PRIMARY_DOMAIN "$CDN_DOMAIN" TLS_CERT_PATH "$tls_cert_cdn" TLS_KEY_PATH "$tls_key_cdn" \
      VLESS_UPSTREAM "vless-cdn:10000" VLESS_WARP_UPSTREAM "vless-cdn:10001" NGINX_HTTPS_PORT "$nginx_port"
    compose_services+=$(render_template "$SERVICE_TEMPLATE_DIR/cdn-proxy.yml.template" \
      NGINX_HTTPS_PORT "$nginx_port" \
      NGINX_CONF_PATH "$nginx_dir/nginx.conf" \
      HOST_SSL_DIR "$SSL_DIR" \
      NGINX_WWW_PATH "$nginx_dir/www")
    compose_services+=$'\n\n'

    # IMPORTANT: Snippet placeholders (WS_WARP_INBOUND, WARP_OUTBOUND, ROUTING_BLOCK)
    # must come FIRST so that placeholders inside the snippets (like VLESS_CLIENTS)
    # get replaced in subsequent passes.
    render_template_file "$TEMPLATE_DIR/vless-cdn/config.json.template" \
      "$vless_cdn_dir/config.json" \
      WS_WARP_INBOUND "$ws_warp_inbound" \
      WARP_OUTBOUND "$warp_outbound" \
      ROUTING_BLOCK "$routing_block" \
      PRIMARY_DOMAIN "$CDN_DOMAIN" VLESS_CLIENTS "$VLESS_WS_CLIENTS"
    compose_services+=$(render_template "$SERVICE_TEMPLATE_DIR/vless-cdn.yml.template" \
      VLESS_CDN_CONFIG_PATH "$vless_cdn_dir/config.json")
    compose_services+=$'\n\n'

    local cdn_warp_section="" cdn_std_heading=""
    if [[ "$render_warp_variants" =~ ^[Yy]$ ]]; then
      cdn_std_heading=$'### Standard\n\n'
      cdn_warp_section="### With WARP egress

Same UUIDs and port. Outbound traffic from the server routes through Cloudflare
WARP before reaching the internet — only the WebSocket path differs.

| Field | Value |
|-------|-------|
| Domain | \`$CDN_DOMAIN\` |
| Port | \`$nginx_port\` |
| Network | WebSocket (\`ws\`) |
| Path | \`/ws-offset\` |
| TLS | enabled |
| Protocol | VLESS |
| UUIDs | \`$VLESS_WS_IDS\` |

"
    fi
    cdn_section=$(render_template "$README_TEMPLATE_DIR/cdn-section.md.template" \
      CDN_DOMAIN "$CDN_DOMAIN" \
      NGINX_HTTPS_PORT "$nginx_port" \
      VLESS_WS_IDS "$VLESS_WS_IDS" \
      CDN_STD_HEADING "$cdn_std_heading" \
      CDN_WARP_SECTION "$cdn_warp_section" \
      TLS_CERT_CDN "$tls_cert_cdn" \
      TLS_KEY_CDN "$tls_key_cdn")
    files_rows+="| \`nginx/nginx.conf\` | Nginx reverse-proxy config for CDN stack |"$'\n'
    files_rows+="| \`vless-cdn/config.json\` | Xray config for VLESS-over-WebSocket |"$'\n'
  fi

  # Direct stack: Hysteria2 + Vision + XHTTP Reality (no CDN)
  if [[ "$render_direct" =~ ^[Yy]$ ]]; then
    local tls_cert_direct="/certs/live/${CERT_BASE_DOMAIN}/fullchain.pem"
    local tls_key_direct="/certs/live/${CERT_BASE_DOMAIN}/privkey.pem"
    read -r -p "Path to TLS certificate for Direct domain (default inside container: $tls_cert_direct; host dir: $SSL_DIR): " input_cert_d
    read -r -p "Path to TLS private key for Direct domain (default inside container: $tls_key_direct; host dir: $SSL_DIR): " input_key_d
    tls_cert_direct=${input_cert_d:-$tls_cert_direct}
    tls_key_direct=${input_key_d:-$tls_key_direct}

    generate_vless_clients "VLESS Vision (XTLS)" "xtls-rprx-vision" VISION_CLIENTS VISION_IDS
    generate_vless_clients "VLESS XHTTP Reality" "xtls-rprx-vision" REALITY_CLIENTS REALITY_IDS
    generate_hysteria_password
    local enable_warp_variants="$([[ "$render_warp_variants" =~ ^[Yy]$ ]] && echo "1" || echo "0")"

    read -r -p "XHTTP path (default: /somepath): " XHTTP_PATH
    XHTTP_PATH=${XHTTP_PATH:-/somepath}
    read -r -p "Reality target (default: microsoft.com:443): " REALITY_TARGET
    REALITY_TARGET=${REALITY_TARGET:-microsoft.com:443}
    read -r -p "Reality SNI server names (comma-separated, default: www.microsoft.com,microsoft.com): " REALITY_SNI_INPUT
    REALITY_SNI_INPUT=${REALITY_SNI_INPUT:-www.microsoft.com,microsoft.com}
    IFS=',' read -r -a sni_arr <<< "$REALITY_SNI_INPUT"
    local sni_json="["
    for host in "${sni_arr[@]}"; do
      sni_json+="\"${host}\","
    done
    sni_json="${sni_json%,}]"

    read -r -p "How many Reality short IDs to auto-generate? (default: 2) " REALITY_SHORT_COUNT
    REALITY_SHORT_COUNT=${REALITY_SHORT_COUNT:-2}
    local sid_json="["
    REALITY_SHORT_LIST=()
    for ((i=1; i<=REALITY_SHORT_COUNT; i++)); do
      sid=$(gen_short_id)
      REALITY_SHORT_LIST+=("$sid")
      sid_json+="\"${sid}\","
    done
    sid_json="${sid_json%,}]"

    generate_reality_keys
    read -r -p "Reality private key (leave blank to use generated): " input_priv
    read -r -p "Reality public key (leave blank to use generated): " input_pub
    local reality_priv reality_pub
    reality_priv=${input_priv:-$REALITY_PRIVATE_KEY}
    reality_pub=${input_pub:-$REALITY_PUBLIC_KEY}
    local reality_keys_file="$STACK_DIR/reality-keys.txt"
    printf "Reality private key: %s\nReality public key: %s\n" "$reality_priv" "$reality_pub" > "$reality_keys_file"

    # Gateway for SNI routing + fallback site
    local gateway_dir="$STACK_DIR/gateway"
    mkdir -p "$gateway_dir"
    seed_nginx_site "$gateway_dir/www"

    local cdn_map_entry="# CDN domain not configured"
    local cdn_upstream="# No CDN upstream configured"
    local vless_direct_host="vless-direct"
    local cdn_upstream_host="cdn-proxy"

    if [[ "$render_cdn" =~ ^[Yy]$ ]]; then
      cdn_map_entry="$CDN_DOMAIN cdn;"
      cdn_upstream="upstream cdn { server ${cdn_upstream_host}:6443; }"
    fi

    render_template_file "$TEMPLATE_DIR/gateway/nginx.conf.template" \
      "$gateway_dir/nginx.conf" \
      CDN_MAP_ENTRY "$cdn_map_entry" CDN_UPSTREAM_BLOCK "$cdn_upstream" DIRECT_DOMAIN "$DIRECT_DOMAIN" VLESS_DIRECT_HOST "$vless_direct_host" GATEWAY_LISTEN_PORT "2053"
    compose_services+=$(render_template "$SERVICE_TEMPLATE_DIR/gateway-router.yml.template" \
      GATEWAY_PORT "2053" \
      GATEWAY_CONF_PATH "$gateway_dir/nginx.conf" \
      GATEWAY_WWW_PATH "$gateway_dir/www")
    compose_services+=$'\n\n'

    # VLESS direct (Vision + XHTTP Reality)
    local vless_direct_dir="$STACK_DIR/vless-direct"
    mkdir -p "$vless_direct_dir"
    local vision_warp_inbound="" reality_warp_inbound="" warp_outbound="" routing_block="" warp_port_bindings=""
    if [[ "$enable_warp_variants" == "1" ]]; then
      vision_warp_inbound=$(read_snippet "$SNIPPET_DIR/vless-direct-vision-warp.json")
      reality_warp_inbound=$(read_snippet "$SNIPPET_DIR/vless-direct-reality-warp.json")
      warp_outbound=$(read_snippet "$SNIPPET_DIR/vless-warp-outbound.json")
      routing_block=$(read_snippet "$SNIPPET_DIR/vless-direct-routing.json")
      warp_port_bindings=$'\n'"$(read_snippet "$SNIPPET_DIR/vless-direct-warp-ports.yml")"
    fi

    # IMPORTANT: Snippet placeholders must come FIRST so their internal placeholders
    # (VISION_CLIENTS, REALITY_CLIENTS, DIRECT_TLS_CERT, etc.) get replaced afterward.
    render_template_file "$TEMPLATE_DIR/vless-direct/config.json.template" \
      "$vless_direct_dir/config.json" \
      VISION_WARP_INBOUND "$vision_warp_inbound" \
      REALITY_WARP_INBOUND "$reality_warp_inbound" \
      WARP_OUTBOUND "$warp_outbound" \
      ROUTING_BLOCK "$routing_block" \
      VISION_CLIENTS "$VISION_CLIENTS" \
      REALITY_CLIENTS "$REALITY_CLIENTS" \
      XHTTP_PATH "$XHTTP_PATH" \
      REALITY_TARGET "$REALITY_TARGET" \
      REALITY_SERVERNAMES "$sni_json" \
      REALITY_PRIVATE_KEY "$reality_priv" \
      REALITY_SHORT_IDS "$sid_json" \
      DIRECT_TLS_CERT "$tls_cert_direct" \
      DIRECT_TLS_KEY "$tls_key_direct" \
      FALLBACK_DEST "gateway-router:20002"
    compose_services+=$(render_template "$SERVICE_TEMPLATE_DIR/vless-direct.yml.template" \
      VLESS_DIRECT_CONFIG_PATH "$vless_direct_dir/config.json" \
      HOST_SSL_DIR "$SSL_DIR" \
      WARP_PORT_BINDINGS "$warp_port_bindings")
    compose_services+=$'\n\n'

    # Hysteria2 (direct)
    local hysteria_dir="$STACK_DIR/hysteria2"
    mkdir -p "$hysteria_dir"
    read -r -p "Masquerade site for Hysteria2 (default: https://news.ycombinator.com): " MASQ
    MASQ=${MASQ:-https://news.ycombinator.com}
    local hysteria_warp_service="" hysteria_warp_config_path=""
    if [[ "$enable_warp_variants" == "1" ]]; then
      hysteria_warp_config_path="$hysteria_dir/hysteria-warp.yaml"
      render_template_file "$TEMPLATE_DIR/hysteria2/hysteria-warp.yaml.template" \
        "$hysteria_warp_config_path" \
        PRIMARY_DOMAIN "$DIRECT_DOMAIN" HYSTERIA_PASSWORD "$HYSTERIA_PASSWORD" TLS_CERT "$tls_cert_direct" TLS_KEY "$tls_key_direct" MASQUERADE "$MASQ"
      hysteria_warp_service=$(render_template "$SERVICE_TEMPLATE_DIR/hysteria2-warp.yml.template" \
        HYSTERIA_WARP_CONFIG_PATH "$hysteria_warp_config_path" \
        HOST_SSL_DIR "$SSL_DIR")
    fi
    render_template_file "$TEMPLATE_DIR/hysteria2/hysteria.yaml.template" \
      "$hysteria_dir/hysteria.yaml" \
      PRIMARY_DOMAIN "$DIRECT_DOMAIN" HYSTERIA_PASSWORD "$HYSTERIA_PASSWORD" TLS_CERT "$tls_cert_direct" TLS_KEY "$tls_key_direct" MASQUERADE "$MASQ"
    compose_services+=$(render_template "$SERVICE_TEMPLATE_DIR/hysteria2.yml.template" \
      HYSTERIA_CONFIG_PATH "$hysteria_dir/hysteria.yaml" \
      HOST_SSL_DIR "$SSL_DIR")
    if [[ -n "$hysteria_warp_service" ]]; then
      compose_services+=$'\n\n'"$hysteria_warp_service"
    fi
    compose_services+=$'\n\n'

    local reality_pub_display
    if [[ "$reality_pub" == "REPLACE_WITH_PUBLIC_KEY" ]]; then
      reality_pub_display="**NOT GENERATED** — install Docker and run: \`docker run --rm ghcr.io/xtls/xray-core:latest x25519\`"
    else
      reality_pub_display="\`$reality_pub\`"
    fi
    local hysteria_warp_section="" vision_warp_section="" reality_warp_section=""
    local hysteria_std_heading="" vision_std_heading="" reality_std_heading=""
    if [[ "$enable_warp_variants" == "1" ]]; then
      hysteria_std_heading=$'#### Standard\n\n'
      vision_std_heading=$'##### Standard\n\n'
      reality_std_heading=$'##### Standard\n\n'
      hysteria_warp_section="#### With WARP egress

Outbound traffic from the server routes through Cloudflare WARP before reaching
the internet — otherwise identical to the standard variant above.

| Field | Value |
|-------|-------|
| Domain | \`$DIRECT_DOMAIN\` |
| Port | \`8443 UDP/TCP\` |
| Password | \`$HYSTERIA_PASSWORD\` |
| Masquerade site | \`$MASQ\` |

"
      vision_warp_section="##### With WARP egress

Outbound traffic from the server routes through Cloudflare WARP. Same UUIDs and
connection parameters — only the port differs.

| Field | Value |
|-------|-------|
| Domain / SNI | \`$DIRECT_DOMAIN\` |
| Port | \`20011\` (direct, bypasses gateway) |
| Protocol | VLESS |
| Flow | \`xtls-rprx-vision\` |
| UUIDs | \`$VISION_IDS\` |

"
      reality_warp_section="##### With WARP egress

Outbound traffic from the server routes through Cloudflare WARP. Same UUIDs,
keys, and short IDs — only the port differs.

| Field | Value |
|-------|-------|
| Port | \`30011\` (direct, bypasses gateway) |
| Network | XHTTP |
| Path | \`$XHTTP_PATH\` |
| Reality target | \`$REALITY_TARGET\` |
| SNI / server names | \`$REALITY_SNI_INPUT\` |
| Public key | \`$reality_pub_display\` |
| Short IDs | \`$(IFS=', '; echo "${REALITY_SHORT_LIST[*]}")\` |
| Protocol | VLESS |
| Flow | \`xtls-rprx-vision\` |
| UUIDs | \`$REALITY_IDS\` |

"
    fi
    direct_section=$(render_template "$README_TEMPLATE_DIR/direct-section.md.template" \
      DIRECT_DOMAIN "$DIRECT_DOMAIN" \
      STACK_DIR "$STACK_DIR" \
      HYSTERIA_PASSWORD "$HYSTERIA_PASSWORD" \
      MASQ "$MASQ" \
      HYSTERIA_STD_HEADING "$hysteria_std_heading" \
      HYSTERIA_WARP_SECTION "$hysteria_warp_section" \
      VISION_IDS "$VISION_IDS" \
      VISION_STD_HEADING "$vision_std_heading" \
      VISION_WARP_SECTION "$vision_warp_section" \
      XHTTP_PATH "$XHTTP_PATH" \
      REALITY_TARGET "$REALITY_TARGET" \
      REALITY_SNI_INPUT "$REALITY_SNI_INPUT" \
      REALITY_PUB_KEY "$reality_pub_display" \
      REALITY_SHORT_IDS_CSV "$(IFS=', '; echo "${REALITY_SHORT_LIST[*]}")" \
      REALITY_IDS "$REALITY_IDS" \
      REALITY_STD_HEADING "$reality_std_heading" \
      REALITY_WARP_SECTION "$reality_warp_section" \
      TLS_CERT_DIRECT "$tls_cert_direct" \
      TLS_KEY_DIRECT "$tls_key_direct")
    files_rows+="| \`gateway/nginx.conf\` | Nginx SNI-routing gateway config |"$'\n'
    files_rows+="| \`vless-direct/config.json\` | Xray config for Vision + XHTTP Reality |"$'\n'
    files_rows+="| \`hysteria2/hysteria.yaml\` | Hysteria2 server config |"$'\n'
    files_rows+="| \`reality-keys.txt\` | Reality keypair (private + public) — keep secret |"$'\n'
    if [[ "$enable_warp_variants" == "1" ]]; then
      files_rows+="| \`hysteria2/hysteria-warp.yaml\` | Hysteria2 config with WARP egress |"$'\n'
    fi
  fi

  # Cloudflare WARP proxy (SOCKS5/HTTP with UDP relay)
  if [[ "$render_warp" =~ ^[Yy]$ ]]; then
    local warp_dir="$STACK_DIR/warp"
    mkdir -p "$warp_dir/data"
    compose_services+=$(render_template "$SERVICE_TEMPLATE_DIR/warp.yml.template" \
      WARP_DATA_PATH "$warp_dir/data")
    compose_services+=$'\n\n'
    warp_section=$(render_template "$README_TEMPLATE_DIR/warp-section.md.template" \
      WARP_DATA_DIR "$warp_dir/data")
    files_rows+="| \`warp/data/\` | Cloudflare WARP persistent data |"$'\n'
  fi

  render_template_file "$COMPOSE_TEMPLATE_DIR/docker-compose.yml.template" \
    "$final_compose" \
    SERVICE_BLOCKS "${compose_services%$'\n'}"
  COMPOSE_OUTPUTS=("$final_compose")

  local readme_file="$STACK_DIR/README.md"
  render_template_file "$README_TEMPLATE_DIR/README.md.template" \
    "$readme_file" \
    GENERATED_AT "$generated_at" \
    STACK_DIR "$STACK_DIR" \
    CDN_SECTION "$cdn_section" \
    DIRECT_SECTION "$direct_section" \
    WARP_SECTION "$warp_section" \
    SSL_DIR "$SSL_DIR" \
    DOMAINS_CSV "$DOMAINS_CSV" \
    CERT_EMAIL "$CERT_EMAIL" \
    CLOUDFLARE_API_TOKEN "$CLOUDFLARE_API_TOKEN" \
    FILES_ROWS "$files_rows"
  echo "Wrote client README to $readme_file"

  if [[ -d "$STACK_DIR" ]]; then
    ${SUDO:-} chown -R "$TARGET_USER:$TARGET_USER" "$STACK_DIR"
  fi

  echo "Rendered Portainer-ready tunnel compose: $final_compose"
  echo "The compose expects an existing Docker network named proxy_net."
  TUNNEL_STACK_RENDERED=1
}

configure_ufw_tunnel() {
  echo "Opening UFW ports for tunnel stack..."
  $SUDO apt-get install -y ufw

  local use_route=false
  if $SUDO grep -q "BEGIN UFW AND DOCKER" /etc/ufw/after.rules 2>/dev/null; then
    use_route=true
  fi

  _open_port() {
    local proto="$1" port="$2"
    $SUDO ufw allow "$port/$proto"
    if [[ "$use_route" == true ]]; then
      $SUDO ufw route allow proto "$proto" from any to any port "$port"
    fi
  }

  # 2053/tcp: gateway router (SNI routing + fallback)
  _open_port tcp 2053
  # 6443/tcp: CDN proxy (Nginx HTTPS for VLESS+WS)
  _open_port tcp 6443
  # 8443/tcp+udp: Hysteria2 WARP variant
  _open_port tcp 8443
  _open_port udp 8443
  # 8444/tcp+udp: Hysteria2 standard
  _open_port tcp 8444
  _open_port udp 8444
  # 20011/tcp: VLESS Vision WARP direct (bypasses gateway)
  _open_port tcp 20011
  # 30011/tcp: VLESS Reality WARP direct (bypasses gateway)
  _open_port tcp 30011

  $SUDO ufw reload
}

run_tunnel_stack_setup() {
  echo "--- Tunnel stack setup ---"
  read -r -p "Username that should own rendered stacks (default: $TARGET_USER): " input_user
  TARGET_USER=${input_user:-$TARGET_USER}
  if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "User '$TARGET_USER' not found; continuing as current user '$(whoami)'."
    TARGET_USER="$(whoami)"
  fi

  if ! command -v docker >/dev/null 2>&1; then
    echo "Docker was not found. You can still render stack files, but run scripts/docker-portainer-setup.sh before launching them."
  fi

  read -r -p "Open UFW ports for tunnel stack (2053, 6443, 8443, 8444, 20011, 30011)? (y/N): " DO_UFW_TUNNEL

  if [[ "$DO_UFW_TUNNEL" =~ ^[Yy]$ ]]; then
    prompt_sudo
  fi

  init_setup_log "tunnel-stack" "$TARGET_USER"
  append_setup_log "UFW tunnel ports selected: \`$DO_UFW_TUNNEL\`."
  TUNNEL_STACK_RENDERED=0
  render_templates
  if [[ "$TUNNEL_STACK_RENDERED" == "1" ]]; then
    append_setup_log "Rendered tunnel stack files under \`$STACK_DIR\`."
    append_setup_log "Docker compose file: \`$STACK_DIR/docker-compose.yml\`."
    append_setup_log "Client README: \`$STACK_DIR/README.md\`."
  else
    append_setup_log "No tunnel stack files rendered because no stack components were selected."
  fi

  if [[ "$DO_UFW_TUNNEL" =~ ^[Yy]$ ]]; then
    configure_ufw_tunnel
    append_setup_log "Opened UFW ports for tunnel stack."
  fi

  finish_setup_log
  echo "Tunnel stack setup complete."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_tunnel_stack_setup "$@"
fi
