#!/usr/bin/env bash
# Agnostic container image build script
#
# Reads global.env + images/<name>/image.env and builds the promoted image
# locally using Docker. Can optionally push to a registry.
#
# Usage:
#   ./scripts/build.sh <image-name> [--push]
#
# Examples:
#   ./scripts/build.sh prometheus          # Build locally
#   ./scripts/build.sh prometheus --push   # Build and push
#   ./scripts/build.sh --list              # List available images
#
# Variable naming matches the container-image-template repo:
#   UPSTREAM_REGISTRY, UPSTREAM_IMAGE, UPSTREAM_TAG — upstream source
#   In image.env files these replace the legacy SOURCE/TAG variables.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"

# ── Helpers ──────────────────────────────────────────────────────────

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

resolve_image_env() {
  local dir="$1"
  if [ -f "${dir}/image.env" ]; then
    printf '%s' "${dir}/image.env"
  elif [ -f "${dir}/image.env.example" ]; then
    printf '%s' "${dir}/image.env.example"
  else
    return 1
  fi
}

emit_build_env() {
  local full_image="$1" digest="$2"
  local tag="${full_image##*:}"
  local name="${full_image%:*}"
  local image_digest="${full_image}"
  [ -n "${digest}" ] && image_digest="${name}@${digest}"

  # Export so downstream in-process steps (e.g. SBOM generation at the
  # end of the orchestrator) can read them without re-parsing
  # build.env. Matches the template-repo contract.
  export IMAGE_REF="${full_image}"
  export IMAGE_DIGEST="${image_digest}"

  cat > "${REPO_ROOT}/build.env" <<BUILDENV
IMAGE_REF=${full_image}
IMAGE_NAME=${name}
IMAGE_TAG=${tag}
BUILDKIT_TAG=${tag}
IMAGE_DIGEST=${image_digest}
TRIVY_IMAGE=${image_digest}
SYFT_IMAGE=${image_digest}
UPSTREAM_TAG=${UPSTREAM_TAG}
UPSTREAM_REF=${UPSTREAM_REF}
BASE_DIGEST=${BASE_DIGEST:-}
GIT_SHA=${GIT_SHA}
CREATED=${BUILD_DATE}
BUILDENV
  echo "  build.env:    ${REPO_ROOT}/build.env"
}

extract_push_digest() {
  local digest
  digest=$(printf '%s' "$1" | grep -oE 'sha256:[0-9a-f]{64}' | head -1)
  if [ -z "${digest}" ]; then
    digest=$(printf '%s' "$1" | awk '/digest: sha256:/{print $3}' | head -1)
  fi
  printf '%s' "${digest}"
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <image-name> [--push | --dry-run]
       $(basename "$0") --list
       $(basename "$0") --help

Builds a promoted container image from images/<name>/.

Options:
  --push       Push the built image after building (respects REGISTRY_KIND)
  --dry-run    Resolve config + base digest, print the report block,
               stop before docker build. No image produced. Useful for
               "what would this build with my current env?"
  --list       List all available images under images/
  --help, -h   Show this help message

Customisation (fork-owned, no template edits required):

  images/<name>/remediate.sh     per-image remediation override (falls
                                 back to scripts/remediate/\${DISTRO}.sh
                                 when absent). Runs inside the image.
  images/<name>/labels.env       per-image LABEL key=value lines, added
                                 to the image's OCI labels.
  images/<name>/Dockerfile       per-image custom Dockerfile. Used only
                                 when CUSTOM_DOCKERFILE=true in the
                                 per-image image.env; otherwise the
                                 shared root Dockerfile is used.

All behavioural toggles are env-driven. See global.env.example (shared)
and images/<name>/image.env.example (per-image) for the full list.
Commonly-used:

  REGISTRY_KIND=artifactory   use scripts/push-backends/artifactory.sh
  REMEDIATE=false             skip scripts/remediate/\${DISTRO}.sh
  INJECT_CERTS=true           bake certs/*.crt into the trust store
  CUSTOM_DOCKERFILE=true      use images/<name>/Dockerfile over the root
  SBOM_GENERATE=true          emit <image>-<tag>.cdx.json after build
  ARTIFACTORY_PRO=true        enable Pro-tier push path
  ARTIFACTORY_XRAY_PRESCAN=true
                              jf docker scan BEFORE push (admin gate)
  ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS=true
                              fail build on Xray policy violation
EOF
  exit "${1:-0}"
}

list_images() {
  # shellcheck source=/dev/null
  source "$(resolve_global_env)"
  echo "Available images:"
  for dir in "${REPO_ROOT}"/images/*/; do
    name="$(basename "${dir}")"
    env_file="$(resolve_image_env "${dir%/}")" || continue
    (
      # shellcheck source=/dev/null
      source "${env_file}"
      flags=""
      [ "${REMEDIATE:-false}"    = "true" ] && flags="${flags} [+remediate:${DISTRO:-?}]"
      [ "${INJECT_CERTS:-false}" = "true" ] && flags="${flags} [+certs]"
      printf "  %-20s %s/%s:%s%s\n" "${name}" "${UPSTREAM_REGISTRY}" "${UPSTREAM_IMAGE}" "${UPSTREAM_TAG}" "${flags}"
    )
  done
  exit 0
}

