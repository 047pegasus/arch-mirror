# Arch Linux Official Mirror

A complete, production-ready Arch Linux mirror deployment for your home server infrastructure.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                      Cloudflare Tunnel                          │
│                         (HTTPS/TLS)                             │
└──────────────────────────┬──────────────────────────────────────┘
                           │
                           ▼
┌─────────────────────────────────────────────────────────────────┐
│                      Traefik (port 80)                          │
│              traefik-public network                             │
└──────────────────────────┬──────────────────────────────────────┘
                           │
         ┌─────────────────┼─────────────────┐
         ▼                 ▼                 ▼
┌─────────────────┐ ┌─────────────────┐ ┌─────────────────┐
│  arch-mirror    │ │  arch-mirror    │ │  arch-mirror    │
│  nginx          │ │  rsync (timer)  │ │  exporter       │
│  (serves files) │ │  (syncs every   │ │  (metrics)      │
│                 │ │   4 hours)      │ │                 │
└─────────────────┘ └─────────────────┘ └─────────────────┘
         │                 │                 │
         └─────────────────┼─────────────────┘
                           │
              ┌────────────┴────────────┐
              ▼                         ▼
       ┌─────────────┐           ┌─────────────┐
       │   Loki      │           │ Prometheus  │
       │  (logs)     │           │ (metrics)   │
       └─────────────┘           └─────────────┘
              │                         │
              └────────────┬────────────┘
                           ▼
                    ┌─────────────┐
                    │  Grafana    │
                    │ (dashboards)│
                    └─────────────┘
```

## Project Structure

```
arch-mirror/
├── docker-compose.yml          # Main stack (nginx + rsync + exporter)
├── .env.example                # Environment configuration template
├── nginx.conf                  # Nginx main configuration
├── conf.d/
│   └── mirror.conf             # Site-specific config
├── sync.sh                     # Rsync sync script
├── rsync-exclude.txt           # Rsync exclude patterns
├── Dockerfile.exporter         # Prometheus exporter build
├── exporter.go                 # Prometheus exporter source
├── systemd/
│   ├── arch-mirror-sync.service
│   └── arch-mirror-sync.timer
├── traefik/
│   └── arch-mirror.yml         # Traefik dynamic config
└── README.md                   # This file
```

## Quick Deploy (on Server)

### 1. Copy Project to Server

```bash
# On server
sudo mkdir -p /srv/apps/arch-mirror
sudo rsync -av /home/tanishq/Projects/arch-mirror/ /srv/apps/arch-mirror/
sudo chmod +x /srv/apps/arch-mirror/sync.sh
```

### 2. Configure Environment

```bash
cd /srv/apps/arch-mirror
cp .env.example .env
# Edit .env with your mirror source, domain, etc.
# chmod 600 .env  # Secure permissions
```

### 3. Build & Push Exporter Image

```bash
cd /srv/apps/arch-mirror
docker build -f Dockerfile.exporter -t ghcr.io/047pegasus/arch-mirror-exporter:latest .
docker push ghcr.io/047pegasus/arch-mirror-exporter:latest
```

### 4. Deploy Stack

```bash
cd /srv/apps/arch-mirror
docker compose up -d
```

### 5. Install Systemd Timer

```bash
sudo cp systemd/arch-mirror-sync.service /etc/systemd/system/
sudo cp systemd/arch-mirror-sync.timer /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now arch-mirror-sync.timer
```

### 6. Configure Traefik (labels already do this — file is optional)

No action needed: `docker-compose.yml` carries the Traefik Docker labels
(exact `Host()` rules on the `web` entrypoint), mirroring the octoport
control-plane pattern. Traefik picks them up automatically on `up -d`.

Only if you prefer file-provider routing, follow `traefik/arch-mirror.yml`'s
header (remove the labels first to avoid duplicate routers), then:
```bash
sudo cp traefik/arch-mirror.yml /srv/infrastructure/dynamic/
docker exec infrastructure-traefik-1 kill -HUP 1
```

> **Collision guard:** add `arch,mirror` to `OCTOPORT_RESERVED_SUBDOMAINS`
> in `/srv/apps/octoport/.env` (and restart the control plane). Otherwise the
> low-priority octoport catch-all (`priority: 1`) could one day be handed one
> of these names as a random tunnel label. Exact `Host()` routes would still
> win, but the reservation removes the ambiguity at allocation time.

### 7. Configure Prometheus

Merge `monitoring/prometheus-snippet.yml` into your `prometheus.yml`
(requires Prometheus on `traefik-public` so `arch-mirror-exporter` resolves),
then reload:
```bash
docker exec monitoring-prometheus-1 kill -HUP 1
```

### 8. Configure Cloudflare DNS

In Cloudflare Dashboard for `itanishq.space`:

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| CNAME | arch | `<your-tunnel-subdomain>` | Proxied |
| CNAME | mirror | `<your-tunnel-subdomain>` | Proxied |

### 9. Verify

```bash
# Health check
curl https://arch.itanishq.space/health

