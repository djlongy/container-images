# Shared promotion Dockerfile — used by all images unless overridden
#
# Features (controlled via build args from image.env):
#   - Promotion labels (always — only adds ours, never overwrites upstream)
#   - CVE remediation (opt-in via REMEDIATE=true + remediate.sh script)
#   - CA certificate injection (opt-in via INJECT_CERTS=true)
#
# Feature selection (Docker only builds stages that feed the final FROM):
#   REMEDIATE=false, INJECT_CERTS=false → base only (labels, zero extra layers)
#   REMEDIATE=true,  INJECT_CERTS=false → base + remediation patches
#   REMEDIATE=false, INJECT_CERTS=true  → base + merged cert bundle
#   REMEDIATE=true,  INJECT_CERTS=true  → base + remediation + certs
#
# Label philosophy:
#   - Upstream labels are INHERITED and never overwritten.
#   - We only ADD: build provenance, promotion metadata, custom labels.
#
# To override for a specific image, create images/<name>/Dockerfile
# and set CUSTOM_DOCKERFILE=true in image.env.
#
# ── ARG override order (highest priority wins) ───────────────────────
#
#   1. --build-arg passed by CI/build.sh  (from image.env values)
#   2. ARG default in this Dockerfile     (fallback only)
#
#   The defaults below (false, "") are safety nets — they are ALWAYS
#   overridden at build time by the CI template or build.sh, which
#   sources the per-image image.env and passes each value explicitly.
#
#   If you see REMEDIATE=false here but a build runs remediation,
#   it's because image.env set REMEDIATE="true" and the build system
#   passed --build-arg REMEDIATE=true, which takes priority.
# ─────────────────────────────────────────────────────────────────────

ARG BASE_IMAGE                  # Set by CI/build.sh from SOURCE:TAG
ARG INJECT_CERTS=false          # Overridden per image via image.env
ARG REMEDIATE=false             # Overridden per image via image.env

# ── Stage: extract upstream cert bundle ───────────────────────────────
FROM ${BASE_IMAGE} AS upstream-certs

# ── Stage: build merged cert bundle ──────────────────────────────────
FROM alpine:3.21 AS certs
RUN apk add --no-cache ca-certificates
COPY --from=upstream-certs /etc/ssl/certs/ca-certificates.crt /tmp/upstream-bundle.crt
RUN cat /tmp/upstream-bundle.crt >> /etc/ssl/certs/ca-certificates.crt 2>/dev/null || true
COPY certs/*.crt /usr/local/share/ca-certificates/
RUN update-ca-certificates

# ── Stage: base (promotion labels only) ──────────────────────────────
FROM ${BASE_IMAGE} AS base

# These ARGs are re-declared in this stage because Docker scopes ARGs
# per stage. All values are passed by CI/build.sh — defaults are fallbacks.
ARG TAG="unknown"               # Overridden from image.env
ARG BASE_IMAGE                  # Overridden from image.env (SOURCE:TAG)
ARG APP_VERSION="unknown"       # Overridden by CI (PROMOTED_TAG)
ARG VENDOR=""                   # Overridden from global.env / CI variable
ARG VCS_REF=""                  # Overridden by CI (CI_COMMIT_SHA / git rev-parse)
ARG BUILD_DATE=""               # Overridden by CI (CI_JOB_STARTED_AT / date)

LABEL org.opencontainers.image.vendor="${VENDOR}"
LABEL org.opencontainers.image.created="${BUILD_DATE}"
LABEL org.opencontainers.image.revision="${VCS_REF}"
LABEL org.opencontainers.image.ref.name="${APP_VERSION}"
LABEL org.opencontainers.image.base.name="${BASE_IMAGE}"
LABEL promoted.from="${BASE_IMAGE}"
LABEL promoted.tag="${APP_VERSION}"

# ── Stage: CVE remediation ───────────────────────────────────────────
# Runs images/<name>/remediate.sh if REMEDIATE=true.
# The script is image-specific — it knows what package manager is
# available and which packages to patch. Runs as root, restores USER.
#
# Example remediate.sh for Alpine:
#   #!/bin/sh
#   apk upgrade --no-cache libcurl openssl
#
# Example for Debian:
#   #!/bin/sh
#   apt-get update && apt-get install -y --only-upgrade libcurl4 && rm -rf /var/lib/apt/lists/*
FROM base AS base-remediated
ARG ORIGINAL_USER="root"        # Overridden from image.env
ARG IMAGE_DIR=""                # Overridden by CI/build.sh (e.g. "nginx")
USER root
COPY images/${IMAGE_DIR}/remediate.sh /tmp/remediate.sh
RUN chmod +x /tmp/remediate.sh && /tmp/remediate.sh && rm -f /tmp/remediate.sh
USER ${ORIGINAL_USER}

# ── Stage: base + merged certs ───────────────────────────────────────
FROM base AS base-certs-only
ARG ORIGINAL_USER="root"
USER root
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER ${ORIGINAL_USER}

# ── Stage: remediated + certs ────────────────────────────────────────
FROM base-remediated AS base-remediated-certs
ARG ORIGINAL_USER="root"
USER root
COPY --from=certs /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
USER ${ORIGINAL_USER}

# ── Final: select based on REMEDIATE and INJECT_CERTS ────────────────
# 4 combinations: false-false, false-true, true-false, true-true
FROM base              AS final-false-false
FROM base-certs-only   AS final-false-true
FROM base-remediated   AS final-true-false
FROM base-remediated-certs AS final-true-true
FROM final-${REMEDIATE}-${INJECT_CERTS}