# ── Argument parsing ─────────────────────────────────────────────────

[ $# -eq 0 ] && usage 1

PUSH=false
DRY_RUN=false
IMAGE=""

for arg in "$@"; do
  case "${arg}" in
    --push)     PUSH=true ;;
    --dry-run)  DRY_RUN=true ;;
    --list)     list_images ;;
    --help|-h)  usage 0 ;;
    -*)         echo "ERROR: unknown option: ${arg}" >&2; echo "" >&2; usage 1 >&2 ;;
    *)          IMAGE="${arg}" ;;
  esac
done

if [ "${PUSH}" = "true" ] && [ "${DRY_RUN}" = "true" ]; then
  echo "ERROR: --push and --dry-run are mutually exclusive" >&2
  echo "" >&2
  usage 1 >&2
fi

[ -z "${IMAGE}" ] && { echo "ERROR: Image name required" >&2; usage 1; }

# ── Load configuration ──────────────────────────────────────────────

IMAGE_DIR="${REPO_ROOT}/images/${IMAGE}"

if [ ! -d "${IMAGE_DIR}" ]; then
  echo "ERROR: Image directory not found: images/${IMAGE}/" >&2
  echo "Run '$(basename "$0") --list' to see available images" >&2
  exit 1
fi

IMAGE_ENV_FILE="$(resolve_image_env "${IMAGE_DIR}")" || {
  echo "ERROR: Missing image.env and image.env.example in images/${IMAGE}/" >&2
  exit 1
}

# Config precedence (highest wins):
#   1. Shell environment (export VAR=… before invoking build.sh, or CI vars)
#   2. images/<name>/image.env
#   3. global.env
__SHELL_OVERRIDES=""
for __v in \
  PULL_REGISTRY PUSH_REGISTRY PUSH_PROJECT VENDOR AUTHORS \
  DOCKERHUB_MIRROR GHCR_MIRROR QUAY_MIRROR \
  APK_MIRROR APT_MIRROR \
  PROD_PUSH_REGISTRY PROD_PUSH_PROJECT \
  IMAGE_NAME UPSTREAM_REGISTRY UPSTREAM_IMAGE UPSTREAM_TAG DISTRO \
  REMEDIATE INJECT_CERTS ORIGINAL_USER CUSTOM_DOCKERFILE \
  VAULT_KV_MOUNT VAULT_CA_PATH CA_CERT \
  REGISTRY_KIND \
  ARTIFACTORY_URL ARTIFACTORY_USER ARTIFACTORY_PASSWORD ARTIFACTORY_TOKEN \
  ARTIFACTORY_PRO ARTIFACTORY_PROJECT \
  ARTIFACTORY_TEAM ARTIFACTORY_ENVIRONMENT \
  ARTIFACTORY_BUILD_NAME ARTIFACTORY_BUILD_NUMBER ARTIFACTORY_PROPERTIES \
  ARTIFACTORY_SBOM_REPO ARTIFACTORY_GRYPE_DB_REPO \
  ARTIFACTORY_PUSH_HOST ARTIFACTORY_IMAGE_REF ARTIFACTORY_MANIFEST_PATH \
  ARTIFACTORY_XRAY_FAIL_ON_VIOLATIONS \
  ARTIFACTORY_XRAY_PRESCAN ARTIFACTORY_XRAY_POSTSCAN \
  CRANE_URL SYFT_INSTALLER_URL SYFT_VERSION \
  SBOM_GENERATE SBOM_TARGET SBOM_FILE
