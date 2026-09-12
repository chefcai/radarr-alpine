# radarr-alpine — minimal Radarr (v6, .NET 8) image on Alpine.
#
# Pattern mirrors chefcai/jellyfin-alpine, chefcai/seerr-alpine,
# chefcai/bazarr-alpine, chefcai/sonarr-alpine:
#   - Build runs in GitHub Actions, not on the deploying host.
#   - Final image is plain alpine + only the runtime artifacts needed
#     to launch the app.
#
# Radarr v6 specifics:
#   - Targets net8.0 (confirmed at v6.1.1.10360 → runtimeconfig tfm=net8.0,
#     NETCore.App 8.0.12). Alpine 3.21 ships dotnet8-runtime natively via
#     apk, but Radarr only distributes a SELF-CONTAINED tarball from GitHub
#     Releases — it bundles its own .NET 8 runtime alongside Radarr.dll.
#     The base image therefore only needs the underlying native libs:
#         icu-libs        (CoreCLR globalization native)
#         tzdata          (TZ env support)
#         ca-certificates (HTTPS to indexers/TMDb/notifications)
#         libstdc++       (C++ runtime for native .NET 8 libs)
#     sqlite-libs is NOT needed — Radarr ships libe_sqlite3.so, which is
#     System.Data.SQLite's self-contained amalgamation (no system libsqlite3
#     dependency).
#
# Compared to upstream linuxserver/radarr the savings come from:
#   - Dropping ghcr.io/linuxserver/baseimage-alpine and its s6-overlay,
#     bash, jq, curl, procps-ng, shadow, ca-certificates, docker-mods scripts.
#   - Dropping Radarr.Update (245 files, ~70 MB uncompressed).
#   - Dropping *.pdb, UI/*.map, ServiceInstall, ServiceUninstall.

ARG RADARR_VERSION=6.1.1.10360
ARG RADARR_BRANCH=master

# ---- Stage 1: fetch & unpack the upstream tarball --------------------------
FROM alpine:3.21 AS fetch
ARG RADARR_VERSION
ARG RADARR_BRANCH

RUN apk add --no-cache curl tar

WORKDIR /work
# Radarr publishes self-contained linux-musl-x64 tarballs on GitHub Releases.
# Naming convention: Radarr.master.{VERSION}.linux-musl-core-x64.tar.gz
# The tarball bundles .NET 8 so no dotnet*-runtime apk is needed.
#
# This URL serves a SELF-CONTAINED tarball — Radarr's CI pipeline publishes
# it under the GitHub Release for each version tag. The linuxmusl-x64 variant
# targets musl-libc (Alpine). Confirmed at v6.1.1.10360: runtimeconfig.json
# shows tfm=net8.0, includedFrameworks=[NETCore.App 8.0.12, AspNetCore.App 8.0.12].
RUN curl -fsSL \
        "https://github.com/Radarr/Radarr/releases/download/v${RADARR_VERSION}/Radarr.${RADARR_BRANCH}.${RADARR_VERSION}.linux-musl-core-x64.tar.gz" \
        -o /work/radarr.tar.gz \
 && mkdir -p /work/radarr \
 && tar xzf /work/radarr.tar.gz -C /work/radarr --strip-components=1 \
 && rm /work/radarr.tar.gz

