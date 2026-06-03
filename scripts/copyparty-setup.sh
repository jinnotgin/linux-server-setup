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

run_copyparty_setup() {
  echo "--- Copyparty setup ---"
  read -r -p "Username that should own Copyparty files (default: $TARGET_USER): " input_user
  TARGET_USER=${input_user:-$TARGET_USER}
  if ! id -u "$TARGET_USER" >/dev/null 2>&1; then
    echo "User '$TARGET_USER' not found; continuing as current user '$(whoami)'."
    TARGET_USER="$(whoami)"
  fi

  local USER_HOME
  USER_HOME=$(eval echo "~$TARGET_USER")
  STACK_DIR="$USER_HOME/copyparty-stack"
  local copyparty_dir="$STACK_DIR"
  mkdir -p "$copyparty_dir/cfg"

  read -r -p "Copyparty username: " COPYPARTY_USER
  read -r -p "Copyparty password (leave blank to auto-generate): " COPYPARTY_PASS
  if [[ -z "$COPYPARTY_PASS" ]]; then
    if command -v openssl >/dev/null 2>&1; then
      COPYPARTY_PASS=$(openssl rand -hex 12)
    else
      COPYPARTY_PASS=$(gen_uuid | tr -d '-')
    fi
  fi
  read -r -p "Copyparty data directory to share (default: $USER_HOME): " COPYPARTY_DATA_PATH
  COPYPARTY_DATA_PATH=${COPYPARTY_DATA_PATH:-$USER_HOME}

  render_template_file "$TEMPLATE_DIR/copyparty/copyparty.conf.template" \
    "$copyparty_dir/cfg/copyparty.conf" \
    COPYPARTY_USER "$COPYPARTY_USER" COPYPARTY_PASS "$COPYPARTY_PASS"
  render_template_file "$TEMPLATE_DIR/copyparty/docker-compose.yml.template" \
    "$copyparty_dir/docker-compose.yml" \
    COPYPARTY_CFG_PATH "$copyparty_dir/cfg" COPYPARTY_DATA_PATH "$COPYPARTY_DATA_PATH"

  printf "Copyparty on 3923\nUser: %s\nPassword: %s\nData dir: %s\n" \
    "$COPYPARTY_USER" "$COPYPARTY_PASS" "$COPYPARTY_DATA_PATH" > "$copyparty_dir/summary.txt"

  if [[ -d "$STACK_DIR" ]]; then
    ${SUDO:-} chown -R "$TARGET_USER:$TARGET_USER" "$STACK_DIR"
  fi

  echo "Copyparty files rendered under $STACK_DIR."
  echo "To launch: import $copyparty_dir/docker-compose.yml into Portainer as a stack."
  echo "Copyparty setup complete."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
  run_copyparty_setup "$@"
fi
