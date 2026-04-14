#!/usr/bin/env bash
# Add a new image to the repo, or regenerate all ci.yml files from template
#
# Usage:
#   ./scripts/add-image.sh <image-name>    # Add new image (scaffolds directory)
#   ./scripts/add-image.sh --regenerate    # Regenerate all ci.yml from template
#
# Examples:
#   ./scripts/add-image.sh redis
#   ./scripts/add-image.sh coredns
#   ./scripts/add-image.sh --regenerate

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
TEMPLATE="${REPO_ROOT}/.ci/image-ci.yml.template"
GITLAB_CI="${REPO_ROOT}/.gitlab-ci.yml"

# ── Generate ci.yml from template ─────────────────────────────────────

generate_ci() {
  local NAME="$1"
  local OUTPUT="${REPO_ROOT}/images/${NAME}/ci.yml"

  sed "s/__IMAGE__/${NAME}/g" "${TEMPLATE}" > "${OUTPUT}"
  echo "  Generated: images/${NAME}/ci.yml"
}

# ── Regenerate all ────────────────────────────────────────────────────

if [ "${1:-}" = "--regenerate" ]; then
  echo "Regenerating all ci.yml files from .ci/image-ci.yml.template"
  for DIR in "${REPO_ROOT}"/images/*/; do
    NAME="$(basename "${DIR}")"
    # Match either the committed template or a local override
    if [ -f "${DIR}/image.env.example" ] || [ -f "${DIR}/image.env" ]; then
      generate_ci "${NAME}"
    fi
  done
  echo "Done. Review changes with: git diff"
  exit 0
fi

# ── Add new image ─────────────────────────────────────────────────────

if [ $# -eq 0 ] || [ "${1:-}" = "--help" ]; then
  cat <<EOF
Usage: $(basename "$0") <image-name>
       $(basename "$0") --regenerate

Adds a new image directory with scaffolded files, or regenerates
all ci.yml files from the template.

Steps performed for a new image:
  1. Creates images/<name>/image.env (edit this with your image details)
  2. Generates images/<name>/ci.yml from .ci/image-ci.yml.template
  3. Adds include line to .gitlab-ci.yml

After running, edit images/<name>/image.env with the correct TAG and SOURCE.
EOF
  exit 0
fi

NAME="$1"
IMAGE_DIR="${REPO_ROOT}/images/${NAME}"

if [ -d "${IMAGE_DIR}" ]; then
  echo "ERROR: images/${NAME}/ already exists" >&2
  exit 1
fi

echo "Adding image: ${NAME}"

# Create directory
mkdir -p "${IMAGE_DIR}"

# Scaffold image.env.example (versioned template — image.env is gitignored)
cat > "${IMAGE_DIR}/image.env.example" << ENVEOF
# ${NAME} — TODO: add upstream URL here

# ── Required: pull and build ──────────────────────────────────────────
IMAGE_NAME="${NAME}"
TAG="TODO"
# DISTRO controls which remediation script is applied when REMEDIATE=true.
# One of: alpine, debian, ubuntu, ubi, busybox, scratch
DISTRO="TODO"
SOURCE="\${PULL_REGISTRY}/docker-hub/library/${NAME}"

# ── Optional: registry destination ───────────────────────────────────
# PUSH_PROJECT="myproject"

# ── Optional: custom labels ──────────────────────────────────────────
# Create images/${NAME}/labels.env with one key=value per line.

# ── Optional: enrichment ─────────────────────────────────────────────
# REMEDIATE="true"
# ORIGINAL_USER="root"
# INJECT_CERTS="false"
ENVEOF
echo "  Created:   images/${NAME}/image.env.example (edit TAG, DISTRO and SOURCE)"
echo "  Tip:       cp images/${NAME}/image.env.example images/${NAME}/image.env"
echo "             to customize locally — image.env is gitignored."

# Generate ci.yml from template
generate_ci "${NAME}"

# Add include to .gitlab-ci.yml if not already present
INCLUDE_LINE="  - local: 'images/${NAME}/ci.yml'"
if ! grep -qF "${INCLUDE_LINE}" "${GITLAB_CI}"; then
  # Find the last per-image include line number and insert after it
  LAST_LINE=$(grep -n "local: 'images/" "${GITLAB_CI}" | tail -1 | cut -d: -f1)
  if [ -n "${LAST_LINE}" ]; then
    # Use python3 for portable line insertion (avoids macOS/GNU sed differences)
    python3 << PYEOF
lines = open("${GITLAB_CI}").readlines()
lines.insert(${LAST_LINE}, "  - local: 'images/${NAME}/ci.yml'\n")
open("${GITLAB_CI}", "w").writelines(lines)
PYEOF
    echo "  Added:     include in .gitlab-ci.yml"
  else
    echo "  WARN: Could not find include block in .gitlab-ci.yml"
    echo "  Add manually: ${INCLUDE_LINE}"
  fi
else
  echo "  Skipped:   include already in .gitlab-ci.yml"
fi

echo ""
echo "Next steps:"
echo "  1. Edit images/${NAME}/image.env — set TAG and SOURCE"
echo "  2. git add images/${NAME}/ .gitlab-ci.yml"
echo "  3. git commit && git push"
