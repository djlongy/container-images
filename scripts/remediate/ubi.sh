#!/bin/sh
# Distro default: Red Hat UBI / UBI-minimal — upgrade all installed packages.
# UBI-minimal uses microdnf; full UBI uses dnf. Try microdnf first.
set -e
if command -v microdnf >/dev/null 2>&1; then
  microdnf -y update
  microdnf clean all
else
  dnf -y update
  dnf clean all
fi
