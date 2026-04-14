#!/bin/sh
# Distro default: Alpine — upgrade all installed packages to latest.
# Per-image override: drop images/<name>/remediate.sh to customise.
#
# Honours APK_MIRROR (exported by the Dockerfile from the build-arg):
# if set, rewrites /etc/apk/repositories to route through a mirror
# instead of dl-cdn.alpinelinux.org (needed for airgapped envs).
set -e

if [ -n "${APK_MIRROR:-}" ] && [ -f /etc/apk/repositories ]; then
  sed -i "s|https://dl-cdn.alpinelinux.org/alpine|${APK_MIRROR}|g" /etc/apk/repositories
fi

apk upgrade --no-cache