# Prune step — every byte counts on storage-constrained hosts.
# Numbers in parentheses are uncompressed sizes from the v6.1.1.10360
# linux-musl-core-x64 tarball.
#
#   - Radarr.Update/ (~70 MB uncompressed, 245 files): in-app updater that
#     bundles its own .NET 8 runtime. We update via `docker pull`, never via
#     Radarr's self-update.
#   - *.pdb (~6 MB): .NET debug symbols. Stack traces still resolve method
#     names without them; only line numbers are lost.
#   - *.xml in ref/ (none in v6 tarball, kept for forward-compat).
#   - UI/*.map (6 files): SPA source maps. Used only by browser dev tools to
#     debug minified JS. Radarr functionality unaffected.
#   - ServiceInstall, ServiceUninstall (~160 KB total): Windows service
#     installer ELF stubs. Not referenced by Radarr.deps.json on Linux.
#
# IMPORTANT — do NOT attempt to prune Windows-only DLLs. Same lesson as
# sonarr-alpine (iter-5a SIGSEGV, 2026-04-25): DLLs like
# Microsoft.Win32.Registry.dll, System.ServiceProcess*.dll,
# System.Diagnostics.EventLog.dll, Microsoft.AspNetCore.Server.HttpSys.dll,
# IIS*.dll, Microsoft.VisualBasic*.dll, WindowsBase.dll, etc. are all
# referenced transitively from Radarr's deps.json and the NETCore.App /
# AspNetCore.App shared-framework manifests. When libcoreclr/libhostfxr fails
# to resolve them it crashes with exit 139 (SIGSEGV) and no stdout.
# LSIO doesn't prune any of these. Don't try to be smarter than the deps graph.
RUN set -eux; \
    cd /work/radarr; \
    rm -rf Radarr.Update; \
    find . -name '*.pdb' -type f -delete; \
    find . -name '*.xml' -path '*/ref/*' -type f -delete 2>/dev/null || true; \
    rm -f UI/*.map; \
    rm -f ServiceInstall ServiceUninstall

# Write package_info so Radarr knows it was installed via Docker and disables
# in-app update checks / restart prompts that would re-download Radarr.Update.
ARG RADARR_VERSION
RUN printf 'UpdateMethod=docker\nBranch=%s\nPackageVersion=%s\nPackageAuthor=[chefcai/radarr-alpine](https://github.com/chefcai/radarr-alpine)\n' \
        "${RADARR_BRANCH:-master}" "${RADARR_VERSION}" \
        > /work/radarr/package_info

# ---- Stage 2: runtime ------------------------------------------------------
FROM alpine:3.21

ARG RADARR_VERSION
LABEL org.opencontainers.image.title="radarr-alpine"
LABEL org.opencontainers.image.description="Footprint-minimized Radarr image on Alpine. See https://github.com/chefcai/radarr-alpine"
LABEL org.opencontainers.image.source="https://github.com/chefcai/radarr-alpine"
LABEL org.opencontainers.image.licenses="GPL-3.0-only"
LABEL org.opencontainers.image.version="${RADARR_VERSION}"

# Disable .NET diagnostics sockets — saves RAM, lines up with LSIO's env.
ENV COMPlus_EnableDiagnostics=0 \
    XDG_CONFIG_HOME=/config/xdg \
    TZ=UTC

# Runtime deps for .NET 8 self-contained on Alpine musl:
#   - icu-libs:        CoreCLR globalization. Without it .NET 8 throws
#                      System.Globalization.CultureNotFoundException at startup
#                      unless DOTNET_SYSTEM_GLOBALIZATION_INVARIANT=1 — Radarr
#                      uses culture-aware string compares, invariant mode is
#                      not safe.
#   - tzdata:          /usr/share/zoneinfo so TZ=America/New_York works.
#   - ca-certificates: outbound HTTPS to TMDb, indexers, notifications.
#   - libstdc++:       C++ runtime required by .NET 8 native libs (libcoreclr,
#                      libclrjit, etc.). icu-libs also pulls it in transitively,
#                      but listed explicitly for clarity.
#
# sqlite-libs intentionally omitted: Radarr bundles libe_sqlite3.so, which is
# System.Data.SQLite's self-contained SQLite amalgamation — it does NOT
# dlopen or link against the system libsqlite3.
#
# UID/GID 13001:13000 by default at build time (homelab convention, matches
# sonarr/jellyfin/seerr-alpine) -- fully overridable at runtime via the
# PUID/PGID env vars, see entrypoint.sh and
# https://github.com/chefcai/radarr-alpine/issues/1
RUN apk add --no-cache \
        icu-libs \
        tzdata \
        ca-certificates \
        libstdc++ \
        su-exec \
 && addgroup -g 13000 radarr \
 && adduser -D -u 13001 -G radarr -h /config -s /sbin/nologin radarr \
 && mkdir -p /config /app /media \
 && chown -R radarr:radarr /config /app /media

COPY --from=fetch --chown=radarr:radarr /work/radarr /app/radarr/bin

COPY entrypoint.sh /entrypoint.sh
RUN chmod +x /entrypoint.sh

# NOTE: intentionally stays as root here -- entrypoint.sh drops to
# PUID:PGID (default 1000:1000) via su-exec at container start. See
# https://github.com/chefcai/radarr-alpine/issues/1
WORKDIR /app/radarr
EXPOSE 7878

# Healthcheck uses busybox wget — no curl in the image. /ping is the Radarr
# lightweight endpoint that returns 200 once fully started, with no auth
# required regardless of URL base setting.
HEALTHCHECK --interval=1m30s --timeout=10s --retries=3 --start-period=60s \
    CMD wget --no-verbose --tries=1 --spider http://localhost:7878/ping || exit 1

# Radarr's bundled AppHost binary launches the .NET 8 runtime and assembly.
# `--data` points at the per-instance config dir (DB, indexer/profile XML,
# logs). `--nobrowser` is a no-op in headless mode but signals intent.
ENTRYPOINT ["/entrypoint.sh"]
CMD ["/app/radarr/bin/Radarr", "--data=/config", "--nobrowser"]
