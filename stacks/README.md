# Stacks

Pre-made Docker Compose stacks for PinneOS.

## Deploying after first boot

Once ZFS is set up and Docker is running:

```bash
# Create the stacks directory on your ZFS apps dataset
mkdir -p /opt/stacks

# Copy the panel stack
cp -r /path/to/stacks/panel /opt/stacks/panel

# Deploy
cd /opt/stacks/panel
docker compose up -d
```

Then open `http://pinneos.local` for the dashboard, or `http://pinneos.local:5001` for Dockge.

## panel/

The core admin stack: **Homepage** (dashboard) + **Dockge** (stack manager).

| Service  | Port | Purpose                        |
|----------|------|--------------------------------|
| Homepage | 80   | Dashboard with service widgets |
| Dockge   | 5001 | Docker Compose stack manager   |

Homepage config lives at `/opt/stacks/panel/homepage/` on your ZFS disk, so it survives USB replacement.

## Adding your own stacks

Use Dockge at `http://pinneos.local:5001`. Each stack gets its own directory under `/opt/stacks/`.

Stacks are plain `docker-compose.yml` files, so they can be version-controlled alongside this repo.