do
  if [ "${!__v+set}" = "set" ]; then
    __SHELL_OVERRIDES="${__SHELL_OVERRIDES}${__v}=$(printf '%q' "${!__v}")"$'\n'
  fi
done
unset __v

# shellcheck source=/dev/null
source "$(resolve_global_env)"
# shellcheck source=/dev/null
source "${IMAGE_ENV_FILE}"

if [ -n "${__SHELL_OVERRIDES}" ]; then
  while IFS= read -r __line; do
    [ -z "${__line}" ] && continue
    eval "export ${__line}"
  done <<< "${__SHELL_OVERRIDES}"
  unset __line
fi
unset __SHELL_OVERRIDES

# Required fields
: "${UPSTREAM_REGISTRY:?UPSTREAM_REGISTRY must be set in image.env}"
: "${UPSTREAM_IMAGE:?UPSTREAM_IMAGE must be set in image.env}"
: "${UPSTREAM_TAG:?UPSTREAM_TAG must be set in image.env}"

# Optional with sane defaults
IMAGE_NAME="${IMAGE_NAME:-${UPSTREAM_IMAGE}}"
DISTRO="${DISTRO:-alpine}"
REMEDIATE="${REMEDIATE:-false}"
INJECT_CERTS="${INJECT_CERTS:-false}"
ORIGINAL_USER="${ORIGINAL_USER:-root}"
VENDOR="${VENDOR:-example.com}"

# Normalise boolean env vars to lowercase so TRUE/True/true all work
# identically. The Dockerfile FROM selectors (certs-${INJECT_CERTS},
# remediate-${REMEDIATE}) MUST see lowercase values. Same pattern as
# the template repo.
REMEDIATE="$(printf '%s' "${REMEDIATE}"               | tr '[:upper:]' '[:lower:]')"
INJECT_CERTS="$(printf '%s' "${INJECT_CERTS}"          | tr '[:upper:]' '[:lower:]')"
CUSTOM_DOCKERFILE="$(printf '%s' "${CUSTOM_DOCKERFILE:-false}" | tr '[:upper:]' '[:lower:]')"
SBOM_GENERATE="$(printf '%s' "${SBOM_GENERATE:-false}" | tr '[:upper:]' '[:lower:]')"
SBOM_TARGET="$(printf '%s'   "${SBOM_TARGET:-image}"   | tr '[:upper:]' '[:lower:]')"

# ── Derived values ───────────────────────────────────────────────────

GIT_SHORT="$(git -C "${REPO_ROOT}" rev-parse --short=7 HEAD 2>/dev/null || echo "local")"
GIT_SHA="$(git -C "${REPO_ROOT}" rev-parse HEAD 2>/dev/null || echo "unknown")"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
FULL_TAG="${UPSTREAM_TAG}-${GIT_SHORT}"
UPSTREAM_REF="${UPSTREAM_REGISTRY}/${UPSTREAM_IMAGE}:${UPSTREAM_TAG}"
FULL_IMAGE="${PUSH_REGISTRY}/${PUSH_PROJECT}/${IMAGE_NAME}:${FULL_TAG}"

# Export for downstream (push backends, build.env)
export UPSTREAM_TAG UPSTREAM_REF GIT_SHA BUILD_DATE

# ── Source / URL labels ──────────────────────────────────────────────
SOURCE_URL="${CI_PROJECT_URL:-${bamboo_planRepository_1_repositoryUrl:-}}"
if [ -z "${SOURCE_URL}" ] && git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  SOURCE_URL=$(git config --get remote.origin.url 2>/dev/null || echo "")
fi

