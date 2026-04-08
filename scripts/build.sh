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
  echo "Available images:"
  for dir in "${REPO_ROOT}"/images/*/; do
    name="$(basename "${dir}")"
    if [ -f "${dir}/image.env" ]; then
      # shellcheck source=/dev/null
      source "${dir}/image.env"
      certs_flag=""
      [ "${INJECT_CERTS:-false}" = "true" ] && certs_flag=" [+certs]"
      printf "  %-20s %s%s\n" "${name}" "${SOURCE}:${TAG}" "${certs_flag}"
    fi
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
source "${REPO_ROOT}/global.env"
# shellcheck source=/dev/null
source "${IMAGE_DIR}/image.env"

# ── Derived values ────────────────────────────────────────────────────

GIT_SHORT_SHA="$(git -C "${REPO_ROOT}" rev-parse --short HEAD 2>/dev/null || echo "local")"
GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")"
PROMOTED_TAG="${TAG}-${GIT_SHORT_SHA}"
FULL_IMAGE="${REGISTRY}/${REGISTRY_PROJECT}/${IMAGE_NAME}:${PROMOTED_TAG}"
BASE_IMAGE="${SOURCE}:${TAG}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

# Preflight: validate remediate.sh exists if REMEDIATE=true
if [ "${REMEDIATE:-false}" = "true" ] && [ ! -f "${IMAGE_DIR}/remediate.sh" ]; then
  echo "ERROR: REMEDIATE=true but ${IMAGE_DIR}/remediate.sh does not exist" >&2
  echo "Create the script or set REMEDIATE=false in image.env" >&2
  exit 1
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
  --build-arg "TAG=${TAG}" \
  --build-arg "APP_VERSION=${PROMOTED_TAG}" \
  --build-arg "VENDOR=${VENDOR:-}" \
  --build-arg "VCS_REF=${GIT_SHA}" \
  --build-arg "BUILD_DATE=${BUILD_DATE}" \
  --build-arg "REMEDIATE=${REMEDIATE:-false}" \
  --build-arg "IMAGE_DIR=images/${IMAGE}" \
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
  echo "=== Pushing to ${REGISTRY} ==="
  docker push "${FULL_IMAGE}"
  echo "Pushed: ${FULL_IMAGE}"
fi
