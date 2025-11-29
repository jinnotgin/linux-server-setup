# Linux Server Bootstrap (SSH hardening, Docker, Portainer, templates)

`setup.sh` is an interactive bootstrap script for Ubuntu/Debian-like hosts. It focuses on SSH/root hardening, Docker/Portainer installation, daily backups to Google Drive via `rclone`, and optional rendering of ready-made Docker Compose templates (SSL renewal, Nginx reverse proxy, VLESS over WebSocket, VLESS Vision + VLESS XHTTP Reality, and Hysteria2). You can run only the parts you want (e.g., skip hardening/install and just render templates).

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
- Optionally renders Docker Compose templates with your inputs (domain/email/UUIDs/TLS paths) into the `generated/` folder, and can start the stacks right after rendering if Docker is present.

## Usage
```bash
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
- The script can render these into `generated/` with your answers:
  - **ssl-renewal**: `certbot` standalone renewal that keeps certificates under `./certs`. Supports multiple domains. Binds port 80 only so it can coexist with other stacks.
  - **cdn-proxy (Nginx)**: reverse proxy for the CDN domain that serves TLS using the certificates from `./certs` and proxies `/ws` to the VLESS WS container over `proxy_net`. When both CDN + Direct are enabled, it listens internally on **6443** (the gateway handles public 443).
  - **vless-cdn**: `teddysun/xray` serving VLESS over WebSocket without terminating TLS (the CDN Nginx layer terminates TLS and forwards to this service on port 10000 inside `proxy_net`). Supports multiple UUID clients.
  - **gateway**: Nginx stream router on port 443 that SNI-routes traffic: CDN domain → `cdn-proxy` (for VLESS WS), Direct domain → VLESS Vision inbound, everything else → VLESS XHTTP Reality inbound. Also serves the Vision fallback site on port 20002.
  - **vless-direct**: `teddysun/xray` with VLESS Vision (XTLS) + VLESS XHTTP Reality inbounds using the Direct domain's TLS certificate. Vision falls back to the gateway's website; Reality targets a configurable site and supports multiple short IDs.
  - **hysteria2**: Hysteria2 server bound to the Direct domain's certificate, supports multiple users, and masquerades to a configurable site (defaults to Hacker News).
  - **healthcheck**: tiny curl container that pings a user-provided URL every 5 minutes (intended for healthchecks.io or similar).

After rendering, you can let the script start the generated stacks automatically (if Docker is installed), or start them yourself with `docker compose up -d` from each generated directory.

## Notes
- SSH hardening disables password logins. Ensure you have SSH keys configured before running the script remotely.
- The script backs up `/etc/ssh/sshd_config` before applying changes.
- The Certbot template binds port 80; ensure it is free when you run renewal. The gateway binds public port 443. If both CDN + Direct are enabled, the CDN Nginx listens on 6443 internally while the gateway handles 443.
- Keep the CDN domain behind Cloudflare only for VLESS+WS. The Direct domain must not sit behind a CDN for Vision/XHTTP Reality/Hysteria2 to work.
- Before starting the Nginx or VLESS stacks, create the shared Docker network with `docker network create proxy_net` (the script will also create it automatically if Docker is available when you choose to auto-start stacks).
- Update the `obfs` password in the Hysteria2 config after generation if you want a custom value.

## Nginx content seeding
When rendering templates, the script can optionally download a static 2048 game (from `jinnotgin/2048`) into `generated/nginx/www` (CDN site) and `generated/gateway/www` (Vision fallback site). If you skip the download, a simple placeholder page is written to the respective `www` directories; replace it with your own site files at any time.