# ── Upstream base digest (optional but preferred) ───────────────────
# Used for the org.opencontainers.image.base.digest OCI label.
# Strategy (matches container-image-template):
#   1. crane digest                       — fast, manifest-only
#   2. auto-install crane from CRANE_URL  — if not on PATH
#   3. docker buildx imagetools inspect   — fallback
# Empty BASE_DIGEST is non-fatal — the build still succeeds.
# NOTE: Resolution happens AFTER the config report below so users see
# progress immediately. The placeholder "<resolving...>" in the report
# is a signal that a network call is about to run.

_build_derive_crane_url() {
  [ -n "${CRANE_URL:-}" ] && return 0
  local _os="" _arch=""
  case "$(uname -s)" in
    Linux)  _os="Linux" ;;
    Darwin) _os="Darwin" ;;
  esac
  case "$(uname -m)" in
    x86_64|amd64)   _arch="x86_64" ;;
    aarch64|arm64)  _arch="arm64" ;;
  esac
  if [ -n "${_os}" ] && [ -n "${_arch}" ]; then
    CRANE_URL="https://github.com/google/go-containerregistry/releases/download/v0.20.2/go-containerregistry_${_os}_${_arch}.tar.gz"
  fi
}

_build_install_crane() {
  command -v crane >/dev/null 2>&1 && return 0
  _build_derive_crane_url
  if [ -z "${CRANE_URL:-}" ]; then
    echo "  NOTE: crane not on PATH and CRANE_URL not set — skipping install" >&2
    echo "        (will fall back to docker buildx imagetools inspect)" >&2
    return 1
  fi
  echo "→ crane not on PATH — installing from ${CRANE_URL}"
  mkdir -p "${REPO_ROOT}/.bin"
  if curl -fSL --progress-bar --max-time 120 "${CRANE_URL}" \
       | tar xz -C "${REPO_ROOT}/.bin" crane 2>/dev/null \
     && [ -x "${REPO_ROOT}/.bin/crane" ]; then
    export PATH="${REPO_ROOT}/.bin:${PATH}"
    echo "  ✓ crane installed to ${REPO_ROOT}/.bin/crane"
    return 0
  fi
  echo "  WARN: crane install failed — URL unreachable or tarball invalid" >&2
  echo "        (will fall back to docker buildx imagetools inspect)" >&2
  return 1
}

_build_resolve_base_digest() {
  BASE_DIGEST=""
  _build_install_crane || true

  if command -v crane >/dev/null 2>&1; then
    echo "→ Resolving upstream digest: crane digest ${UPSTREAM_REF}"
    local _out _rc
    _out=$(crane digest "${UPSTREAM_REF}" 2>&1) && _rc=0 || _rc=$?
    if [ "${_rc}" -eq 0 ]; then
      BASE_DIGEST="${_out}"
      echo "  ✓ ${BASE_DIGEST}"
      return 0
    fi
    echo "  WARN: crane digest failed (rc=${_rc}) for ${UPSTREAM_REF}" >&2
    printf '%s\n' "${_out}" | head -2 | sed 's/^/        /' >&2
  fi

  if command -v docker >/dev/null 2>&1; then
    echo "→ Resolving upstream digest: docker buildx imagetools inspect ${UPSTREAM_REF}"
    BASE_DIGEST=$(docker buildx imagetools inspect "${UPSTREAM_REF}" --format '{{.Digest}}' 2>/dev/null || echo "")
    if [ -n "${BASE_DIGEST}" ]; then
      echo "  ✓ ${BASE_DIGEST}"
      return 0
    fi
    echo "  WARN: docker buildx imagetools inspect also failed" >&2
    echo "        (base.digest label will be empty — image build unaffected)" >&2
  fi
}

# ── Preflight: materialise remediate.sh ──────────────────────────────
REMEDIATE_CLEANUP=""

