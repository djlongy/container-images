#!/usr/bin/env bash
# push-backend: JFrog Artifactory (JCR Free and Pro-compatible)
#
# Sourced by scripts/build.sh when REGISTRY_KIND=artifactory and --push
# is requested. Exposes a single entry point, push_to_backend(), that:
#
#   1. Retags the locally-built image under the Artifactory-specific path
#        ${ARTIFACTORY_URL}/${ARTIFACTORY_TEAM}/${IMAGE_NAME}:${TAG}
#      (Artifactory's nginx sidecar routes the <team> prefix to the
#      <team>-docker-<suffix> repo — dev → *-docker-local, prod →
#      *-docker-prod. Match the reference JCR Free layout from the
#      homelab deployment.)
#
#   2. Logs docker in to the Artifactory host and pushes.
#
#   3. Publishes build info to Artifactory using the LCD pattern that
#      works on both JCR Free and Pro:
#
#        jf rt bp <name> <number> --collect-env --collect-git-info
#
#      This captures git SHA, branch, remote URL, environment
#      variables, and timestamps. On Pro you COULD also get layer /
#      module linkage via `jf docker push --build-name ...` or
#      `jf rt bdc`, but both of those call a repo-detail API that's
#      blocked on JCR Free. Property-based traceability (step 4)
#      gives the same query capability on both tiers, so we don't
#      wire up the Pro-only path — if you want module linkage on Pro,
#      run `jf rt bdc "${BUILD_NAME}" "${BUILD_NUMBER}"` after push.
#
#   4. Tags the manifest with structured properties (team, environment,
#      build.name, build.number, git.commit, plus whatever's in
#      ARTIFACTORY_PROPERTIES). Works on both tiers. Lets you query
#      "all unapproved images for team X" with
#        jf rt search "*/**/manifest.json" --props="team=X;approval.status=pending"
#
# Required env (fail fast if missing):
#   ARTIFACTORY_URL        e.g. https://artifactory.example.com
#   ARTIFACTORY_USER       username with push rights to the target repo
#   ARTIFACTORY_PASSWORD   (or ARTIFACTORY_TOKEN — access token preferred)
#   ARTIFACTORY_TEAM       routing prefix (your team acronym — e.g. a
#                          4-letter code the platform team assigns you)
#
# Optional env:
#   ARTIFACTORY_ENVIRONMENT  dev|prod (default: dev → *-docker-local)
#   ARTIFACTORY_BUILD_NAME   defaults to ${IMAGE_NAME}
#   ARTIFACTORY_BUILD_NUMBER defaults to $CI_JOB_ID / $CI_PIPELINE_ID /
#                            $BUILD_NUMBER / $GITHUB_RUN_ID / $(date +%s)
#   ARTIFACTORY_PROPERTIES   extra props, ;-separated, e.g.
#                              "security.scan=pending;hardened=false"

set -uo pipefail

# ── Entry point — called by scripts/build.sh after a successful build.
# Arg 1: the locally-built image tag (FULL_IMAGE from build.sh), i.e.
#        ${PUSH_REGISTRY}/${PUSH_PROJECT}/${IMAGE_NAME}:${PROMOTED_TAG}
push_to_backend() {
  local built="$1"

  _artifactory_require_env   || return 1
  _artifactory_require_tools || return 1

  local env="${ARTIFACTORY_ENVIRONMENT:-dev}"
  local repo_suffix
  case "${env}" in
    prod|production) repo_suffix="prod"  ;;
    *)               repo_suffix="local" ;;
  esac

  # Strip the build.sh-constructed prefix to get the bare image:tag pair.
  # Format: ${PUSH_REGISTRY}/${PUSH_PROJECT}/<image>:<tag>
  local image_repo_tag="${built##*/}"                 # <image>:<tag>
  local image_repo="${image_repo_tag%:*}"
  local image_tag="${image_repo_tag##*:}"

  # Target path uses the <team>/<image> virtual route that the
  # Artifactory nginx sidecar re-writes to the <team>-docker-<suffix>
  # backing repo. See the JCR reference doc from the homelab deployment.
  local host="${ARTIFACTORY_URL#https://}"
  host="${host#http://}"
  local target="${host}/${ARTIFACTORY_TEAM}/${image_repo}:${image_tag}"

  echo ""
  echo "=== Artifactory push ==="
  echo "  Source (local):  ${built}"
  echo "  Target:          ${target}"
  echo "  Team:            ${ARTIFACTORY_TEAM}"
  echo "  Environment:     ${env} (${ARTIFACTORY_TEAM}-docker-${repo_suffix})"

  _artifactory_jf_config || return 1
  _artifactory_docker_login "${host}" || return 1

  docker tag "${built}" "${target}"
  local push_output
  push_output=$(docker push "${target}" 2>&1) || {
    echo "${push_output}" >&2
    echo "ERROR: docker push to Artifactory failed" >&2
    return 1
  }
  echo "${push_output}"

  # Capture the registry-reported manifest digest for build.env so
  # downstream CI jobs (cosign, trivy, syft) can sign/scan by digest.
  # extract_push_digest is defined in scripts/build.sh and is in scope
  # because build.sh sources this file.
  local push_digest
  push_digest=$(extract_push_digest "${push_output}")
  emit_build_env "${target}" "${push_digest}"

  local build_name build_number
  build_name="${ARTIFACTORY_BUILD_NAME:-${image_repo}}"
  build_number="${ARTIFACTORY_BUILD_NUMBER:-${CI_JOB_ID:-${CI_PIPELINE_ID:-${BUILD_NUMBER:-${GITHUB_RUN_ID:-$(date +%s)}}}}}"
  echo "  Build name:      ${build_name}"
  echo "  Build number:    ${build_number}"

  _artifactory_build_publish "${build_name}" "${build_number}"
  # Storage layout: <repo>/<image>/<tag>/manifest.json. The <team>
  # prefix in the push URL is a virtual routing hint handled by
  # Artifactory's nginx sidecar; it does NOT appear in the actual
  # backing-store path (verified against the homelab JCR instance).
  _artifactory_set_props \
    "${ARTIFACTORY_TEAM}-docker-${repo_suffix}/${image_repo}/${image_tag}/manifest.json" \
    "${build_name}" "${build_number}" "${env}"

  echo "Pushed: ${target}"
}

