# Linux Server Bootstrap (SSH hardening, Docker, Portainer, templates)

`setup.sh` is an interactive bootstrap script for Ubuntu/Debian-like hosts. It focuses on SSH/root hardening, Docker/Portainer installation, daily backups to Google Drive via `rclone`, and optional rendering of ready-made Docker Compose templates (Certbot renewal, Nginx reverse proxy, VLESS over WebSocket, VLESS Vision + VLESS XHTTP Reality, and Hysteria2). You can run only the parts you want (e.g., skip hardening/install and just render templates).

## Domain roles (Cloudflare vs direct)
- Provide one or two domains. With one domain, pick a mode: **CDN** (Cloudflare OK) for VLESS over WebSocket only, or **Direct** (no CDN) for Hysteria2 + VLESS Vision + VLESS XHTTP Reality.
- With two domains, assign one as the **CDN domain** (VLESS+WS only) and one as the **Direct domain** (Hysteria2 + Vision + XHTTP Reality). Certbot is configured for all selected domains.

## What the script does
- Requests sudo at the start when privileged steps are selected.
- (Optional) Updates packages and sets locale to `en_US.UTF-8` and timezone to `Asia/Singapore`.
- (Optional) Hardens SSH: disables root login and password authentication, forces protocol 2, and restarts `sshd`.
- Prompts for a username to create/ensure sudo access and docker group membership (password is requested when the user is created).
- (Optional) Installs Docker Engine + Compose plugin and deploys Portainer (`portainer/portainer-ce`) on ports `8000` and `9443` using the `portainer_data` volume.
- (Optional) Installs `rclone`, optionally configures a Google Drive remote using a service account JSON, and sets up a daily Portainer backup (local archive + optional Drive upload) with systemd service/timer.
  - You can paste the service account JSON interactively; it is saved under the selected user’s home directory with correct ownership.
- (Optional) Installs Tailscale, enables SSH + exit-node advertising, and optionally brings it up with your provided auth key.
- Optionally renders Docker Compose templates with your inputs (domain/email/UUIDs/TLS paths) into the `generated/` folder, and can start the stacks right after rendering if Docker is present.

## Usage
```bash
git clone https://github.com/jinnotgin/linux-server-setup.git
cd linux-server-setup
chmod +x setup.sh
./setup.sh
```
Run as root or a sudo-capable user. The script will prompt for:
- Which sections to run (system prep, hardening, Docker/Portainer, backups, template rendering).
- Sudo password (if needed).
- The username to create/ensure, and a password if the user is being created.
- Optional Google Drive service account JSON path for automated `rclone` configuration.
- Domain names, email, UUIDs, and other template parameters if you choose to render templates.

> Re-login after the script finishes so the chosen user picks up new group memberships (sudo/docker).

## Portainer backup & restore
See [`docs/portainer-backup.md`](docs/portainer-backup.md) for details on how the daily backup works and how to restore from the archives.

## Template overview (`docker-templates/`)
- The script renders stacks under `~/server-stacks` with user ownership:
  - **ssl**: `nbraun1/certbot` with cron renewal; certs/logs live in `~/server-stacks/ssl` (mounted as `/etc/letsencrypt`), binds port 80.
  - **cdn-proxy (Nginx)**: reverse proxy for the CDN domain using certs from `~/server-stacks/ssl` (mounted as `/certs`), proxies `/ws` to VLESS WS over `proxy_net`; if both CDN + Direct are enabled it listens on 6443 internally while the gateway holds 443.
  - **vless-cdn**: `ghcr.io/xtls/xray-core:latest` serving VLESS over WebSocket (TLS offloaded at `cdn-proxy`); multiple UUID clients supported.
  - **gateway**: Nginx stream router on 443 SNI-routing to CDN (vless-cdn), Direct Vision, and XHTTP Reality; serves the Vision fallback site on 20002.
  - **vless-direct**: `ghcr.io/xtls/xray-core:latest` with VLESS Vision (XTLS) + VLESS XHTTP Reality, using the Direct domain cert from `/certs`.
  - **hysteria2**: single-password Hysteria2 using the Direct domain cert; masquerade target configurable.
  - **healthcheck**: tiny curl container that pings a user URL every 5 minutes (healthchecks.io-friendly).
  - **copyparty**: file server with configurable credentials and data path; config in `~/server-stacks/copyparty/cfg`, default port 3923.

After rendering, you can let the script start the generated stacks automatically (if Docker is installed), or start them yourself with `docker compose up -d` from each generated directory.

## Notes
- SSH hardening disables password logins. Ensure you have SSH keys configured before running the script remotely.
- The script backs up `/etc/ssh/sshd_config` before applying changes.
- The Certbot stack binds port 80; ensure it is free when you run it. The gateway binds public port 443. If both CDN + Direct are enabled, the CDN Nginx listens on 6443 internally while the gateway handles 443.
- Keep the CDN domain behind Cloudflare only for VLESS+WS. The Direct domain must not sit behind a CDN for Vision/XHTTP Reality/Hysteria2 to work.
- Before starting the Nginx or VLESS stacks, create the shared Docker network with `docker network create proxy_net` (the script will also create it automatically if Docker is available when you choose to auto-start stacks).
- Hysteria2 uses a generated password; update it in `~/server-stacks/hysteria2/server.yaml` if you want a custom value.
- Templates and SSL material are rendered under the selected user's home directory (`~/server-stacks` with `~/server-stacks/ssl` for certs) with user ownership. Compose files use absolute paths into that folder.
- A summary of client-facing details is written to `~/server-stacks/summary.txt` after rendering.

## Nginx content seeding
When rendering templates, the script can optionally download a static 2048 game (from `jinnotgin/2048`) into `~/server-stacks/nginx/www` (CDN site) and `~/server-stacks/gateway/www` (Vision fallback site). If you skip the download, a simple placeholder page is written to the respective `www` directories; replace it with your own site files at any time.
