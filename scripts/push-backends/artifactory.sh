#!/usr/bin/env bash
# push-backend: JFrog Artifactory (JCR Free and Pro-compatible)
#
# Sourced by scripts/build.sh when REGISTRY_KIND=artifactory and --push
# is requested. Exposes a single entry point, push_to_backend(), that:
#
#   1. Resolves two layout templates at runtime:
#        ARTIFACTORY_IMAGE_REF    — the docker push URL
#        ARTIFACTORY_MANIFEST_PATH — the REST API storage path for
#                                    property tagging
#      Both are shell parameter-expansion templates. See the
#      "Artifactory layout templates" section in global.env.example
#      for five named presets (homelab per-team, shared repo, subdomain,
#      subdomain-per-team, team-dispatch subdomain) or write your own.
#
#   2. Retags the locally-built image to the resolved ARTIFACTORY_IMAGE_REF
#      and logs docker in to ARTIFACTORY_PUSH_HOST before pushing.
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
#                          Used for the REST API (jf config, set-props).
#                          NOT necessarily the docker push host — see
#                          ARTIFACTORY_PUSH_HOST below.
#   ARTIFACTORY_USER       username with push rights to the target repo
#   ARTIFACTORY_PASSWORD   (or ARTIFACTORY_TOKEN — access token preferred)
#   ARTIFACTORY_TEAM       your team acronym (commonly a 4-letter code the
#                          platform team assigns) — runtime-only, never
#                          committed
#
# Optional env:
#   ARTIFACTORY_PUSH_HOST    docker push hostname. Defaults to the host
#                            portion of ARTIFACTORY_URL. Override for
#                            subdomain layouts, e.g.
#                              ARTIFACTORY_PUSH_HOST=docker.artifactory.example.com
#   ARTIFACTORY_IMAGE_REF    docker push URL template (see presets in
#                            global.env.example). Defaults to
#                              ${ARTIFACTORY_PUSH_HOST}/${ARTIFACTORY_TEAM}/${IMAGE_NAME}:${IMAGE_TAG}
#   ARTIFACTORY_MANIFEST_PATH storage path template for set-props.
#                            Defaults to
#                              ${ARTIFACTORY_TEAM}-docker-${ARTIFACTORY_REPO_SUFFIX}/${IMAGE_NAME}/${IMAGE_TAG}/manifest.json
#   ARTIFACTORY_ENVIRONMENT  dev|prod (default: dev). Exposed to templates
#                            as ${ARTIFACTORY_ENVIRONMENT}; derived
#                            ${ARTIFACTORY_REPO_SUFFIX} maps dev→local,
#                            prod→prod for the legacy default templates.
#                            Layouts that don't split dev/prod can just
#                            not reference either variable.
#   ARTIFACTORY_BUILD_NAME   defaults to ${IMAGE_NAME}
#   ARTIFACTORY_BUILD_NUMBER defaults to $CI_JOB_ID / $CI_PIPELINE_ID /
#                            $BUILD_NUMBER / $GITHUB_RUN_ID / $(date +%s)
#   ARTIFACTORY_PROPERTIES   extra props, ;-separated, e.g.
#                              "security.scan=pending;hardened=false"
#
# Template variables (available inside ARTIFACTORY_IMAGE_REF /
# ARTIFACTORY_MANIFEST_PATH via shell parameter expansion):
#   ${ARTIFACTORY_PUSH_HOST}    docker push host
#   ${ARTIFACTORY_TEAM}         runtime team acronym
#   ${ARTIFACTORY_ENVIRONMENT}  dev|prod (use :- for a default if needed)
#   ${ARTIFACTORY_REPO_SUFFIX}  dev→local, prod→prod (legacy convenience)
#   ${IMAGE_NAME}               image short name (e.g. nginx)
#   ${IMAGE_TAG}                computed tag (upstream + git sha)

set -uo pipefail

