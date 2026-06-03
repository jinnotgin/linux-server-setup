# Linux Server Setup

This repository provides purpose-based interactive setup scripts for Ubuntu/Debian-like hosts:

- `scripts/linux-server-setup.sh`: general server setup, SSH hardening, optional Tailscale exit-node/subnet-router setup, UFW, and optional host-level healthchecks.io uptime ping.
- `scripts/docker-portainer-setup.sh`: Docker Engine, Docker Compose plugin, Portainer CE, and optional Portainer backups to Google Drive via `rclone`.
- `scripts/copyparty-setup.sh`: standalone Copyparty file-server stack rendering.
- `scripts/tunnel-stack-setup.sh`: tunnel/proxy Docker stack rendering for Certbot, Nginx, VLESS, Hysteria2, and WARP variants.
- `scripts/media-stack-setup.sh`: Jellyfin + Radarr + Sonarr + Prowlarr + Byparr + Profilarr stack rendering, with optional SMB/CIFS mount setup and HTTPS via Cloudflare DNS-01.
- `scripts/healthcheck-setup.sh`: host-level healthchecks.io uptime ping using a systemd service and timer.

`setup.sh` is a launcher that lets you run one purpose script, a comma-separated set of scripts in the order you choose, or all purpose scripts in order.

## Domain roles (Cloudflare vs direct)
- Provide one or two domains. With one domain, pick a mode: **CDN** (Cloudflare OK) for VLESS over WebSocket only, or **Direct** (no CDN) for Hysteria2 + VLESS Vision + VLESS XHTTP Reality.
- With two domains, assign one as the **CDN domain** (VLESS+WS only) and one as the **Direct domain** (Hysteria2 + Vision + XHTTP Reality). Certbot is configured for all selected domains.

## What the script does
- Requests sudo when privileged steps are selected.
- Best-effort optional steps warn and continue where safe; warnings are written to the setup log. Required inputs and template rendering errors still stop the selected setup because continuing would create incomplete files.
- General Linux setup can update packages, install common packages, set locale to `en_US.UTF-8`, set timezone to `Asia/Singapore`, create/ensure a sudo user, harden SSH, install Tailscale with exit-node advertising, optionally enable Tailscale SSH, optionally advertise subnet routes, configure Linux IP forwarding and persistent UDP offload tuning for Tailscale routing, configure UFW, and install a host-level healthchecks.io uptime ping.
- Docker setup can install Docker Engine + Compose plugin, deploy Portainer CE (`portainer/portainer-ce`) on ports `8000` and `9443`, optionally add Docker-friendly UFW rules (`DOCKER-USER` chain in `after.rules`) and open Portainer ports, and configure daily Portainer backups.
- Portainer backups use `rclone config` with Google Drive OAuth and a remote named `portainer_gdrive`.
- Tunnel stack setup renders one Portainer-ready Docker Compose file with your inputs under `~/tunnel-stack/docker-compose.yml`, and optionally opens tunnel ports in UFW (using `ufw route allow` only if Docker-friendly rules are already active). It does not launch Docker Compose for you.
- Host healthcheck setup installs `linux-server-healthcheck.service` and `linux-server-healthcheck.timer`, which ping your healthchecks.io URL every 5 minutes without depending on Docker.
- Copyparty setup renders its Docker Compose files under `~/copyparty-stack`.
- The media stack script renders a stack under `~/media-stack/docker-compose.yml` with Jellyfin (8096), Radarr (7878), Sonarr (8989), Prowlarr (9696), Byparr (8191), Profilarr (6868), a Cloudflare DNS-01 certbot, and an Nginx HTTPS reverse proxy (443 → Jellyfin). If SMB mounting is selected, the script installs `cifs-utils`, mounts the share, and writes an `/etc/fstab` entry for persistence; the NAS hostname and IP are also injected via `extra_hosts` into Radarr and Sonarr. The script does not launch Docker Compose for you.

## Usage
```bash
git clone https://github.com/jinnotgin/linux-server-setup.git
cd linux-server-setup
chmod +x setup.sh
./setup.sh
```

The launcher accepts one option or a comma-separated list:

```text
1       # General Linux server setup
1,2,4   # Run Linux setup, Docker/Portainer, then tunnel stack setup
6       # Run all purpose setups in order
```

You can also run a purpose script directly:

```bash
chmod +x scripts/*.sh
./scripts/linux-server-setup.sh
./scripts/docker-portainer-setup.sh
./scripts/copyparty-setup.sh
./scripts/tunnel-stack-setup.sh
./scripts/media-stack-setup.sh
./scripts/healthcheck-setup.sh
```

