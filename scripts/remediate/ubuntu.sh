#!/bin/sh
# Distro default: Ubuntu — upgrade all installed packages to latest.
#
# Honours APT_MIRROR (exported by the Dockerfile from the build-arg):
# if set, replaces the upstream archive hostnames in
# /etc/apt/sources.list* with the Nexus apt-proxy path convention:
#
#   http://archive.ubuntu.com/ubuntu       -> ${APT_MIRROR}/apt-ubuntu-<codename>-proxy
#   http://security.ubuntu.com/ubuntu      -> ${APT_MIRROR}/apt-ubuntu-<codename>-security-proxy
#
# The codename is read from /etc/os-release (VERSION_CODENAME).
set -e
export DEBIAN_FRONTEND=noninteractive

if [ -n "${APT_MIRROR:-}" ]; then
  . /etc/os-release
  CODENAME="${VERSION_CODENAME:-noble}"
  # Ubuntu 24.04+ ships sources in /etc/apt/sources.list.d/ubuntu.sources (deb822 format).
  # Older releases use /etc/apt/sources.list. Handle both.
  find /etc/apt/sources.list /etc/apt/sources.list.d -type f 2>/dev/null | while IFS= read -r f; do
    [ -f "$f" ] || continue
    # security.ubuntu.com → security proxy
    sed -i "s|http://security\.ubuntu\.com/ubuntu/\?|${APT_MIRROR}/apt-ubuntu-${CODENAME}-security-proxy/|g" "$f"
    sed -i "s|https://security\.ubuntu\.com/ubuntu/\?|${APT_MIRROR}/apt-ubuntu-${CODENAME}-security-proxy/|g" "$f"
    # archive.ubuntu.com (amd64) → main archive proxy
    sed -i "s|http://archive\.ubuntu\.com/ubuntu/\?|${APT_MIRROR}/apt-ubuntu-${CODENAME}-proxy/|g" "$f"
    sed -i "s|https://archive\.ubuntu\.com/ubuntu/\?|${APT_MIRROR}/apt-ubuntu-${CODENAME}-proxy/|g" "$f"
    # ports.ubuntu.com (arm64, riscv, ppc64el, etc.) → separate ports proxy
    sed -i "s|http://ports\.ubuntu\.com/ubuntu-ports/\?|${APT_MIRROR}/apt-ubuntu-${CODENAME}-ports-proxy/|g" "$f"
    sed -i "s|https://ports\.ubuntu\.com/ubuntu-ports/\?|${APT_MIRROR}/apt-ubuntu-${CODENAME}-ports-proxy/|g" "$f"
  done
fi

apt-get update
apt-get -y --only-upgrade upgrade
apt-get clean
rm -rf /var/lib/apt/lists/*