# ── Entry point — called by scripts/build.sh after a successful build.
# Arg 1: the locally-built image tag (FULL_IMAGE from build.sh), i.e.
#        ${PUSH_REGISTRY}/${PUSH_PROJECT}/${IMAGE_NAME}:${PROMOTED_TAG}
push_to_backend() {
  local built="$1"

  _artifactory_require_env   || return 1
  _artifactory_require_tools || return 1

  # ── Decompose the build.sh local tag ──
  # build.sh hands us the locally-built image reference, which looks like
  #   ${PUSH_REGISTRY}/${PUSH_PROJECT}/<image>:<tag>
  # Split it into the bare <image> and <tag> so templates can reference
  # them as ${IMAGE_NAME} and ${IMAGE_TAG}.
  local image_repo_tag="${built##*/}"
  local _img_name="${image_repo_tag%:*}"
  local _img_tag="${image_repo_tag##*:}"

  # ── Build the template interpolation context ──
  # Every variable referenced in ARTIFACTORY_IMAGE_REF /
  # ARTIFACTORY_MANIFEST_PATH (and ARTIFACTORY_BUILD_NAME) is exported
  # here so the template resolver below can see it. Template authors
  # can rely on any of these being set; unset-safety is the user's
  # responsibility via ${VAR:-fallback} syntax in their template.
  export IMAGE_NAME="${_img_name}"
  export IMAGE_TAG="${_img_tag}"
  export ARTIFACTORY_TEAM

  # Environment is optional. Default "dev" only if the user hasn't
  # set it — some layouts (e.g. work's `docker` shared repo with no
  # prod split) don't reference it at all. We also derive a REPO
  # SUFFIX that maps dev→local / prod→prod for legacy-style
  # per-team repos (used by the fallback default template below);
  # users whose layouts don't need it just don't reference it.
  : "${ARTIFACTORY_ENVIRONMENT:=dev}"
  case "${ARTIFACTORY_ENVIRONMENT}" in
    prod|production) export ARTIFACTORY_REPO_SUFFIX="prod"  ;;
    *)               export ARTIFACTORY_REPO_SUFFIX="local" ;;
  esac
  export ARTIFACTORY_ENVIRONMENT

  # Docker push host. If the user set ARTIFACTORY_PUSH_HOST (typically
  # to use a subdomain like docker.artifactory.example.com), we use
  # that for the docker login and URL. Otherwise we fall back to the
  # host portion of ARTIFACTORY_URL so the simple case needs no
  # extra config.
  if [ -z "${ARTIFACTORY_PUSH_HOST:-}" ]; then
    local _url_host="${ARTIFACTORY_URL#https://}"
    _url_host="${_url_host#http://}"
    _url_host="${_url_host%%/*}"
    ARTIFACTORY_PUSH_HOST="${_url_host}"
  fi
  export ARTIFACTORY_PUSH_HOST

  # ── Resolve the two layout templates ──
  # See global.env.example "Artifactory layout templates" section for
  # named presets (homelab, shared repo, subdomain, subdomain-per-team).
  #
  # Fallback defaults match the legacy per-team-repo behaviour this
  # backend originally hardcoded, so anyone upgrading from the
  # previous version sees zero change without editing config.
  local image_ref_tpl manifest_path_tpl
  if [ -n "${ARTIFACTORY_IMAGE_REF:-}" ]; then
    image_ref_tpl="${ARTIFACTORY_IMAGE_REF}"
  else
    image_ref_tpl='${ARTIFACTORY_PUSH_HOST}/${ARTIFACTORY_TEAM}/${IMAGE_NAME}:${IMAGE_TAG}'
  fi
  if [ -n "${ARTIFACTORY_MANIFEST_PATH:-}" ]; then
    manifest_path_tpl="${ARTIFACTORY_MANIFEST_PATH}"
  else
    manifest_path_tpl='${ARTIFACTORY_TEAM}-docker-${ARTIFACTORY_REPO_SUFFIX}/${IMAGE_NAME}/${IMAGE_TAG}/manifest.json'
  fi

  # Shell parameter expansion via eval. Templates come from the
  # gitignored global.env or shell environment — same trust boundary
  # as the rest of build.sh. Shell injection via a template would
  # require the user to attack themselves.
  local target manifest_path
  eval "target=\"${image_ref_tpl}\""
  eval "manifest_path=\"${manifest_path_tpl}\""

  echo ""
  echo "=== Artifactory push ==="
  echo "  Source (local):  ${built}"
  echo "  Target:          ${target}"
  echo "  Team:            ${ARTIFACTORY_TEAM}"
  echo "  Environment:     ${ARTIFACTORY_ENVIRONMENT}"
  echo "  Push host:       ${ARTIFACTORY_PUSH_HOST}"
  echo "  Manifest path:   ${manifest_path}"

  _artifactory_jf_config || return 1
  _artifactory_docker_login "${ARTIFACTORY_PUSH_HOST}" || return 1

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
  # extract_push_digest + emit_build_env are defined in scripts/build.sh
  # and are in scope because build.sh sources this file.
  local push_digest
  push_digest=$(extract_push_digest "${push_output}")
  emit_build_env "${target}" "${push_digest}"

  local build_name build_number
  build_name="${ARTIFACTORY_BUILD_NAME:-${IMAGE_NAME}}"
  build_number="${ARTIFACTORY_BUILD_NUMBER:-${CI_JOB_ID:-${CI_PIPELINE_ID:-${BUILD_NUMBER:-${GITHUB_RUN_ID:-$(date +%s)}}}}}"
  echo "  Build name:      ${build_name}"
  echo "  Build number:    ${build_number}"

  _artifactory_build_publish "${build_name}" "${build_number}"
  _artifactory_set_props "${manifest_path}" \
    "${build_name}" "${build_number}" "${ARTIFACTORY_ENVIRONMENT}"

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

  # Sanitize ARTIFACTORY_URL: strip trailing slashes, validate scheme,
  # avoid doubling /artifactory suffix.
  local _url="${ARTIFACTORY_URL%/}"
  if [[ ! "${_url}" =~ ^https?:// ]]; then
    echo "ERROR: ARTIFACTORY_URL must start with http:// or https://" >&2
    echo "       Got: ${_url}" >&2
    echo "       Example: https://artifactory.example.com" >&2
    return 1
  fi
  local _art_url
  if [[ "${_url}" == */artifactory ]]; then
    _art_url="${_url}"
    _url="${_url%/artifactory}"
  else
    _art_url="${_url}/artifactory"
  fi

  if [ -n "${ARTIFACTORY_TOKEN:-}" ]; then
    auth_flag="--access-token=${secret}"
  else
    auth_flag="--password=${secret}"
  fi
  # shellcheck disable=SC2086
  jf config add container-images-artifactory \
    --url="${_url}" \
    --artifactory-url="${_art_url}" \
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