For fresh servers, run the scripts in that order. `setup.sh` also has a "Run all in order" option.

If you download only the launcher with `wget` or `curl`, also download the `scripts/` directory and `docker-templates/` directory. The launcher depends on those files.

Run as root or a sudo-capable user. The scripts will prompt for:
- Which purpose setup to run.
- One option or comma-separated options when using `setup.sh`.
- Sudo password (if needed).
- The username to create/ensure, and a password if the user is being created.
- Whether to enable Tailscale SSH.
- Optional Tailscale subnet routes to advertise, as comma-separated CIDRs.
- Optional interactive `rclone config` for the Google Drive remote used by Portainer backups.
- Domain names, email, UUIDs, and other template parameters if you choose to render templates.
- Optional healthchecks.io ping URL for host uptime monitoring.

Each setup script writes a lightweight finished log under the selected user's `~/linux-server-setup-logs/` with the selected options, generated files, warnings, and follow-up notes. If the selected user's home directory cannot be found, the log falls back to the current user's home directory.

> Re-login after the script finishes so the chosen user picks up new group memberships (sudo/docker).

## Portainer backup & restore
See [`docs/portainer-backup.md`](docs/portainer-backup.md) for details on how the daily backup works and how to restore from the archives.

## Template overview (`docker-templates/`)
- The tunnel script renders one stack compose under `~/tunnel-stack/docker-compose.yml` with user ownership:
  - **tunnel-certbot**: `serversideup/certbot-dns-cloudflare` using Cloudflare DNS-01; certs live in `~/tunnel-stack/ssl` (mounted as `/etc/letsencrypt`), so port 80 is not needed.
  - **cdn-proxy (Nginx)**: reverse proxy for the CDN domain using certs from `~/tunnel-stack/ssl` (mounted as `/certs`), proxies `/ws` to VLESS WS over `proxy_net`; listens on public port `6443`.
  - **vless-cdn**: `ghcr.io/xtls/xray-core:latest` serving VLESS over WebSocket (TLS offloaded at `cdn-proxy`); multiple UUID clients supported.
  - **gateway-router**: Nginx stream router on public port `2053` SNI-routing to CDN (vless-cdn), Direct Vision, and XHTTP Reality; serves the Vision fallback site on 20002.
  - **vless-direct**: `ghcr.io/xtls/xray-core:latest` with VLESS Vision (XTLS) + VLESS XHTTP Reality, using the Direct domain cert from `/certs`.
  - **hysteria2**: single-password Hysteria2 using the Direct domain cert; masquerade target configurable.
- The Copyparty script renders a separate file-server stack under `~/copyparty-stack`; default port 3923.

After rendering, import `~/tunnel-stack/docker-compose.yml` into Portainer or run it yourself later. The setup script intentionally does not run Docker Compose.

## Notes
- SSH hardening disables password logins. Ensure you have SSH keys configured before running the script remotely.
- The script backs up `/etc/ssh/sshd_config` before applying changes.
- Certbot uses Cloudflare DNS-01 and does not bind port 80. The gateway binds public port `2053`, the CDN proxy binds public port `6443`, Hysteria2 WARP binds public port `8443` TCP/UDP, and Hysteria2 binds public port `8444` TCP/UDP.
- Keep the CDN domain behind Cloudflare only for VLESS+WS. The Direct domain must not sit behind a CDN for Vision/XHTTP Reality/Hysteria2 to work.
- Before starting the Portainer stack, create the shared Docker network with `docker network create proxy_net` or create an equivalent external network in Portainer.
- Hysteria2 uses a generated password; update it in `~/tunnel-stack/hysteria2/hysteria.yaml` if you want a custom value.
- Tunnel config files and SSL material are rendered under the selected user's home directory (`~/tunnel-stack` with `~/tunnel-stack/ssl` for certs) with user ownership. The generated compose file uses absolute paths into that folder.
- A client-facing tunnel README with generated connection details is written to `~/tunnel-stack/README.md` after rendering.

## Nginx content seeding
When rendering tunnel templates, the script can optionally download a static 2048 game (from `jinnotgin/2048`) into `~/tunnel-stack/nginx/www` (CDN site) and `~/tunnel-stack/gateway/www` (Vision fallback site). If you skip the download, a simple placeholder page is written to the respective `www` directories; replace it with your own site files at any time.
