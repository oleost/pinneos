# Recommended apps for PinneOS

Ready-to-use Docker Compose stacks for the most popular homelab apps.
All examples use `tank` as the pool name — replace with your actual pool name.

**Conventions used throughout:**
- `PUID=1000 PGID=1000` — the `homelab` system user baked into PinneOS
- `/tank/apps/<appname>` — app config (persists across reboots on ZFS)
- `/tank/storage/` — user data (media, photos, shared files)
- Prefer `lscr.io/linuxserver/` images — they handle PUID/PGID natively

Paste stacks into Dockge at `http://pinneos.local:5001`.

---

## 1. Jellyfin — Media server

Stream movies, TV shows, and music from your ZFS storage to any device.
Open source, no account required.

```yaml
services:
  jellyfin:
    image: lscr.io/linuxserver/jellyfin:latest
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Oslo
    ports:
      - "8096:8096"
    volumes:
      - /tank/apps/jellyfin:/config
      - /tank/storage/media:/media
    restart: unless-stopped
```

Open: `http://pinneos.local:8096`
First run: point the library wizard at `/media/movies`, `/media/tv`, etc.

---

## 2. Immich — Photo backup (self-hosted Google Photos)

Automatic photo and video backup from your phone. Face recognition, albums, map view.
Requires a phone app (iOS/Android).

```yaml
services:
  immich-server:
    image: ghcr.io/immich-app/immich-server:release
    environment:
      - DB_HOSTNAME=immich-db
      - DB_USERNAME=immich
      - DB_PASSWORD=immich
      - DB_DATABASE_NAME=immich
      - REDIS_HOSTNAME=immich-redis
    ports:
      - "2283:2283"
    volumes:
      - /tank/storage/photos:/usr/src/app/upload
      - /etc/localtime:/etc/localtime:ro
    depends_on:
      - immich-redis
      - immich-db
    restart: unless-stopped

  immich-machine-learning:
    image: ghcr.io/immich-app/immich-machine-learning:release
    volumes:
      - /tank/apps/immich/model-cache:/cache
    restart: unless-stopped

  immich-redis:
    image: redis:alpine
    restart: unless-stopped

  immich-db:
    image: tensorchord/pgvecto-rs:pg14-v0.2.0
    environment:
      - POSTGRES_USER=immich
      - POSTGRES_PASSWORD=immich
      - POSTGRES_DB=immich
    volumes:
      - /tank/apps/immich/db:/var/lib/postgresql/data
    restart: unless-stopped
```

Open: `http://pinneos.local:2283`
Setup: `mkdir -p /tank/apps/immich/{model-cache,db} /tank/storage/photos`

---

## 3. Vaultwarden — Password manager

Self-hosted Bitwarden-compatible password manager.
Works with the official Bitwarden browser extension and mobile apps.

```yaml
services:
  vaultwarden:
    image: vaultwarden/server:latest
    user: "1000:1000"
    environment:
      - TZ=Europe/Oslo
    ports:
      - "8888:80"
    volumes:
      - /tank/apps/vaultwarden:/data
    restart: unless-stopped
```

Open: `http://pinneos.local:8888`
Note: For use outside your LAN, put this behind Nginx Proxy Manager with HTTPS.
Setup: `mkdir -p /tank/apps/vaultwarden && chown 1000:1000 /tank/apps/vaultwarden`

---

## 4. Nextcloud — Personal cloud storage

File sync, calendar, contacts, notes — a self-hosted Dropbox/Google Drive.
Requires the Nextcloud desktop or mobile client.

```yaml
services:
  nextcloud:
    image: lscr.io/linuxserver/nextcloud:latest
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Oslo
    ports:
      - "443:443"
    volumes:
      - /tank/apps/nextcloud:/config
      - /tank/storage/shared:/data
    depends_on:
      - nextcloud-db
    restart: unless-stopped

  nextcloud-db:
    image: lscr.io/linuxserver/mariadb:latest
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Oslo
      - MYSQL_ROOT_PASSWORD=changeme
      - MYSQL_DATABASE=nextcloud
      - MYSQL_USER=nextcloud
      - MYSQL_PASSWORD=changeme
    volumes:
      - /tank/apps/nextcloud-db:/config
    restart: unless-stopped
```

Open: `https://pinneos.local`
Setup: `mkdir -p /tank/apps/{nextcloud,nextcloud-db}`
Note: Change both `changeme` passwords before starting.

---

## 5. Samba — Network file sharing (SMB)

Mount your ZFS storage as a network drive on Windows, macOS, or Linux.
No client software needed — shows up directly in Explorer/Finder.

```yaml
services:
  samba:
    image: lscr.io/linuxserver/samba:latest
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Oslo
      - SAMBA_CONF_WORKGROUP=WORKGROUP
      - SAMBA_CONF_SERVER_STRING=PinneOS
    ports:
      - "445:445"
    volumes:
      - /tank/apps/samba:/config
      - /tank/storage:/shares
    restart: unless-stopped
```

After starting, edit `/tank/apps/samba/smb.conf` to define shares:
```ini
[storage]
  path = /shares
  browsable = yes
  read only = no
  valid users = your-user
```

Connect from Windows: `\\pinneos.local\storage`
Connect from macOS: `smb://pinneos.local/storage`

---

## 6. Filebrowser — Web file manager

Browse, upload, download, and manage files in your browser.

```yaml
services:
  filebrowser:
    image: filebrowser/filebrowser:latest
    user: "1000:1000"
    ports:
      - "8080:80"
    volumes:
      - /tank:/srv
      - /tank/apps/filebrowser:/config
    restart: unless-stopped
```

