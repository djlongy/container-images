#
# Shared promotion Dockerfile — used by all images unless overridden.
#
# Structure matches the container-image-template repo exactly:
#   upstream base → optional cert injection → optional CVE remediation
#   → final user restoration. Each stage is ARG-gated via
#   `FROM stage-${ARG}` so unused branches never run. BuildKit prunes
#   the unselected graph.
#
# The only monorepo-specific addition is IMAGE_DIR, which tells the
# remediate stage where to find the per-image remediate.sh script
# (images/<name>/remediate.sh). The template repo uses
# scripts/remediate/${DISTRO}.sh directly instead.
#
# Dynamic OCI labels (version, revision, created, base.digest, source,
# etc.) are intentionally NOT set here with LABEL. They're passed by
# scripts/build.sh via `docker build --label ...`, which is the
# DevSecOps-recommended pattern: Dockerfiles hold static provenance
# (title, vendor, licenses), build invocation holds dynamic provenance
# (commit SHA, timestamp, base digest). Checking the Dockerfile into
# source control shouldn't require bumping commit SHAs in LABEL lines.
#
# To override for a specific image, create images/<name>/Dockerfile
# and set CUSTOM_DOCKERFILE=true in image.env.

# ── Global ARGs (available to FROM lines of all stages) ──────────────
#
# Defaults are fallbacks only — build.sh always passes these from
# image.env. Keeping defaults suppresses BuildKit's
# InvalidDefaultArgInFrom warning for bare `docker build .` runs.
ARG UPSTREAM_REGISTRY=docker.io/library
ARG UPSTREAM_IMAGE=nginx
# Pinned default for safety; build.sh always overrides via --build-arg from image.env
ARG UPSTREAM_TAG=1.29.8-alpine
ARG INJECT_CERTS=false
ARG REMEDIATE=false
ARG ORIGINAL_USER=root
ARG APK_MIRROR=""
ARG APT_MIRROR=""

# ── Upstream base ────────────────────────────────────────────────────
FROM ${UPSTREAM_REGISTRY}/${UPSTREAM_IMAGE}:${UPSTREAM_TAG} AS base

# ── Label policy: preserve upstream, append ours ─────────────────────
#
# No static LABEL lines. Docker's label inheritance model is "later
# LABELs override earlier ones by key" — so any LABEL we wrote would
# silently clobber whatever the upstream image already carried.
# All labels are added via `docker build --label ...` in build.sh.

# ── Cert injection (optional) ────────────────────────────────────────
# When INJECT_CERTS=true, copy everything from certs/ into the system
# trust store. The raw append to ca-certificates.crt covers Alpine and
# distroless cases where `update-ca-certificates` isn't present; the
# later `update-ca-certificates` call rebuilds the merged bundle on
# Debian/Ubuntu/RHEL-family images.
FROM base AS certs-false

FROM base AS certs-true
USER root
COPY certs/ /tmp/certs/
RUN set -eux; \
    found=0; \
    for f in /tmp/certs/*.crt /tmp/certs/*.pem; do \
      [ -f "$f" ] || continue; \
      cat "$f" >> /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true; \
      cat "$f" >> /etc/ssl/cert.pem 2>/dev/null || true; \
      found=$((found + 1)); \
    done; \
    echo "Injected ${found} CA cert(s)"; \
    rm -rf /tmp/certs; \
    if command -v update-ca-certificates >/dev/null 2>&1; then \
      update-ca-certificates 2>/dev/null || true; \
    fi

ARG INJECT_CERTS
FROM certs-${INJECT_CERTS} AS with-certs

# ── CVE remediation (optional) ──────────────────────────────────────
# When REMEDIATE=true, runs images/<name>/remediate.sh (materialised
# by build.sh from either a per-image override or the distro default
# at scripts/remediate/${DISTRO}.sh).
FROM with-certs AS remediate-false

FROM with-certs AS remediate-true
ARG IMAGE_DIR=""
ARG APK_MIRROR
ARG APT_MIRROR
USER root
# Inject CA certs BEFORE remediation so apk/apt trust internal mirrors.
# This runs regardless of INJECT_CERTS — the flag controls whether certs
# persist in the FINAL shipped image, but the build always needs to trust
# the mirror during package upgrades.
COPY certs/ /tmp/build-certs/
RUN set -eux; \
    for f in /tmp/build-certs/*.crt /tmp/build-certs/*.pem; do \
      [ -f "$f" ] || continue; \
      cat "$f" >> /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true; \
    done; \
    rm -rf /tmp/build-certs
COPY images/${IMAGE_DIR}/remediate.sh /tmp/remediate.sh
RUN set -eux; \
    chmod +x /tmp/remediate.sh; \
    APK_MIRROR="${APK_MIRROR}" APT_MIRROR="${APT_MIRROR}" \
      /tmp/remediate.sh; \
    rm -f /tmp/remediate.sh

ARG REMEDIATE
FROM remediate-${REMEDIATE} AS final

# Restore whatever USER the upstream image ran as.
ARG ORIGINAL_USER
USER ${ORIGINAL_USER}