if [ "${REMEDIATE}" = "true" ]; then
  if [ -z "${DISTRO}" ]; then
    echo "ERROR: DISTRO not set in images/${IMAGE}/image.env (required when REMEDIATE=true)" >&2
    exit 1
  fi
  if [ -f "${IMAGE_DIR}/remediate.sh" ]; then
    echo "  Remediation:  images/${IMAGE}/remediate.sh (per-image)"
  elif [ -f "${REPO_ROOT}/scripts/remediate/${DISTRO}.sh" ]; then
    cp "${REPO_ROOT}/scripts/remediate/${DISTRO}.sh" "${IMAGE_DIR}/remediate.sh"
    REMEDIATE_CLEANUP="${IMAGE_DIR}/remediate.sh"
    echo "  Remediation:  scripts/remediate/${DISTRO}.sh (distro default)"
  else
    echo "ERROR: REMEDIATE=true but scripts/remediate/${DISTRO}.sh not found" >&2
    echo "       Available: $(ls "${REPO_ROOT}/scripts/remediate/" | sed 's/\.sh$//' | tr '\n' ' ')" >&2
    exit 1
  fi
elif [ ! -f "${IMAGE_DIR}/remediate.sh" ]; then
  printf '#!/bin/sh\nexit 0\n' > "${IMAGE_DIR}/remediate.sh"
  REMEDIATE_CLEANUP="${IMAGE_DIR}/remediate.sh"
fi

# Select Dockerfile: custom per-image or shared root
if [ "${CUSTOM_DOCKERFILE}" = "true" ] && [ -f "${IMAGE_DIR}/Dockerfile" ]; then
  DOCKERFILE="${IMAGE_DIR}/Dockerfile"
else
  DOCKERFILE="${REPO_ROOT}/Dockerfile"
fi

# ── Cert materialisation ────────────────────────────────────────────
mkdir -p "${REPO_ROOT}/certs"
CERTS_CLEANUP=""
# shellcheck disable=SC2064
trap '
  [ -n "${REMEDIATE_CLEANUP}" ] && rm -f "${REMEDIATE_CLEANUP}"
  [ -n "${CERTS_CLEANUP}" ]     && rm -f "${CERTS_CLEANUP}"
' EXIT

if [ -n "${CA_CERT:-}" ]; then
  echo "${CA_CERT}" > "${REPO_ROOT}/certs/ci-injected.crt"
  echo "  CA cert:      injected from CA_CERT env var"
  INJECT_CERTS=true
elif [ -n "${VAULT_CA_PATH:-}" ] && command -v vault >/dev/null 2>&1; then
  if vault kv get -mount="${VAULT_KV_MOUNT:-secret}" \
       -field=certificate "${VAULT_CA_PATH}" \
       > "${REPO_ROOT}/certs/vault-ca.crt" 2>/dev/null; then
    echo "  CA cert:      pulled from Vault (${VAULT_KV_MOUNT:-secret}/${VAULT_CA_PATH})"
    INJECT_CERTS=true
  else
    echo "  WARN: Vault pull failed — falling back to certs/ on disk" >&2
    rm -f "${REPO_ROOT}/certs/vault-ca.crt"
  fi
fi

