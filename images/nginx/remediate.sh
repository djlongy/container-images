#!/bin/sh
# CVE remediation for nginx (Alpine-based)
#
# Upgrades all Alpine packages to their latest available versions.
# This patches OS-level CVEs (libcrypto, libssl, libxml2, libpng, etc.)
# without changing the nginx version itself.
#
# To target specific packages instead of upgrading all:
#   apk upgrade --no-cache libcrypto3 libssl3 libxml2 libpng libexpat

apk upgrade --no-cache