# ── Internals ────────────────────────────────────────────────────────

_artifactory_require_env() {
  local missing=0
  local var
  for var in ARTIFACTORY_URL ARTIFACTORY_USER ARTIFACTORY_TEAM; do
    if [ -z "${!var:-}" ]; then
      echo "ERROR: ${var} is required when REGISTRY_KIND=artifactory" >&2
      case "${var}" in
        ARTIFACTORY_TEAM)
          echo "  Set this as an env var in your pipeline/shell so each" >&2
          echo "  team gets their own target repo, e.g." >&2
          echo "    export ARTIFACTORY_TEAM=<your-team>   # e.g. a 4-letter acronym" >&2
          ;;
      esac
      missing=1
    fi
  done
  if [ -z "${ARTIFACTORY_TOKEN:-}" ] && [ -z "${ARTIFACTORY_PASSWORD:-}" ]; then
    echo "ERROR: set either ARTIFACTORY_TOKEN (access token, preferred)" >&2
    echo "       or ARTIFACTORY_PASSWORD" >&2
    missing=1
  fi
  return "${missing}"
}

_artifactory_require_tools() {
  local missing=0
  if ! command -v jf >/dev/null 2>&1; then
    echo "ERROR: 'jf' CLI not found on PATH" >&2
    echo "  Install: https://jfrog.com/getcli/ — or" >&2
    echo "    brew install jfrog-cli" >&2
    echo "    curl -fL https://install-cli.jfrog.io | sh" >&2
    missing=1
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: 'docker' CLI not found on PATH" >&2
    missing=1
  fi
  return "${missing}"
}

_artifactory_jf_config() {
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD}}"
  local auth_flag
  if [ -n "${ARTIFACTORY_TOKEN:-}" ]; then
    auth_flag="--access-token=${secret}"
  else
    auth_flag="--password=${secret}"
  fi
  # shellcheck disable=SC2086
  jf config add container-images-artifactory \
    --url="${ARTIFACTORY_URL}" \
    --artifactory-url="${ARTIFACTORY_URL}/artifactory" \
    --user="${ARTIFACTORY_USER}" \
    ${auth_flag} \
    --interactive=false \
    --overwrite=true >/dev/null || {
      echo "ERROR: 'jf config add' failed" >&2
      return 1
    }
  jf config use container-images-artifactory >/dev/null
}

_artifactory_docker_login() {
  local host="$1"
  printf '%s' "${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD}}" \
    | docker login "${host}" -u "${ARTIFACTORY_USER}" --password-stdin >/dev/null || {
      echo "ERROR: 'docker login ${host}' failed" >&2
      return 1
    }
}

_artifactory_build_publish() {
  local build_name="$1" build_number="$2"
  # LCD flow — works on both JCR Free and Pro.
  # --collect-env:      captures env vars into build info
  # --collect-git-info: captures git SHA, branch, remote URL
  #
  # Note: publishing build info requires Deploy permission on the
  # system-wide `artifactory-build-info` repo. On JCR Free, team users
  # don't have that by default — only admin does. The push itself
  # always succeeds first, so a failure here just means the image
  # won't appear in the Builds UI section; properties below still
  # provide full traceability (team, build.name, build.number,
  # git.commit) queryable via `jf rt search --props=...`.
  local stderr
  stderr=$(jf rt bp "${build_name}" "${build_number}" \
             --collect-env --collect-git-info 2>&1 >/dev/null) || {
    echo "  WARN: 'jf rt bp' failed — build info not published" >&2
    if echo "${stderr}" | grep -q 'not permitted to deploy.*artifactory-build-info'; then
      echo "        Cause: ${ARTIFACTORY_USER} lacks Deploy on the system" >&2
      echo "        'artifactory-build-info' repo. An admin can grant it" >&2
      echo "        in Artifactory UI → Security → Permissions. Property-" >&2
      echo "        based traceability (below) still works regardless." >&2
    else
      echo "        ${stderr}" | head -5 >&2
    fi
    return 0  # non-fatal
  }
}

_artifactory_set_props() {
  local manifest_path="$1" build_name="$2" build_number="$3" env="$4"
  local props="team=${ARTIFACTORY_TEAM};environment=${env}"
  props="${props};build.name=${build_name};build.number=${build_number}"
  [ -n "${VCS_REF:-}" ]    && props="${props};git.commit=${VCS_REF}"
  [ -n "${GIT_SHA:-}" ]    && props="${props};git.commit=${GIT_SHA}"
  [ -n "${ARTIFACTORY_PROPERTIES:-}" ] \
    && props="${props};${ARTIFACTORY_PROPERTIES}"

  if ! jf rt set-props "${manifest_path}" "${props}" 2>/dev/null; then
    echo "  WARN: 'jf rt set-props' failed for ${manifest_path}" >&2
    echo "        (check manifest path matches the repo storage layout;" >&2
    echo "         property-based traceability unavailable for this image)" >&2
  fi
}
