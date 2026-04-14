#!/bin/sh
# Distro default: Debian — upgrade all installed packages to latest.
#
# Honours APT_MIRROR (exported by the Dockerfile from the build-arg):
# if set, replaces the upstream archive hostnames in
# /etc/apt/sources.list* with the Nexus apt-proxy path convention:
#
#   http://deb.debian.org/debian              -> ${APT_MIRROR}/apt-debian-<codename>-proxy
#   http://deb.debian.org/debian-security     -> ${APT_MIRROR}/apt-debian-security-<codename>-proxy
#   http://security.debian.org/debian-security
#
# The codename is read from /etc/os-release (VERSION_CODENAME).
set -e
export DEBIAN_FRONTEND=noninteractive

if [ -n "${APT_MIRROR:-}" ]; then
  . /etc/os-release
  CODENAME="${VERSION_CODENAME:-trixie}"
  find /etc/apt/sources.list /etc/apt/sources.list.d -type f 2>/dev/null | while IFS= read -r f; do
    [ -f "$f" ] || continue
    # security archive (http or https, two upstream hostnames)
    sed -i "s|http://security\.debian\.org/debian-security/\?|${APT_MIRROR}/apt-debian-security-${CODENAME}-proxy/|g" "$f"
    sed -i "s|https://security\.debian\.org/debian-security/\?|${APT_MIRROR}/apt-debian-security-${CODENAME}-proxy/|g" "$f"
    sed -i "s|http://deb\.debian\.org/debian-security/\?|${APT_MIRROR}/apt-debian-security-${CODENAME}-proxy/|g" "$f"
    # main archive
    sed -i "s|http://deb\.debian\.org/debian/\?|${APT_MIRROR}/apt-debian-${CODENAME}-proxy/|g" "$f"
    sed -i "s|https://deb\.debian\.org/debian/\?|${APT_MIRROR}/apt-debian-${CODENAME}-proxy/|g" "$f"
  done
fi

apt-get update
apt-get -y --only-upgrade upgrade
apt-get clean
rm -rf /var/lib/apt/lists/*
