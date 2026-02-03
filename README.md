# MistServer Bootstrap

Complete MistServer setup with monitoring and HTTPS. Works as Docker stack or native CLI tools.

## Quick Start

### Docker

```bash
git clone https://github.com/ddvtech/mistserver-bootstrap
cd mistserver-bootstrap
docker compose up
```

| Service | URL | Credentials |
|---------|-----|-------------|
| MistServer | http://localhost:4242 | admin / admin |
| Grafana | http://localhost:3000 | admin / admin |
| Prometheus | http://localhost:9090 | - |
| HLS | http://localhost:8080/hls/{stream}/index.m3u8 | - |
| RTMP Ingest | rtmp://localhost:1935/live/{stream} | - |

### Native

```bash
sudo ./install.sh
mist-install                              # Build MistServer from source
mist-monitoring enable                    # Start Prometheus + Grafana
mist-https enable --domain example.com    # Enable HTTPS
```

## Docker Options

```bash
# With HTTPS (requires DOMAIN in .env)
docker compose --profile caddy up

# With GPU passthrough (Linux)
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up

# Makefile shortcuts
make up CADDY=true GPU=true DETACH=true
```

When `DOMAIN` is set, Caddy proxies `https://$DOMAIN/mist/`, `/hls/`, `/webrtc/`, `/grafana/`.

## CLI Tools

After `sudo ./install.sh`:

| Command | Description |
|---------|-------------|
| `mist-install` | Install MistServer natively (source or binary) |
| `mist-passwd` | Change admin password (native only) |
| `mist-https` | HTTPS via Caddy (native only, use `--profile caddy` for Docker) |
| `mist-monitoring` | Prometheus + Grafana (adds containers to native MistServer) |
| `mist-status` | Show server status |
| `mist-videogen` | Generate test streams |

**Docker stack**: Use `.env` for config (`ADMIN_PASSWORD`, `DOMAIN`) and `--profile caddy` for HTTPS.

## Streams

```bash
# Ingest
mist-videogen -f flv rtmp://localhost:1935/live/test

# Playback
ffplay http://localhost:8080/hls/test/index.m3u8
open http://localhost:8080/test.html
```

## Environment

Copy `env.example` to `.env`:

- `ADMIN_USER` / `ADMIN_PASSWORD` - MistServer credentials
- `DOMAIN` - Enable HTTPS when set
- `MIST_API_PORT`, `GRAFANA_PORT`, `PROMETHEUS_PORT` - Port overrides
