#!/usr/bin/env bash
set -euo pipefail

SETUP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=scripts/linux-server-setup.sh
source "$SETUP_DIR/scripts/linux-server-setup.sh"
# shellcheck source=scripts/docker-portainer-setup.sh
source "$SETUP_DIR/scripts/docker-portainer-setup.sh"
# shellcheck source=scripts/tunnel-stack-setup.sh
source "$SETUP_DIR/scripts/tunnel-stack-setup.sh"
# shellcheck source=scripts/copyparty-setup.sh
source "$SETUP_DIR/scripts/copyparty-setup.sh"
# shellcheck source=scripts/media-stack-setup.sh
source "$SETUP_DIR/scripts/media-stack-setup.sh"
# shellcheck source=scripts/healthcheck-setup.sh
source "$SETUP_DIR/scripts/healthcheck-setup.sh"

main() {
  echo "--- Linux server setup launcher ---"
  echo "1) General Linux server setup"
  echo "2) Docker + Portainer CE setup"
  echo "3) Copyparty setup"
  echo "4) Tunnel stack setup"
  echo "5) Media stack setup"
  echo "6) Host healthcheck setup"
  echo "7) Run all in order"
  read -r -p "Choose an option [1-7]: " choice

  case "$choice" in
    1) run_linux_server_setup ;;
    2) run_docker_portainer_setup ;;
    3) run_copyparty_setup ;;
    4) run_tunnel_stack_setup ;;
    5) run_media_stack_setup ;;
    6) run_healthcheck_setup ;;
    7)
      run_linux_server_setup
      run_docker_portainer_setup
      run_copyparty_setup
      run_tunnel_stack_setup
      run_media_stack_setup
      ;;
    *)
      echo "Invalid choice. Use 1, 2, 3, 4, 5, 6, or 7." >&2
      exit 1
      ;;
  esac
}

main "$@"
