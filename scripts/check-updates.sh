#!/usr/bin/env bash
# Check for newer upstream tags for all promoted images
#
# Queries Docker Hub (or compatible v2 registry) for available tags,
# compares against the current TAG in each image.env, and reports
# available updates. Optionally opens a merge request / pull request.
#
# Usage:
#   ./scripts/check-updates.sh                    # Report only
#   ./scripts/check-updates.sh --create-mr        # GitLab: create MR per update
#   ./scripts/check-updates.sh --create-pr        # GitHub/Bitbucket: create PR per update
#
# Environment variables:
#   GITLAB_TOKEN    — GitLab API token (for --create-mr)
#   GITLAB_URL      — GitLab instance URL
#   GITLAB_PROJECT  — Project ID or path
#   GITHUB_TOKEN    — GitHub token (for --create-pr)
#   GITHUB_REPO     — owner/repo (for --create-pr)
#
# Requires: curl, jq (or python3)

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(dirname "${SCRIPT_DIR}")"
CREATE_MR=false
CREATE_PR=false

for arg in "$@"; do
  case "${arg}" in
    --create-mr) CREATE_MR=true ;;
    --create-pr) CREATE_PR=true ;;
  esac
done

# ── Helpers ───────────────────────────────────────────────────────────

# Fetch available tags from Docker Hub or compatible v2 registry
# Usage: fetch_tags <image-path>
# Example: fetch_tags "prom/prometheus" or fetch_tags "library/nginx"
fetch_tags() {
  local IMAGE_PATH="$1"

  # Docker Hub uses a different API than v2 registries
  if echo "${IMAGE_PATH}" | grep -q "docker.io\|docker-hub"; then
    # Strip any registry prefix to get the Docker Hub path
    local HUB_PATH
    HUB_PATH=$(echo "${IMAGE_PATH}" | sed 's|.*docker-hub/||;s|.*docker.io/||')
    curl -sf "https://hub.docker.com/v2/repositories/${HUB_PATH}/tags/?page_size=200&ordering=last_updated" 2>/dev/null \
      | python3 -c "
import sys, json
data = json.load(sys.stdin)
for t in data.get('results', []):
    print(t['name'])
" 2>/dev/null
  else
    # Generic v2 registry — use tags/list endpoint
    local HOST REPO_PATH
    HOST=$(echo "${IMAGE_PATH}" | cut -d/ -f1)
    REPO_PATH=$(echo "${IMAGE_PATH}" | cut -d/ -f2-)
    if [ -n "${PUSH_REGISTRY_USER:-}" ] && [ -n "${PUSH_REGISTRY_PASSWORD:-}" ]; then
      AUTH_HEADER="Basic $(echo -n "${PUSH_REGISTRY_USER}:${PUSH_REGISTRY_PASSWORD}" | base64)"
      curl -sf -H "Authorization: ${AUTH_HEADER}" \
        "https://${HOST}/v2/${REPO_PATH}/tags/list" 2>/dev/null \
        | python3 -c "import sys, json; [print(t) for t in json.load(sys.stdin).get('tags', [])]" 2>/dev/null
    else
      curl -sf "https://${HOST}/v2/${REPO_PATH}/tags/list" 2>/dev/null \
        | python3 -c "import sys, json; [print(t) for t in json.load(sys.stdin).get('tags', [])]" 2>/dev/null
    fi
  fi
}

# Compare two semver-like tags using python3 (portable, no sort -V dependency)
# Returns 0 if $1 is newer than $2
is_newer() {
  python3 -c "
import re, sys
def parse_ver(v):
    v = v.lstrip('v')
    # Extract numeric prefix
    m = re.match(r'(\d+)\.(\d+)\.(\d+)', v)
    if not m: return (0,0,0)
    return tuple(int(x) for x in m.groups())
sys.exit(0 if parse_ver('$1') > parse_ver('$2') else 1)
"
}

# Filter tags to only stable semver releases (no rc, beta, alpha, latest, etc.)
filter_stable_tags() {
  grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+(-[a-zA-Z0-9.]+)?$' \
    | grep -v -iE 'rc|beta|alpha|dev|nightly|canary'
}

# ── Main ──────────────────────────────────────────────────────────────

echo "=== Checking for image updates ==="
echo ""

UPDATES_FOUND=0

