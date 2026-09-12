# radarr-alpine

A footprint-minimized Docker image for [Radarr](https://radarr.video) v6 (.NET 8),
built on Alpine Linux. Same playbook as
[`chefcai/jellyfin-alpine`](https://github.com/chefcai/jellyfin-alpine),
[`chefcai/seerr-alpine`](https://github.com/chefcai/seerr-alpine),
[`chefcai/bazarr-alpine`](https://github.com/chefcai/bazarr-alpine), and
[`chefcai/sonarr-alpine`](https://github.com/chefcai/sonarr-alpine): the image
is assembled in GitHub Actions and published to `ghcr.io`, so the eMMC-bound
small/resource-constrained homelab hosts never hold intermediate build artifacts.

## Image

```
ghcr.io/chefcai/radarr-alpine:latest
ghcr.io/chefcai/radarr-alpine:<radarr-version>   # e.g. 6.1.1.10360
```

## Result

| | Compressed pull (linux/amd64) | On-disk (uncompressed) | Δ vs upstream |
|---|---:|---:|---:|
| `lscr.io/linuxserver/radarr:latest` (upstream) | **88.6 MB** | **209 MB** | — |
| `ghcr.io/chefcai/radarr-alpine:latest`         | **74.1 MB** | **172 MB** | **−16.4 % (compressed)** / **−17.7 % (on-disk)** |

> Compressed size is what `docker pull` actually transfers — the metric that
> matters on storage-constrained hosts. The GH workflow's "Report
> final image size" step computes this from the OCI manifest after each push
> and writes it into the run's job summary.

**The 30 % reduction target in the brief was not achievable.** Radarr v6's
self-contained tarball from GitHub Releases (~70 MB compressed) is the floor
that all viable iterations share — same situation as sonarr-alpine. The savings
vs upstream come almost entirely from dropping the `linuxserver/baseimage-alpine`
layer (s6-overlay, bash, jq, curl, procps-ng, shadow, ca-certificates, docker-mods
scripts) plus a few Radarr.Update / *.pdb / UI/*.map prunes. The ffprobe binary
in the tarball is ~16 MB and would yield another ~9 MB compressed if removed,
but that breaks Radarr's "Analyse video files" feature and is not enabled by
default in `:latest` (documented as iter-2b below).

## Upstream tracking

Tracks **`master`** (stable) as published on [Radarr's GitHub Releases](https://github.com/Radarr/Radarr/releases/latest).
The workflow resolves "what version is master today" at build time via the
GitHub Releases API, checks whether that exact version tag already exists in
GHCR, and skips the build if so. The daily 07:15 UTC cron is therefore a no-op
on days Radarr hasn't released anything new.

## Why not just use upstream `linuxserver/radarr`?

Homelab notes claimed the upstream Sonarr/Radarr images were "already efficient
enough" not to be worth a custom build, in contrast to seerr/jellyfin/bazarr
where chefcai/* saved hundreds of MB. sonarr-alpine re-validated that claim
with measurements — there was a real win (~15.5 %), smaller than the 50–60 %
wins elsewhere. radarr-alpine follows the same playbook and lands at −16.4 %,
confirming the pattern.

The wins come from:
- **Dropping the `linuxserver/baseimage-alpine` shell.** Upstream pulls in
  s6-overlay, bash, jq, curl, procps-ng, shadow, ca-certificates, and the
  LSIO docker-mods scripts. We use plain `alpine:3.21` and `init: true` for
  PID 1.
- **No `Radarr.Update/`** (245-file subtree, ~70 MB uncompressed) — in-app
  updates aren't used; we update via `docker pull`.
- **No `*.pdb`** debug symbols, `UI/*.map` SPA source maps.
- **No `sqlite-libs`** — Radarr ships `libe_sqlite3.so`, which is
  System.Data.SQLite's self-contained amalgamation (no system libsqlite3
  dependency). Not needed in the base image.
- **Configurable UID/GID via `PUID`/`PGID`** (default 1000:1000; remapped at
  container start by `entrypoint.sh`, `su-exec`-based) — same runtime
  behavior as LSIO's `abc` user, without the s6-overlay.
- **`COMPlus_EnableDiagnostics=0`** — disables diagnostic sockets, saves RAM.

**Key difference vs sonarr-alpine:** Radarr v6 uses **.NET 8** (sonarr-alpine
tracks Sonarr v4 which uses .NET 6). The self-contained tarball bundles
`NETCore.App 8.0.12 + AspNetCore.App 8.0.12`. Alpine 3.21 ships
`dotnet8-runtime` in apk, but Radarr doesn't distribute a framework-dependent
Linux build, so the self-contained tarball is the only option.

## Compose snippet

Replace the `radarr:` block in `~/arrs/docker-compose.yml`:

```yaml
radarr:
  # Slim Alpine-based Radarr (~74 MB vs upstream ~89 MB, -16.4%).
  # Source: https://github.com/chefcai/radarr-alpine
  image: ghcr.io/chefcai/radarr-alpine:latest
  #image: lscr.io/linuxserver/radarr:latest
  container_name: radarr
  init: true          # Docker provides PID 1; no s6-overlay in chefcai image
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
  environment:
    - TZ=UTC  # override to your local zone
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:7878/ping"]
    interval: 1m30s
    timeout: 10s
    retries: 3
    start_period: 60s
  ports:
    - "7878:7878"
  volumes:
    - /path/to/radarr-config:/config
    - /mnt/Media/config/radarr/MediaCover:/config/MediaCover
    - /mnt/Media/config/radarr/Backups:/config/Backups
    - /mnt/Media/config/radarr/logs:/config/logs
    - /mnt/Media/data:/data
  restart: unless-stopped
  networks:
    - arrs_net
```

Changes vs the LSIO block:
- `image:` → `ghcr.io/chefcai/radarr-alpine:latest`
- `init: true` added (no s6-overlay; Docker provides PID 1)
- `PUID` / `PGID` env vars work directly (default 1000:1000 if unset);
  `UMASK` is still unsupported (LSIO-only) — drop that one
- Healthcheck: `wget` instead of `curl` (no curl in image); `/ping` endpoint
  instead of `/radarr/health` (works with any URL base, no auth required)

## Iteration log

### iter-0 — upstream baseline (lscr.io/linuxserver/radarr:latest)
- **88.6 MB** compressed, **209 MB** on-disk (linux/amd64, measured 2026-04-26)
- 9 layers. Reference point. Not deployed.

### iter-1 — alpine:3.21 + self-contained tarball + safe prune (`Dockerfile`) ✅ current `:latest`
- **74.1 MB** compressed, **172 MB** on-disk — **−16.4 % / −17.7 %** vs upstream
- 4 layers. Deployed 2026-04-26. `/ping` → `{"status":"OK"}`, healthcheck healthy.
- Drops: `linuxserver/baseimage-alpine` shell layer + `Radarr.Update/` (245 files)
  + `*.pdb` + `UI/*.map` (6 files) + `ServiceInstall` / `ServiceUninstall`
- APKs: `icu-libs tzdata ca-certificates libstdc++` (no `sqlite-libs` — `libe_sqlite3.so` is bundled)
- Version: 6.1.1.10360 (.NET 8 / NETCore.App 8.0.12)

### iter-2b — ffprobe-free variant (not in `:latest`, not deployed)
- Would remove the bundled `ffprobe` binary (~16 MB uncompressed → ~9 MB compressed savings)
- Breaks Radarr's "Analyse video files" / custom format video quality detection
- Enable by adding `rm -f ffprobe` to the prune `RUN` step in `Dockerfile`
- Expected size with ffprobe removed: ~65 MB compressed (−27 % vs upstream)