if [ "${INJECT_CERTS}" = "true" ]; then
  if ! ls "${REPO_ROOT}"/certs/*.crt >/dev/null 2>&1 && \
     ! ls "${REPO_ROOT}"/certs/*.pem >/dev/null 2>&1; then
    echo "ERROR: INJECT_CERTS=true but no .crt/.pem files in certs/" >&2
    exit 1
  fi
  echo "  Certs found:  $(ls "${REPO_ROOT}"/certs/*.crt "${REPO_ROOT}"/certs/*.pem 2>/dev/null | wc -l | tr -d ' ') file(s)"
fi

# Ensure certs/ has at least a .gitkeep so COPY certs/ doesn't fail
: > "${REPO_ROOT}/certs/.gitkeep"

# ── Build ────────────────────────────────────────────────────────────
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

echo ""
echo "=========================================="
echo "  container-images build"
echo "=========================================="
echo "  Image:              ${FULL_IMAGE}"
echo "  Upstream:           ${UPSTREAM_REF}"
echo "  Upstream digest:    <resolving...>"
echo "  Git commit:         ${GIT_SHORT} (${GIT_SHA})"
echo "  Created (UTC):      ${BUILD_DATE}"
echo "  Distro:             ${DISTRO}"
echo "  Remediate:          ${REMEDIATE}$([ "${REMEDIATE}" = "true" ] && echo " (${DISTRO})" || echo "")"
echo "  Inject certs:       ${INJECT_CERTS}"
echo "  Original user:      ${ORIGINAL_USER}"
echo "  Vendor:             ${VENDOR}"
echo "=========================================="
echo ""

# Resolve base digest AFTER the report so user sees config immediately
# and understands the network call is about to run.
_build_resolve_base_digest

# --dry-run stops here: config resolved, digest fetched, no image built.
if [ "${DRY_RUN}" = "true" ]; then
  echo ""
  echo "→ --dry-run: stopping before docker build"
  exit 0
fi

BUILD_ARGS=(
  --build-arg "UPSTREAM_REGISTRY=${UPSTREAM_REGISTRY}"
  --build-arg "UPSTREAM_IMAGE=${UPSTREAM_IMAGE}"
  --build-arg "UPSTREAM_TAG=${UPSTREAM_TAG}"
  --build-arg "INJECT_CERTS=${INJECT_CERTS}"
  --build-arg "REMEDIATE=${REMEDIATE}"
  --build-arg "ORIGINAL_USER=${ORIGINAL_USER}"
  --build-arg "IMAGE_DIR=${IMAGE}"
  --build-arg "APK_MIRROR=${APK_MIRROR:-}"
  --build-arg "APT_MIRROR=${APT_MIRROR:-}"
)

LABEL_ARGS=(
  --label "org.opencontainers.image.vendor=${VENDOR}"
  --label "org.opencontainers.image.authors=${AUTHORS:-Platform Engineering}"
  --label "org.opencontainers.image.created=${BUILD_DATE}"
  --label "org.opencontainers.image.revision=${GIT_SHA}"
  --label "org.opencontainers.image.version=${FULL_TAG}"
  --label "org.opencontainers.image.ref.name=${FULL_TAG}"
  --label "org.opencontainers.image.base.name=${UPSTREAM_REF}"
  --label "promoted.from=${UPSTREAM_REF}"
  --label "promoted.tag=${FULL_TAG}"
)
if [ -n "${BASE_DIGEST}" ]; then
  LABEL_ARGS+=(--label "org.opencontainers.image.base.digest=${BASE_DIGEST}")
fi
if [ -n "${SOURCE_URL:-}" ]; then
  LABEL_ARGS+=(--label "org.opencontainers.image.source=${SOURCE_URL}")
  LABEL_ARGS+=(--label "org.opencontainers.image.url=${SOURCE_URL}")
fi

# shellcheck disable=SC2086
docker build \
  "${BUILD_ARGS[@]}" \
  "${LABEL_ARGS[@]}" \
  ${LABEL_FLAGS} \
  -t "${FULL_IMAGE}" \
  -f "${DOCKERFILE}" \
  "${REPO_ROOT}"

echo ""
echo "Built: ${FULL_IMAGE}"

echo ""
echo "=== OCI Labels ==="
docker inspect "${FULL_IMAGE}" --format='{{json .Config.Labels}}' | python3 -m json.tool 2>/dev/null || \
  docker inspect "${FULL_IMAGE}" --format='{{json .Config.Labels}}'

# ── Push (optional) ──────────────────────────────────────────────────

if [ "${PUSH}" = "true" ]; then
  if [ -n "${REGISTRY_KIND:-}" ]; then
    BACKEND_SCRIPT="${REPO_ROOT}/scripts/push-backends/${REGISTRY_KIND}.sh"
    if [ ! -f "${BACKEND_SCRIPT}" ]; then
      echo "ERROR: unknown REGISTRY_KIND='${REGISTRY_KIND}'" >&2
      exit 1
    fi
    # shellcheck source=/dev/null
    source "${BACKEND_SCRIPT}"
    push_to_backend "${FULL_IMAGE}"
  else
    echo ""
    echo "=== Pushing to ${PUSH_REGISTRY} ==="
    PUSH_OUTPUT=$(docker push "${FULL_IMAGE}" 2>&1) || {
      echo "${PUSH_OUTPUT}" >&2
      echo "ERROR: docker push failed" >&2
      exit 1
    }
    echo "${PUSH_OUTPUT}"
    PUSH_DIGEST=$(extract_push_digest "${PUSH_OUTPUT}")
    emit_build_env "${FULL_IMAGE}" "${PUSH_DIGEST}"
    if [ -n "${PUSH_DIGEST}" ]; then
      echo "Pushed: ${FULL_IMAGE%:*}@${PUSH_DIGEST}"
    else
      echo "Pushed: ${FULL_IMAGE} (no digest captured)"
    fi
  fi
fi

# ════════════════════════════════════════════════════════════════════
# SBOM generation (opt-in, decoupled from shipping)
# ════════════════════════════════════════════════════════════════════
# Matches the template repo's scripts/build.sh shape. Off by default
# on purpose — the CI pipeline already has a dedicated `sbom` stage in
# .gitlab-ci.yml that does this against the pushed digest, and a
# separate `sbom-ingest` stage that ships via scripts/sbom-post.sh.
# Running both would duplicate work.
#
# Turn SBOM_GENERATE=true on for local dev or forks without the CI
# sbom stage. SBOM_TARGET=image (default) scans the built/pushed
# image; SBOM_TARGET=source scans the working directory instead —
# useful for Ansible / pip / npm source builds.
#
# Shipping stays the domain of scripts/sbom-post.sh as a standalone
# stage — do not chain it here.

_build_install_syft() {
  command -v syft >/dev/null 2>&1 && return 0
  local _url="${SYFT_INSTALLER_URL:-https://raw.githubusercontent.com/anchore/syft/main/install.sh}"
  local _ver="${SYFT_VERSION:-v1.14.0}"
  echo ""
  echo "→ syft not on PATH — installing ${_ver} from ${_url}"
  mkdir -p "${REPO_ROOT}/.bin"
  if curl -fsSL --max-time 120 "${_url}" \
       | sh -s -- -b "${REPO_ROOT}/.bin" "${_ver}" >/dev/null 2>&1 \
     && [ -x "${REPO_ROOT}/.bin/syft" ]; then
    export PATH="${REPO_ROOT}/.bin:${PATH}"
    echo "  ✓ syft installed"
    return 0
  fi
  echo "  WARN: syft install failed — skipping SBOM generation" >&2
  return 1
}

_build_generate_sbom() {
  [ "${SBOM_GENERATE}" = "true" ] || return 0

  _build_install_syft || return 0
  command -v syft >/dev/null 2>&1 || return 0

  local basename scan_target
  basename="${IMAGE_NAME##*/}-${FULL_TAG}"
  SBOM_FILE="${SBOM_FILE:-${basename}.cdx.json}"

  case "${SBOM_TARGET}" in
    source)  scan_target="dir:${REPO_ROOT}" ;;
    image|*) scan_target="${IMAGE_DIGEST:-${FULL_IMAGE}}" ;;
  esac

  echo ""
  echo "→ syft: generating CycloneDX SBOM for ${scan_target}"
  if ! syft "${scan_target}" -o cyclonedx-json="${SBOM_FILE}"; then
    echo "  WARN: syft failed — no SBOM produced" >&2
    return 0
  fi

  echo "→ SBOM: ${SBOM_FILE} ($(wc -c < "${SBOM_FILE}") bytes)"
  if command -v jq >/dev/null 2>&1; then
    echo "        components: $(jq '.components | length' "${SBOM_FILE}")"
  fi
  if [ -f "${REPO_ROOT}/build.env" ] && ! grep -q "^SBOM_FILE=" "${REPO_ROOT}/build.env"; then
    echo "SBOM_FILE=${SBOM_FILE}" >> "${REPO_ROOT}/build.env"
  fi
  echo "  (ship via scripts/sbom-post.sh ${SBOM_FILE} in a separate stage)"
}

_build_generate_sbom
