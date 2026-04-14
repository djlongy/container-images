#!/usr/bin/env bash
# Agnostic container image build script
#
# Reads global.env + images/<name>/image.env and builds the promoted image
# locally using Docker. Can optionally push to Harbor.
#
# Usage:
#   ./scripts/build.sh <image-name> [--push]
#
# Examples:
#   ./scripts/build.sh prometheus          # Build locally
#   ./scripts/build.sh prometheus --push   # Build and push to Harbor
#   ./scripts/build.sh --list              # List available images

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# Resolve which global env file to source. global.env is gitignored so
# local homelab defaults stay out of the repo; global.env.example is the
# versioned template. On first clone, copy the template:
#   cp global.env.example global.env
# and edit for your environment. CI systems can either cp in the job or
# set all variables as pipeline variables and skip the file.
resolve_global_env() {
  if [ -f "${REPO_ROOT}/global.env" ]; then
    printf '%s' "${REPO_ROOT}/global.env"
  elif [ -f "${REPO_ROOT}/global.env.example" ]; then
    printf '%s' "${REPO_ROOT}/global.env.example"
  else
    echo "ERROR: neither global.env nor global.env.example found in ${REPO_ROOT}" >&2
    exit 1
  fi
}

# ── Helpers ───────────────────────────────────────────────────────────

usage() {
  cat <<EOF
Usage: $(basename "$0") <image-name> [--push]
       $(basename "$0") --list

Builds a promoted container image from images/<name>/.

Options:
  --push    Push the built image to Harbor after building
  --list    List all available images
  --help    Show this help message
EOF
  exit "${1:-0}"
}