Open: `http://pinneos.local:8080`
Default login: `admin` / `admin` — change immediately after first login.
Setup: `mkdir -p /tank/apps/filebrowser && chown 1000:1000 /tank/apps/filebrowser`

---

## 7. Nginx Proxy Manager — Reverse proxy + SSL

Route `jellyfin.yourdomain.com` → port 8096, with automatic Let's Encrypt certificates.
Required if you want HTTPS or access from outside your home network.

```yaml
services:
  nginx-proxy-manager:
    image: jc21/nginx-proxy-manager:latest
    ports:
      - "80:80"
      - "81:81"
      - "443:443"
    volumes:
      - /tank/apps/nginx-proxy-manager/data:/data
      - /tank/apps/nginx-proxy-manager/letsencrypt:/etc/letsencrypt
    restart: unless-stopped
```

Open: `http://pinneos.local:81`
Default login: `admin@example.com` / `changeme`
Note: Port 80 conflicts with Homepage. Either move Homepage to another port or change
Nginx Proxy Manager's HTTP port to something else (e.g. 8000:80).
Setup: `mkdir -p /tank/apps/nginx-proxy-manager/{data,letsencrypt}`

---

## 8. qBittorrent — Torrent client

Download torrents via a web UI. Pairs naturally with Sonarr/Radarr for automated downloads.

```yaml
services:
  qbittorrent:
    image: lscr.io/linuxserver/qbittorrent:latest
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Oslo
      - WEBUI_PORT=8090
    ports:
      - "8090:8090"
      - "6881:6881"
      - "6881:6881/udp"
    volumes:
      - /tank/apps/qbittorrent:/config
      - /tank/storage/downloads:/downloads
    restart: unless-stopped
```

Open: `http://pinneos.local:8090`
Default login: `admin` / `adminadmin`
Set download path to `/downloads` in Settings → Downloads.

---

## 9. Sonarr + Radarr — Automated media management

Sonarr monitors TV shows and triggers downloads automatically.
Radarr does the same for movies. Both integrate with qBittorrent and Jellyfin.

```yaml
services:
  sonarr:
    image: lscr.io/linuxserver/sonarr:latest
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Oslo
    ports:
      - "8989:8989"
    volumes:
      - /tank/apps/sonarr:/config
      - /tank/storage/media/tv:/tv
      - /tank/storage/downloads:/downloads
    restart: unless-stopped

  radarr:
    image: lscr.io/linuxserver/radarr:latest
    environment:
      - PUID=1000
      - PGID=1000
      - TZ=Europe/Oslo
    ports:
      - "7878:7878"
    volumes:
      - /tank/apps/radarr:/config
      - /tank/storage/media/movies:/movies
      - /tank/storage/downloads:/downloads
    restart: unless-stopped
```

Sonarr: `http://pinneos.local:8989`
Radarr: `http://pinneos.local:7878`
Connect to qBittorrent in Settings → Download Clients → qBittorrent (host: `qbittorrent`, port: `8090`).

---

## 10. Uptime Kuma — Service monitoring

Dashboard showing whether your services are up, with notifications when something goes down.

```yaml
services:
  uptime-kuma:
    image: louislam/uptime-kuma:latest
    user: "1000:1000"
    ports:
      - "3001:3001"
    volumes:
      - /tank/apps/uptime-kuma:/app/data
    restart: unless-stopped
```

Open: `http://pinneos.local:3001`
Setup: `mkdir -p /tank/apps/uptime-kuma && chown 1000:1000 /tank/apps/uptime-kuma`
Add monitors for: Cockpit (:9090), Jellyfin (:8096), Dockge (:5001), and any other services.

---

## 11. Gotify — Push notifications

Self-hosted push notification server. Sends alerts from PinneOS (disk failures, ZFS scrub errors)
to your phone via the Gotify Android/iOS app.

```yaml
services:
  gotify:
    image: gotify/server:latest
    user: "1000:1000"
    ports:
      - "8008:80"
    volumes:
      - /tank/apps/gotify:/app/data
    restart: unless-stopped
```

Open: `http://pinneos.local:8008`
Setup:
```bash
mkdir -p /tank/apps/gotify && chown 1000:1000 /tank/apps/gotify
```

After setup, create an app token in the Gotify UI and configure PinneOS to use it:
```bash
echo "http://pinneos.local:8008" > /etc/homelab/gotify-url
echo "<your-app-token>"          > /etc/homelab/gotify-token
```

PinneOS will then send push notifications to Gotify for:
- SMART disk warnings and failures
- ZFS scrub errors

---

## Port reference

| App | Port | URL |
|-----|------|-----|
| Homepage | 80 | `http://pinneos.local` |
| Cockpit | 9090 | `http://pinneos.local:9090` |
| Dockge | 5001 | `http://pinneos.local:5001` |
| Jellyfin | 8096 | `http://pinneos.local:8096` |
| Immich | 2283 | `http://pinneos.local:2283` |
| Vaultwarden | 8888 | `http://pinneos.local:8888` |
| Nextcloud | 443 | `https://pinneos.local` |
| Filebrowser | 8080 | `http://pinneos.local:8080` |
| Nginx Proxy Manager UI | 81 | `http://pinneos.local:81` |
| qBittorrent | 8090 | `http://pinneos.local:8090` |
| Sonarr | 8989 | `http://pinneos.local:8989` |
| Radarr | 7878 | `http://pinneos.local:7878` |
| Uptime Kuma | 3001 | `http://pinneos.local:3001` |
| Gotify | 8008 | `http://pinneos.local:8008` |