for IMAGE_DIR in "${REPO_ROOT}"/images/*/; do
  IMAGE_NAME="$(basename "${IMAGE_DIR}")"
  # Prefer local gitignored files, fall back to versioned templates —
  # same pattern as scripts/build.sh resolve_global_env / resolve_image_env.
  IMAGE_DIR_TRIMMED="${IMAGE_DIR%/}"
  if [ -f "${IMAGE_DIR_TRIMMED}/image.env" ]; then
    ENV_FILE="${IMAGE_DIR_TRIMMED}/image.env"
  elif [ -f "${IMAGE_DIR_TRIMMED}/image.env.example" ]; then
    ENV_FILE="${IMAGE_DIR_TRIMMED}/image.env.example"
  else
    continue
  fi

  if [ -f "${REPO_ROOT}/global.env" ]; then
    GLOBAL_ENV_FILE="${REPO_ROOT}/global.env"
  else
    GLOBAL_ENV_FILE="${REPO_ROOT}/global.env.example"
  fi
  # shellcheck source=/dev/null
  source "${GLOBAL_ENV_FILE}"
  # shellcheck source=/dev/null
  source "${ENV_FILE}"

  CURRENT_TAG="${TAG}"
  # Determine the upstream source path for tag lookup
  # SOURCE may contain ${PULL_REGISTRY} variable — resolve or use raw
  RESOLVED_SOURCE=$(eval echo "${SOURCE}" 2>/dev/null || echo "${SOURCE}")

  echo "Checking ${IMAGE_NAME} (current: ${CURRENT_TAG})..."

  # Fetch and filter tags
  AVAILABLE_TAGS=$(fetch_tags "${RESOLVED_SOURCE}" | filter_stable_tags || true)

  if [ -z "${AVAILABLE_TAGS}" ]; then
    echo "  WARN: Could not fetch tags for ${RESOLVED_SOURCE}"
    echo ""
    continue
  fi

  # Check if current tag has a suffix like -alpine, -slim, etc.
  # If so, only compare against tags with the same suffix
  # Strip the semver prefix (with optional v) to isolate the suffix
  TAG_SUFFIX=$(echo "${CURRENT_TAG}" | sed -E 's/^v?[0-9]+\.[0-9]+\.[0-9]+//')

  if [ -n "${TAG_SUFFIX}" ]; then
    # Escape the suffix for regex (e.g. -alpine → \-alpine) and anchor to end
    ESCAPED_SUFFIX=$(printf '%s' "${TAG_SUFFIX}" | sed 's/[.[\*^$()+?{|]/\\&/g')
    FILTERED_TAGS=$(echo "${AVAILABLE_TAGS}" | grep -E -- "${ESCAPED_SUFFIX}$" || true)
  else
    # No suffix — only compare against tags without suffixes
    FILTERED_TAGS=$(echo "${AVAILABLE_TAGS}" | grep -E '^v?[0-9]+\.[0-9]+\.[0-9]+$' || true)
  fi

  # Find the latest tag (python3 semver sort — portable across macOS/Linux)
  LATEST_TAG=$(echo "${FILTERED_TAGS}" | python3 -c "
import sys, re
def ver_key(v):
    m = re.match(r'v?(\d+)\.(\d+)\.(\d+)', v.strip())
    return tuple(int(x) for x in m.groups()) if m else (0,0,0)
tags = [l.strip() for l in sys.stdin if l.strip()]
print(max(tags, key=ver_key)) if tags else None
" 2>/dev/null)

  if [ -z "${LATEST_TAG}" ]; then
    echo "  No comparable tags found"
    echo ""
    continue
  fi

  if is_newer "${LATEST_TAG}" "${CURRENT_TAG}"; then
    echo "  UPDATE AVAILABLE: ${CURRENT_TAG} → ${LATEST_TAG}"
    UPDATES_FOUND=$((UPDATES_FOUND + 1))

    # Create MR/PR if requested — uses API calls (no git push needed)
    if [ "${CREATE_MR}" = "true" ] || [ "${CREATE_PR}" = "true" ]; then
      BRANCH_NAME="update/${IMAGE_NAME}-${LATEST_TAG}"
      ENV_REL_PATH="images/${IMAGE_NAME}/image.env"
      COMMIT_MSG="Bump ${IMAGE_NAME} to ${LATEST_TAG}"

      # Read current file and replace TAG line
      NEW_CONTENT=$(sed "s|^TAG=.*|TAG=\"${LATEST_TAG}\"|" "${ENV_FILE}")

      if [ "${CREATE_MR}" = "true" ] && [ -n "${GITLAB_TOKEN:-}" ]; then
        # GitLab: create branch + commit + MR via API (no push needed)
        # Create branch from main
        curl -sf -X POST \
          -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
          "${GITLAB_URL}/api/v4/projects/${GITLAB_PROJECT}/repository/branches" \
          -H "Content-Type: application/json" \
          -d "{\"branch\": \"${BRANCH_NAME}\", \"ref\": \"main\"}" > /dev/null 2>&1 || {
            echo "  SKIP: Branch ${BRANCH_NAME} already exists"
            echo ""
            continue
          }

        # Commit file change via API
        ENCODED_CONTENT=$(printf '%s' "${NEW_CONTENT}" | python3 -c "import sys,json; print(json.dumps(sys.stdin.read()))")
        curl -sf -X POST \
          -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
          "${GITLAB_URL}/api/v4/projects/${GITLAB_PROJECT}/repository/commits" \
          -H "Content-Type: application/json" \
          -d "{
            \"branch\": \"${BRANCH_NAME}\",
            \"commit_message\": \"${COMMIT_MSG}\",
            \"actions\": [{
              \"action\": \"update\",
              \"file_path\": \"${ENV_REL_PATH}\",
              \"content\": ${ENCODED_CONTENT}
            }]
          }" > /dev/null 2>&1

        # Create MR
        MR_RESULT=$(curl -sf -X POST \
          -H "PRIVATE-TOKEN: ${GITLAB_TOKEN}" \
          "${GITLAB_URL}/api/v4/projects/${GITLAB_PROJECT}/merge_requests" \
          -H "Content-Type: application/json" \
          -d "{
            \"source_branch\": \"${BRANCH_NAME}\",
            \"target_branch\": \"main\",
            \"title\": \"${COMMIT_MSG}\",
            \"description\": \"Automated update: ${CURRENT_TAG} → ${LATEST_TAG}\\n\\nCreated by check-updates.sh\",
            \"remove_source_branch\": true
          }" 2>&1)
        echo "${MR_RESULT}" | python3 -c "
import sys, json
mr = json.load(sys.stdin)
print(f\"  MR created: {mr.get('web_url', 'unknown')}\")
" 2>/dev/null || echo "  MR created (could not parse URL)"
      fi

      if [ "${CREATE_PR}" = "true" ] && [ -n "${GITHUB_TOKEN:-}" ]; then
        # GitHub: create branch + commit + PR via API
        # Get main SHA
        MAIN_SHA=$(curl -sf \
          -H "Authorization: token ${GITHUB_TOKEN}" \
          "https://api.github.com/repos/${GITHUB_REPO}/git/ref/heads/main" \
          | python3 -c "import sys,json; print(json.load(sys.stdin)['object']['sha'])" 2>/dev/null)

        # Create branch
        curl -sf -X POST \
          -H "Authorization: token ${GITHUB_TOKEN}" \
          "https://api.github.com/repos/${GITHUB_REPO}/git/refs" \
          -d "{\"ref\": \"refs/heads/${BRANCH_NAME}\", \"sha\": \"${MAIN_SHA}\"}" > /dev/null 2>&1 || {
            echo "  SKIP: Branch ${BRANCH_NAME} already exists"
            echo ""
            continue
          }

        # Update file via Contents API
        FILE_SHA=$(curl -sf \
          -H "Authorization: token ${GITHUB_TOKEN}" \
          "https://api.github.com/repos/${GITHUB_REPO}/contents/${ENV_REL_PATH}?ref=${BRANCH_NAME}" \
          | python3 -c "import sys,json; print(json.load(sys.stdin)['sha'])" 2>/dev/null)

        ENCODED_B64=$(printf '%s' "${NEW_CONTENT}" | base64)
        curl -sf -X PUT \
          -H "Authorization: token ${GITHUB_TOKEN}" \
          "https://api.github.com/repos/${GITHUB_REPO}/contents/${ENV_REL_PATH}" \
          -d "{
            \"message\": \"${COMMIT_MSG}\",
            \"content\": \"${ENCODED_B64}\",
            \"sha\": \"${FILE_SHA}\",
            \"branch\": \"${BRANCH_NAME}\"
          }" > /dev/null 2>&1

        # Create PR
        PR_RESULT=$(curl -sf -X POST \
          -H "Authorization: token ${GITHUB_TOKEN}" \
          "https://api.github.com/repos/${GITHUB_REPO}/pulls" \
          -d "{
            \"head\": \"${BRANCH_NAME}\",
            \"base\": \"main\",
            \"title\": \"${COMMIT_MSG}\",
            \"body\": \"Automated update: ${CURRENT_TAG} → ${LATEST_TAG}\\n\\nCreated by check-updates.sh\"
          }" 2>&1)
        echo "${PR_RESULT}" | python3 -c "
import sys, json
pr = json.load(sys.stdin)
print(f\"  PR created: {pr.get('html_url', 'unknown')}\")
" 2>/dev/null || echo "  PR created (could not parse URL)"
      fi
    fi
  else
    echo "  Up to date"
  fi
  echo ""
done

echo "=== ${UPDATES_FOUND} update(s) available ==="
exit 0