list_images() {
  # Source global env ONCE so ${PULL_REGISTRY} (referenced by SOURCE in
  # each image.env) expands. Each per-image source runs in a subshell so
  # variables from one image.env don't leak into the next iteration.
  # shellcheck source=/dev/null
  source "$(resolve_global_env)"
  echo "Available images:"
  for dir in "${REPO_ROOT}"/images/*/; do
    name="$(basename "${dir}")"
    [ -f "${dir}/image.env" ] || continue
    (
      # shellcheck source=/dev/null
      source "${dir}/image.env"
      flags=""
      [ "${REMEDIATE:-false}"    = "true" ] && flags="${flags} [+remediate:${DISTRO:-?}]"
      [ "${INJECT_CERTS:-false}" = "true" ] && flags="${flags} [+certs]"
      printf "  %-20s %s%s\n" "${name}" "${SOURCE}:${TAG}" "${flags}"
    )
  done
  exit 0
}

# ── Argument parsing ──────────────────────────────────────────────────

[ $# -eq 0 ] && usage 1

PUSH=false
IMAGE=""

for arg in "$@"; do
  case "${arg}" in
    --push)  PUSH=true ;;
    --list)  list_images ;;
    --help)  usage 0 ;;
    -*)      echo "Unknown option: ${arg}" >&2; usage 1 ;;
    *)       IMAGE="${arg}" ;;
  esac
done

[ -z "${IMAGE}" ] && { echo "ERROR: Image name required" >&2; usage 1; }

# ── Load configuration ───────────────────────────────────────────────

IMAGE_DIR="${REPO_ROOT}/images/${IMAGE}"

if [ ! -d "${IMAGE_DIR}" ]; then
  echo "ERROR: Image directory not found: images/${IMAGE}/" >&2
  echo "Run '$(basename "$0") --list' to see available images" >&2
  exit 1
fi

if [ ! -f "${IMAGE_DIR}/image.env" ]; then
  echo "ERROR: Missing image.env in images/${IMAGE}/" >&2
  exit 1
fi

# Source global vars then image-specific vars (image overrides global)
# shellcheck source=/dev/null
source "$(resolve_global_env)"
# shellcheck source=/dev/null
source "${IMAGE_DIR}/image.env"

# ── Derived values ────────────────────────────────────────────────────

GIT_SHORT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "local")"
GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")"
PROMOTED_TAG="${TAG}-${GIT_SHORT_SHA}"
FULL_IMAGE="${PUSH_REGISTRY}/${PUSH_PROJECT}/${IMAGE_NAME}:${PROMOTED_TAG}"
BASE_IMAGE="${SOURCE}:${TAG}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Preflight: validate DISTRO + resolve remediate.sh
#
# Each image must declare its base DISTRO in image.env (alpine, debian,
# ubuntu, ubi, busybox, scratch, …) so we know which package manager to
# drive when REMEDIATE=true. Resolution order for the script:
#
#   1. images/<name>/remediate.sh        — per-image override wins
#   2. scripts/remediate/${DISTRO}.sh    — shared distro default
#   3. Hard error if neither exists.
#
# The resolved script is copied into images/<name>/remediate.sh so the
# Dockerfile's unconditional COPY finds it at a stable path. A trap at
# the bottom of the script removes any script we materialised so it
# doesn't leak into the repo.
REMEDIATE_CLEANUP=""
trap '[ -n "${REMEDIATE_CLEANUP}" ] && rm -f "${REMEDIATE_CLEANUP}"' EXIT

if [ "${REMEDIATE:-false}" = "true" ]; then
  if [ -z "${DISTRO:-}" ]; then
    echo "ERROR: DISTRO not set in images/${IMAGE}/image.env (required when REMEDIATE=true)" >&2
    echo "Set DISTRO to one of: alpine, debian, ubuntu, ubi" >&2
    exit 1
  fi
  if [ -f "${IMAGE_DIR}/remediate.sh" ]; then
    echo "  Remediation:  images/${IMAGE}/remediate.sh (per-image)"
  elif [ -f "${REPO_ROOT}/scripts/remediate/${DISTRO}.sh" ]; then
    cp "${REPO_ROOT}/scripts/remediate/${DISTRO}.sh" "${IMAGE_DIR}/remediate.sh"
    REMEDIATE_CLEANUP="${IMAGE_DIR}/remediate.sh"
    echo "  Remediation:  scripts/remediate/${DISTRO}.sh (distro default)"
  else
    echo "ERROR: REMEDIATE=true but no remediation script found" >&2
    echo "  Expected one of:" >&2
    echo "    ${IMAGE_DIR}/remediate.sh           (per-image override)" >&2
    echo "    ${REPO_ROOT}/scripts/remediate/${DISTRO}.sh  (distro default)" >&2
    exit 1
  fi
elif [ ! -f "${IMAGE_DIR}/remediate.sh" ]; then
  # REMEDIATE=false and no per-image script — drop a no-op so the
  # Dockerfile's unconditional COPY images/<name>/remediate.sh succeeds.
  # The base-remediated stage that would execute it is pruned from the
  # final image by the multi-stage final selector.
  printf '#!/bin/sh\n# placeholder — REMEDIATE=false, this file is never executed\nexit 0\n' \
    > "${IMAGE_DIR}/remediate.sh"
  REMEDIATE_CLEANUP="${IMAGE_DIR}/remediate.sh"
fi

# Select Dockerfile: custom per-image or shared root
if [ "${CUSTOM_DOCKERFILE:-false}" = "true" ] && [ -f "${IMAGE_DIR}/Dockerfile" ]; then
  DOCKERFILE="${IMAGE_DIR}/Dockerfile"
else
  DOCKERFILE="${REPO_ROOT}/Dockerfile"
fi

# Inject CA cert — three sources, checked in order:
#   1. CA_CERT env var (CI variable or export)
#   2. HashiCorp Vault (if vault CLI available)
#   3. Files already in certs/ (manually dropped, gitignored)
mkdir -p "${REPO_ROOT}/certs"
if [ "${INJECT_CERTS:-false}" = "true" ]; then
  if [ -n "${CA_CERT:-}" ]; then
    echo "${CA_CERT}" > "${REPO_ROOT}/certs/custom-ca.crt"
    echo "  CA cert:      injected from CA_CERT env var"
  elif command -v vault >/dev/null 2>&1; then
    vault kv get -mount="${VAULT_KV_MOUNT:-secret}" -field=certificate "${VAULT_CA_PATH:-pki/root-ca}" \
      > "${REPO_ROOT}/certs/custom-ca.crt" 2>/dev/null \
      && echo "  CA cert:      pulled from Vault" \
      || echo "  WARN: Vault pull failed — falling back to certs/ on disk"
  fi
  # Check we have at least one cert to inject
  if ls "${REPO_ROOT}"/certs/*.crt >/dev/null 2>&1; then
    echo "  Certs found:  $(ls "${REPO_ROOT}"/certs/*.crt | wc -l | tr -d ' ') file(s)"
  else
    echo "  ERROR: INJECT_CERTS=true but no .crt files in certs/"
    echo "  Set CA_CERT env var, configure Vault, or drop certs into certs/"
    exit 1
  fi
fi

# ── Build ─────────────────────────────────────────────────────────────

# Build custom label flags from labels.env file (one key=value per line)
LABEL_FLAGS=""
LABELS_FILE="${IMAGE_DIR}/labels.env"
if [ -f "${LABELS_FILE}" ]; then
  while IFS= read -r LABEL || [ -n "${LABEL}" ]; do
    [ -z "${LABEL}" ] && continue
    [ "${LABEL#\#}" != "${LABEL}" ] && continue
    LABEL_FLAGS="${LABEL_FLAGS} --label ${LABEL}"
  done < "${LABELS_FILE}"
  echo "  Custom labels: ${LABELS_FILE}"
fi

echo "=== Building ${IMAGE_NAME} ==="
echo "  Source:       ${BASE_IMAGE}"
echo "  Destination:  ${FULL_IMAGE}"
echo "  Dockerfile:   ${DOCKERFILE#${REPO_ROOT}/}"
echo "  Remediate:    ${REMEDIATE:-false}"
echo "  Inject certs: ${INJECT_CERTS:-false}"
echo ""

# shellcheck disable=SC2086
docker build \
  --build-arg "BASE_IMAGE=${BASE_IMAGE}" \
  --build-arg "BUILDER_IMAGE=${BUILDER_IMAGE:-alpine:3.21}" \
  --build-arg "APK_MIRROR=${APK_MIRROR:-}" \
  --build-arg "APT_MIRROR=${APT_MIRROR:-}" \
  --build-arg "TAG=${TAG}" \
  --build-arg "APP_VERSION=${PROMOTED_TAG}" \
  --build-arg "VENDOR=${VENDOR:-}" \
  --build-arg "VCS_REF=${GIT_SHA}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  --build-arg "REMEDIATE=${REMEDIATE:-false}" \
  --build-arg "IMAGE_DIR=${IMAGE}" \
  --build-arg "INJECT_CERTS=${INJECT_CERTS:-false}" \
  --build-arg "ORIGINAL_USER=${ORIGINAL_USER:-root}" \
  ${LABEL_FLAGS} \
  -t "${FULL_IMAGE}" \
  -f "${DOCKERFILE}" \
  "${REPO_ROOT}"

echo ""
echo "Built: ${FULL_IMAGE}"

# Show labels for verification
echo ""
echo "=== OCI Labels ==="
docker inspect "${FULL_IMAGE}" --format='{{json .Config.Labels}}' | python3 -m json.tool 2>/dev/null || \
  docker inspect "${FULL_IMAGE}" --format='{{json .Config.Labels}}'

# ── Push (optional) ──────────────────────────────────────────────────

if [ "${PUSH}" = "true" ]; then
  echo ""
  echo "=== Pushing to ${PUSH_REGISTRY} ==="
  docker push "${FULL_IMAGE}"
  echo "Pushed: ${FULL_IMAGE}"
fi