# Mirror status
curl https://arch.itanishq.space/mirror-status

# Metrics
curl http://arch-mirror-exporter:9100/metrics

# Test package download
curl -I https://arch.itanishq.space/core/os/x86_64/core.db.tar.zst
```

## Monitoring

### Loki Log Queries (Grafana Explore)

```logql
# Nginx access logs
{app="arch-mirror", component="nginx"} |= "GET" |~ "\.pkg\.tar\."

# Rsync sync logs
{app="arch-mirror", component="rsync"} |= "Sync completed"

# Errors
{app="arch-mirror"} |= "error"
```

### Prometheus Metrics

Key metrics exposed:
- `arch_mirror_size_bytes{repo="core|extra|community|multilib|iso|pool"}`
- `arch_mirror_files_total{repo="..."}`
- `arch_mirror_last_sync_timestamp`
- `arch_mirror_sync_status` (1=success, 0=failed)
- `arch_mirror_disk_usage_bytes{mountpoint="/srv",type="total|free|available"}`

### Grafana Dashboard

Import or create dashboard with panels:
1. **Mirror Size by Repo** - Bar gauge
2. **Total Files by Repo** - Stat
3. **Last Sync Status** - Stat with threshold
4. **Sync Duration Trend** - Time series
5. **Disk Usage** - Gauge
6. **Sync Success Rate (30d)** - Stat
7. **nginx Request Rate** - From Loki
8. **Top Downloaded Packages** - From Loki

## Maintenance

```bash
# Check sync timer status
sudo systemctl status arch-mirror-sync.timer

# View sync logs
sudo journalctl -u arch-mirror-sync.service -f
tail -f /var/log/arch-mirror-sync.log

# Manual sync
sudo systemctl start arch-mirror-sync.service

# Check disk space
df -h /srv/http/archlinux

# View container logs
docker logs arch-mirror-nginx -f
docker logs arch-mirror-exporter -f
```

## Register as Official Mirror

Once syncing reliably for 2+ weeks:

1. Verify package integrity:
   ```bash
   mkdir -p /tmp/test && pacman -Sy --dbpath /tmp/test https://arch.itanishq.space
   ```

2. Submit to: https://archlinux.org/mirrors/ (requires account)

3. Provide:
   - `https://arch.itanishq.space`
   - `https://mirror.itanishq.space`

## Customization

### Change Sync Source

Edit `.env`:
```bash
MIRROR_SOURCE=rsync://your-preferred-mirror/archlinux/
# See: https://archlinux.org/mirrors/
```
Then restart the timer: `sudo systemctl restart arch-mirror-sync.timer`

### Change Sync Frequency

Edit `systemd/arch-mirror-sync.timer`:
```ini
# Every 2 hours
OnCalendar=*-*-* 00,02,04,06,08,10,12,14,16,18,20,22:00:00

# Daily at 3 AM
OnCalendar=*-*-* 03:00:00
```
Then reload: `sudo systemctl daemon-reload && sudo systemctl restart arch-mirror-sync.timer`

### Exclude Architectures

Edit `rsync-exclude.txt`:
```bash
*i686*          # Exclude 32-bit
*arm*           # Exclude ARM
*aarch64*       # Exclude ARM64
```

### Change Mirror Domain

Edit `.env`:
```bash
MIRROR_DOMAIN=your-domain.com
```

### Add Basic Auth to Status Endpoint

1. Generate htpasswd:
   ```bash
   htpasswd -nb admin yourpassword
   # Output: admin:$apr1$...
   ```

2. Uncomment in `traefik/arch-mirror.yml`:
   ```yaml
   arch-mirror-auth:
     basicAuth:
       users:
         - "admin:$apr1$..."
   ```

3. Reload Traefik: `docker exec infrastructure-traefik-1 kill -HUP 1`

## Troubleshooting

| Issue | Solution |
|-------|----------|
| Sync fails | Check `/var/log/arch-mirror-sync.log` |
| No metrics | Verify exporter container running, Prometheus scrape config |
| 404 on packages | Check nginx config, verify files exist in `/srv/http/archlinux` |
| Traefik not routing | Check dynamic config loaded, `docker exec traefik kill -HUP 1` |
| Loki no logs | Verify logging driver config matches other apps |

## Requirements

- Docker & Docker Compose
- Traefik on `traefik-public` network
- Cloudflare Tunnel for public ingress
- Loki logging driver plugin installed on host
- Prometheus + Grafana for monitoring
- Systemd for sync timer

## License

MIT - Feel free to use and modify for your own mirror.