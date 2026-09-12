#!/bin/sh
# Runtime PUID/PGID support (linuxserver.io-style).
# https://github.com/chefcai/radarr-alpine/issues/1
#
# Defaults to a generic 1000:1000 so this image runs out of the box on any
# host. Override with `-e PUID=... -e PGID=...` (or the PUID/PGID entries in
# docker-compose) to match your existing bind-mount ownership.
#
# Only app-state directories are remapped here -- never a media-library
# mount, which stays whatever the host already owns. Recursively chown'ing
# a large media library on every container start would be slow and is
# unnecessary; the deployer is expected to have already set that dir's
# ownership per the README.
set -e

PUID="${PUID:-1000}"
PGID="${PGID:-1000}"

CUR_UID=$(id -u radarr)
CUR_GID=$(id -g radarr)

if [ "$PGID" != "$CUR_GID" ]; then
  sed -i "s/^radarr:x:[0-9]*:/radarr:x:${PGID}:/" /etc/group
fi
if [ "$PUID" != "$CUR_UID" ]; then
  sed -i "s/^radarr:x:[0-9]*:[0-9]*:/radarr:x:${PUID}:${PGID}:/" /etc/passwd
fi

for dir in /config; do
  if [ -d "$dir" ]; then
    owner="$(stat -c '%u:%g' "$dir" 2>/dev/null || echo '?')"
    if [ "$owner" != "${PUID}:${PGID}" ]; then
      chown -R "${PUID}:${PGID}" "$dir"
    fi
  fi
done

exec su-exec radarr "$@"
