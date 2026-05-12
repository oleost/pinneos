The user wants to add a Docker app to their PinneOS homelab server. Generate a ready-to-paste docker-compose stack for Dockge.

## PinneOS Docker conventions

**User:** All containers run as `PUID=1000 PGID=1000` (the `homelab` system user).

**Image preference (in order):**
1. `lscr.io/linuxserver/<app>` — preferred, supports PUID/PGID natively
2. Official image with `user: "1000:1000"` in compose
3. Official image with `user: root` only as last resort (note the tradeoff)

**Volume paths** (pool name varies — check with `zpool list` or infer from context):
- App config/state: `/POOLNAME/apps/APPNAME/` — persists across reboots, survives Docker volume removal
- User data/media: `/POOLNAME/storage/` — owned by homelab user
- Internal databases the user never touches: Docker named volume (auto-created, lives on apps dataset)

**Do NOT:**
- Use `/var/lib/homelab/` or `/opt/` — not on ZFS, lost on reboot
- Use `user: root` when a PUID/PGID approach is available
- Hardcode `/pool/` — the pool name is set by the user during setup (e.g. `pinneoshdd`, `tank`, `data`)

**Standard template (linuxserver.io image):**
```yaml
services:
  APPNAME:
    image: lscr.io/linuxserver/APPNAME:latest
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Oslo
    ports:
      - "PORT:PORT"
    volumes:
      - /POOLNAME/apps/APPNAME:/config
      - /POOLNAME/storage/media:/media        # only if app needs media
    restart: unless-stopped
```

**Standard template (non-linuxserver image with PUID/PGID support):**
```yaml
services:
  APPNAME:
    image: vendor/APPNAME:latest
    user: "1000:1000"
    ports:
      - "PORT:PORT"
    volumes:
      - /POOLNAME/apps/APPNAME:/config
    restart: unless-stopped
```

## Known pool name
The user's pool is `pinneoshdd` (confirmed from `zpool list` output shared in conversation).
Storage is at `/pinneoshdd/storage/`, apps at `/pinneoshdd/apps/`.

## Common apps and their correct images

| App | Image | Port | Notes |
|-----|-------|------|-------|
| Plex | `lscr.io/linuxserver/plex` | `32400` | `network_mode: host` recommended; needs `PLEX_CLAIM` on first run |
| Jellyfin | `lscr.io/linuxserver/jellyfin` | `8096` | OSS Plex alternative |
| Sonarr | `lscr.io/linuxserver/sonarr` | `8989` | TV show management |
| Radarr | `lscr.io/linuxserver/radarr` | `7878` | Movie management |
| Prowlarr | `lscr.io/linuxserver/prowlarr` | `9696` | Indexer manager |
| qBittorrent | `lscr.io/linuxserver/qbittorrent` | `8080` | Torrent client |
| Filebrowser | `filebrowser/filebrowser` | `8080` | No lscr image; use `user: root` or ensure paths owned by 1000 |
| Nextcloud | `lscr.io/linuxserver/nextcloud` | `443` | Needs MariaDB sidecar |
| Samba | `lscr.io/linuxserver/samba` | `445` | SMB shares from storage datasets |
| Vaultwarden | `vaultwarden/server` | `80` | Bitwarden-compatible; use named volume for data |
| Uptime Kuma | `louislam/uptime-kuma` | `3001` | Monitoring; named volume for data |
| Homepage | `ghcr.io/gethomepage/homepage` | `3000` | Already included in PinneOS base |

## Before generating the compose

1. Confirm the pool name (from conversation context or ask)
2. Check if a lscr.io image exists for the app
3. Note any app-specific requirements (claim tokens, sidecars, network_mode: host)
4. Mention that the user should create the config dir path if it doesn't exist:
   `ssh root@<ip> "mkdir -p /POOLNAME/apps/APPNAME"`
   Or they can use Cockpit terminal.
