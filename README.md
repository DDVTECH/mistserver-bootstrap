# MistServer Bootstrap Stack

Cloneable example that bundles MistServer, Prometheus, and Grafana with ready-to-use VOD assets and a live ingest helper. The default setup compiles MistServer from source with `-DWITH_AV=true` for hardware-accelerated transcoding support, provisions Prometheus scraping, and loads a starter Grafana dashboard.

## What you get
- Custom MistServer image built from the official `development` branch with AV acceleration enabled.
- Pre-baked configuration at `configs/mistserver.conf` mounted read/write for easy updates through the Mist UI.
- Sample VOD assets & simulated livestream preconfigured in Mist.
- Prometheus configured to scrape MistServer metrics and Grafana auto-provisioned with a baseline dashboard and Prometheus datasource.
- Default `--shm-size=1gb` to avoid the 64 MB Docker shared-memory limit.

## Quick start

### Local (Linux / macOS / Windows)
```bash
docker compose up --build
```
> Linux environment is recommended, but Docker Desktop works too. This starts only the core services (Mist, Prometheus, Grafana, etc.) and publishes their ports directly. Caddy is disabled by default so ports 80/443 stay free. You can enable it using: `docker compose --profile caddy up --build`, or set `COMPOSE_PROFILES=caddy` in `.env` if you always want the proxy running.

| Service | URL / Endpoint | Notes |
| --- | --- | --- |
| MistController UI | http://localhost:4242 | Defaults to `admin` / `admin` unless overridden via env. |
| MistPlayer templates | http://localhost:8080/{stream}.html | Replace `{stream}` with `vod`, `live`, `push`, etc. |
| RTMP ingest | rtmp://localhost:1935/live/{stream} | Push FLV/RTMP inputs (obs → `live/{stream}`). |
| Prometheus | http://localhost:9090 | Scrapes Mist metrics every 10 s. |
| Grafana | http://localhost:3000 | Default login `admin` / `admin`; auto-provisioned dashboard. |

#### Optional local reverse proxy (no domain)
Want friendlier URLs without buying a domain? Start the Caddy profile on plain HTTP:

```bash
docker compose --profile caddy up --build
```

This keeps the published ports above, but also serves:
- `http://localhost/mist/` (plus `http://localhost/mist/ws`)
- `http://localhost/view/`, `http://localhost/hls/`, `http://localhost/webrtc/`
- `http://localhost/grafana/`

Set `COMPOSE_PROFILES=caddy` in `.env` if you always want this proxy when running `docker compose up`.

### Optional domain + HTTPS (Caddy)
1) Copy `env.example` to project root as `.env` and set at least `DOMAIN` (e.g. `stream.example.com`).  
2) Point DNS for `DOMAIN` to this host and open ports 80/443.  
3) Start with the Caddy profile enabled:
   ```bash
   docker compose --profile caddy up --build
   ```
   (Or set `COMPOSE_PROFILES=caddy` in `.env` so a plain `docker compose up` also starts Caddy.)

When `DOMAIN` is set, Caddy will terminate TLS and proxy:

| Public path | Backend | Notes |
| --- | --- | --- |
| `https://$DOMAIN/mist/` | MistController UI (port 4242) | Admin/API surface. |
| `wss://$DOMAIN/mist/ws` | MistController WebSocket | Live stats/socket UI channel. |
| `https://$DOMAIN/view/` | Mist viewer endpoints (port 8080) | Handles WebSocket upgrades for DRM/dev panels. |
| `https://$DOMAIN/hls/` | Mist HLS | Served with permissive CORS headers. |
| `https://$DOMAIN/webrtc/` | Mist WebRTC | Signalling + media for browsers. |
| `https://$DOMAIN/grafana/` | Grafana (port 3000) | Served from `/grafana/` sub-path. |

If `DOMAIN` is unset but you run the `caddy` profile, it still exposes the same paths on plain HTTP (`http://localhost/...`) alongside the direct service ports above.

### Optional GPU passthrough (Linux only)
```bash
docker compose -f docker-compose.yml -f docker-compose.gpu.yml up --build
```
`docker-compose.gpu.yml` grants the container access to NVIDIA GPUs (`gpus: all`) when the NVIDIA Container Toolkit is installed, and exposes `/dev/dri` for Intel Quick Sync / VA-API. If your distribution restricts `/dev/dri` to the `render` group, edit the commented `group_add` line with your render group GID (`getent group render`). Docker Desktop on macOS/Windows does not expose host GPUs to Linux containers, so this override has no effect there.

Need both GPU access **and** the reverse proxy? Just add the profile flag:

```bash
docker compose --profile caddy -f docker-compose.yml -f docker-compose.gpu.yml up --build
```

## Working with MistServer
- Default streams:
  - `vod`: on-demand playback from assets in `assets/vod/`.
  - `live`: simulated livestream using ffmpeg
  - `push`: stream ready to accept RTMP inputs
- Metrics are exposed at `http://localhost:4242/metrics`. Prometheus scrapes this endpoint every 10 seconds.

## Simulating live sources
- To emit a synthetic FFmpeg test signal to the stream named 'push':
  ```bash
  ./scripts/videogen.sh -f flv -ac 2 rtmp://localhost:1935/live/push
  ```
- To playback the result (substitute your favourite player):
  ```bash
  ffplay http://localhost:8080/hls/push/index.m3u8
  ffplay http://localhost:8080/cmaf/push/index.m3u8
  ffplay http://localhost:8080/webrtc/push
  ```
- On the MistController UI (http://localhost:4242) you can view the stream and some basic QoE metrics
- The embedded MistPlayer allows you to seamlessly switch between protocols, like WebRTC: http://localhost:8080/push.html?dev=1

## Env-driven Mist config
On container start, a small script rewrites `configs/mistserver.conf` from environment:
- `ADMIN_USER` / `ADMIN_PASSWORD` (password stored as MD5)
- `BANDWIDTH_EXCLUDE_LOCAL` and optional `BANDWIDTH_LIMIT_MBIT`
- `LOCATION_NAME`, `LOCATION_LAT`, `LOCATION_LON`
- `PROMETHEUS_PATH` (defaults to `metrics`)
- If `DOMAIN` is set, HTTP pub addresses and WebRTC `pubhost` are updated accordingly

## Grafana provisioning
Grafana loads the `MistServer Overview` dashboard automatically. Start with the example panels (target status, scrape duration, latest metrics) and extend the queries as you explore the Mist metrics namespace. To import community dashboards, drop the JSON in `grafana/dashboards` and restart Grafana.

## Cleanup
```bash
docker compose down
```
Add `--volumes` to drop Prometheus/Grafana data directories.
