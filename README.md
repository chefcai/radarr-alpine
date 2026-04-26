# radarr-alpine

A footprint-minimized Docker image for [Radarr](https://radarr.video) v6 (.NET 8),
built on Alpine Linux. Same playbook as
[`chefcai/jellyfin-alpine`](https://github.com/chefcai/jellyfin-alpine),
[`chefcai/seerr-alpine`](https://github.com/chefcai/seerr-alpine),
[`chefcai/bazarr-alpine`](https://github.com/chefcai/bazarr-alpine), and
[`chefcai/sonarr-alpine`](https://github.com/chefcai/sonarr-alpine): the image
is assembled in GitHub Actions and published to `ghcr.io`, so the eMMC-bound
homelab host (`squirttle`, ~3.9 GB free) never holds intermediate build artifacts.

## Image

```
ghcr.io/chefcai/radarr-alpine:latest
ghcr.io/chefcai/radarr-alpine:<radarr-version>   # e.g. 6.1.1.10360
```

## Result

| | Compressed pull (linux/amd64) | Δ vs upstream |
|---|---:|---:|
| `lscr.io/linuxserver/radarr:latest` (upstream, iter-0) | **88.6 MB** | — |
| `ghcr.io/chefcai/radarr-alpine:latest` (iter-1) | **TBD after first build** | **TBD** |

> Compressed size is what `docker pull` actually transfers — the metric that
> matters for squirttle's eMMC bandwidth/space. The GH workflow's "Report
> final image size" step computes this from the OCI manifest after each push
> and writes it into the run's job summary.

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
with measurements — there was a real win (~15.5%), smaller than the 50–60%
wins elsewhere. radarr-alpine follows the same playbook and expects a similar
savings band.

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
- **Fixed UID/GID baked in** (13001:13000). LSIO's `abc` user gets renumbered
  at runtime; the chefcai image hardcodes the IDs and chowns at build.
- **`COMPlus_EnableDiagnostics=0`** — disables diagnostic sockets, saves RAM.

**Key difference vs sonarr-alpine:** Radarr v6 uses **.NET 8** (sonarr-alpine
tracks Sonarr v4 which uses .NET 6). The self-contained tarball bundles its
own `NETCore.App 8.0.12 + AspNetCore.App 8.0.12`. Alpine 3.21 ships
`dotnet8-runtime` in apk but Radarr doesn't distribute a framework-dependent
Linux build, so the self-contained tarball is the only option.

## The 30% reduction target

The same analysis applies here as for sonarr-alpine: **the 30% reduction target
is not achievable.** The application layer floor is set by Radarr's bundled
.NET 8 self-contained binary (~70–75 MB compressed), which we don't control.
The only remaining lever is removing the bundled `ffprobe` binary (~16 MB),
but that breaks Radarr's "Analyse video files" feature and is not enabled by
default in `:latest` (documented as iter-2b below).

## Compose snippet

Replace the `radarr:` block in `~/arrs/docker-compose.yml`:

```yaml
radarr:
  image: ghcr.io/chefcai/radarr-alpine:latest
  container_name: radarr
  init: true          # Docker provides PID 1; no s6-overlay
  logging:
    driver: json-file
    options:
      max-size: "10m"
      max-file: "3"
  environment:
    - TZ=America/New_York
  healthcheck:
    test: ["CMD", "wget", "--no-verbose", "--tries=1", "--spider", "http://localhost:7878/ping"]
    interval: 1m30s
    timeout: 10s
    retries: 3
    start_period: 60s
  ports:
    - "7878:7878"
  volumes:
    - /home/haadmin/config/radarr-config:/config
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
- Drop `PUID=13001 / PGID=13000 / UMASK=002` env vars (UID baked in)
- Healthcheck: `wget` instead of `curl` (no curl in image); `/ping` endpoint
  instead of `/radarr/health` (works with any URL base, no auth required)

## Iteration log

### iter-0 — upstream baseline (lscr.io/linuxserver/radarr:latest)
- **88.6 MB** compressed, 9 layers (linux/amd64, measured 2026-04-25)
- Reference point. Not deployed.

### iter-1 — alpine:3.21 + self-contained tarball + safe prune (`Dockerfile`)
- **TBD** — pending first build
- Drops: baseimage-alpine shell + Radarr.Update + *.pdb + UI/*.map + ServiceInstall/Uninstall
- APKs: icu-libs, tzdata, ca-certificates, libstdc++ (no sqlite-libs — bundled libe_sqlite3.so)

### iter-2b — ffprobe-free variant (not in `:latest`)
- Would remove the bundled `ffprobe` binary (~16 MB uncompressed → ~9 MB compressed)
- Breaks Radarr's "Analyse video files" / custom format video quality detection
- Documented here as an option for deployments that don't use media analysis
- Enable by adding `rm -f ffprobe` to the prune RUN step in the Dockerfile
