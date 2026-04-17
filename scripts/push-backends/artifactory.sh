#!/usr/bin/env bash
# push-backend: JFrog Artifactory (JCR Free baseline + Pro opt-in).
#
# Sourced by scripts/build.sh when REGISTRY_KIND=artifactory and --push
# is requested. Exposes a single entry point, push_to_backend(), that:
#
#   FREE (default): docker push + enriched build info with module
#     linkage (constructed from storage API checksums), env vars
#     (from jf's --collect-env with org-specific post-filter), git
#     context, and build.name/build.number props on all layers.
#
#   PRO (ARTIFACTORY_PRO=true): jf docker push (automatic module
#     linkage + layer props), project-scoped build info, Xray scan.
#
# See the template repo's scripts/push-backends/artifactory.sh for
# the full Free/Pro feature comparison table.
#
# Required env:
#   ARTIFACTORY_URL, ARTIFACTORY_USER, ARTIFACTORY_TEAM
#   ARTIFACTORY_TOKEN | ARTIFACTORY_PASSWORD
#
# Pro-only: ARTIFACTORY_PRO=true, ARTIFACTORY_PROJECT
#
# Layout templates: ARTIFACTORY_IMAGE_REF, ARTIFACTORY_MANIFEST_PATH
# (see global.env.example for 5 named presets)

set -uo pipefail

push_to_backend() {
  local built="$1"

  _artifactory_require_env   || return 1
  _artifactory_require_tools || return 1

  local image_repo_tag="${built##*/}"
  local _img_name="${image_repo_tag%:*}"
  local _img_tag="${image_repo_tag##*:}"

  export IMAGE_NAME="${_img_name}"
  export IMAGE_TAG="${_img_tag}"
  export ARTIFACTORY_TEAM

  : "${ARTIFACTORY_ENVIRONMENT:=dev}"
  case "${ARTIFACTORY_ENVIRONMENT}" in
    prod|production) export ARTIFACTORY_REPO_SUFFIX="prod"  ;;
    *)               export ARTIFACTORY_REPO_SUFFIX="local" ;;
  esac
  export ARTIFACTORY_ENVIRONMENT

  if [ -z "${ARTIFACTORY_PUSH_HOST:-}" ]; then
    local _url_host="${ARTIFACTORY_URL#https://}"
    _url_host="${_url_host#http://}"
    _url_host="${_url_host%%/*}"
    ARTIFACTORY_PUSH_HOST="${_url_host}"
  fi
  export ARTIFACTORY_PUSH_HOST

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

  local target manifest_path
  target=$(_artifactory_expand_template "${image_ref_tpl}")
  manifest_path=$(_artifactory_expand_template "${manifest_path_tpl}")

  local build_name build_number
  build_name="${ARTIFACTORY_BUILD_NAME:-${IMAGE_NAME}}"
  build_number="${ARTIFACTORY_BUILD_NUMBER:-${CI_JOB_ID:-${CI_PIPELINE_ID:-${BUILD_NUMBER:-${GITHUB_RUN_ID:-$(date +%s)}}}}}"

  local is_pro="false"
  [ "${ARTIFACTORY_PRO:-false}" = "true" ] && is_pro="true"
  local project_key="${ARTIFACTORY_PROJECT:-${ARTIFACTORY_TEAM:-}}"

  echo ""
  echo "=== Artifactory push ==="
  echo "  Source (local):  ${built}"
  echo "  Target:          ${target}"
  echo "  Team:            ${ARTIFACTORY_TEAM}"
  echo "  Environment:     ${ARTIFACTORY_ENVIRONMENT}"
  echo "  Push host:       ${ARTIFACTORY_PUSH_HOST}"
  echo "  Manifest path:   ${manifest_path}"
  echo "  Build name:      ${build_name}"
  echo "  Build number:    ${build_number}"
  echo "  Tier:            $([ "${is_pro}" = "true" ] && echo "PRO (project=${project_key})" || echo "FREE (LCD baseline)")"

  _artifactory_jf_config || return 1
  _artifactory_docker_login "${ARTIFACTORY_PUSH_HOST}" || return 1

  # ════════════════════════════════════════════════════════════════════
  # PRO PATH
  # ════════════════════════════════════════════════════════════════════
  if [ "${is_pro}" = "true" ]; then
    echo ""
    echo "── Pro: enriching build info before push ──"
    local project_flag=""
    [ -n "${project_key}" ] && project_flag="--project=${project_key}"

    # shellcheck disable=SC2086
    jf rt build-collect-env "${build_name}" "${build_number}" ${project_flag} 2>&1
    # shellcheck disable=SC2086
    jf rt build-add-git "${build_name}" "${build_number}" ${project_flag} 2>&1

    docker tag "${built}" "${target}"
    # shellcheck disable=SC2086
    jf docker push "${target}" \
      --build-name="${build_name}" \
      --build-number="${build_number}" \
      ${project_flag} || {
        echo "ERROR: jf docker push failed" >&2
        return 1
      }

    echo ""
    echo "── Pro: publishing build info ──"
    # shellcheck disable=SC2086
    jf rt build-publish "${build_name}" "${build_number}" ${project_flag} 2>&1 | tail -5

    echo ""
    echo "── Pro: Xray build scan ──"
    # shellcheck disable=SC2086
    jf build-scan "${build_name}" "${build_number}" ${project_flag} 2>&1 || {
      echo "  WARN: jf build-scan returned non-zero (Xray may still be indexing)" >&2
    }

    local push_digest=""
    push_digest=$(crane digest "${target}" 2>/dev/null || echo "")
    if [ -z "${push_digest}" ]; then
      push_digest=$(docker inspect --format='{{index .RepoDigests 0}}' "${target}" 2>/dev/null | grep -oE 'sha256:[0-9a-f]{64}' || echo "")
    fi

    # emit_build_env is defined in scripts/build.sh and in scope
    emit_build_env "${target}" "${push_digest}"

    _artifactory_set_props "${manifest_path}" \
      "${build_name}" "${build_number}" "${ARTIFACTORY_ENVIRONMENT}"

  # ════════════════════════════════════════════════════════════════════
  # FREE PATH
  # ════════════════════════════════════════════════════════════════════
  else
    docker tag "${built}" "${target}"
    local push_output
    push_output=$(docker push "${target}" 2>&1) || {
      echo "${push_output}" >&2
      echo "ERROR: docker push to Artifactory failed" >&2
      return 1
    }
    echo "${push_output}"

    local push_digest
    push_digest=$(extract_push_digest "${push_output}")
    emit_build_env "${target}" "${push_digest}"

    # Build info with module linkage + env vars (merged from jf rt bp)
    _artifactory_build_publish_free_with_modules \
      "${build_name}" "${build_number}" "${manifest_path}" "${target}"

    # build.name/build.number on all layers for Packages cross-link
    _artifactory_set_props_all_layers "${manifest_path}" \
      "${build_name}" "${build_number}"

    _artifactory_set_props "${manifest_path}" \
      "${build_name}" "${build_number}" "${ARTIFACTORY_ENVIRONMENT}"
  fi

  echo "Pushed: ${target}"
}

# ── Internals ────────────────────────────────────────────────────────

# Expand ${VAR} references in a template string using bash parameter
# expansion. Only the variables whitelisted below are substituted —
# anything else is left untouched. Safer than `eval` because it can't
# execute arbitrary code if a variable value contains backticks, $(...),
# or semicolons.
_artifactory_expand_template() {
  local tpl="$1"
  local v
  for v in ARTIFACTORY_PUSH_HOST ARTIFACTORY_TEAM ARTIFACTORY_ENVIRONMENT \
           ARTIFACTORY_REPO_SUFFIX IMAGE_NAME IMAGE_TAG; do
    tpl="${tpl//\$\{${v}\}/${!v:-}}"
  done
  printf '%s' "${tpl}"
}

_artifactory_require_env() {
  local missing=0 var
  for var in ARTIFACTORY_URL ARTIFACTORY_USER ARTIFACTORY_TEAM; do
    if [ -z "${!var:-}" ]; then
      echo "ERROR: ${var} is required when REGISTRY_KIND=artifactory" >&2
      missing=1
    fi
  done
  if [ -z "${ARTIFACTORY_TOKEN:-}" ] && [ -z "${ARTIFACTORY_PASSWORD:-}" ]; then
    echo "ERROR: set either ARTIFACTORY_TOKEN (preferred) or ARTIFACTORY_PASSWORD" >&2
    missing=1
  fi
  return "${missing}"
}

_artifactory_require_tools() {
  local missing=0
  if ! command -v jf >/dev/null 2>&1; then
    _artifactory_install_jf || { missing=1; }
  fi
  if ! command -v docker >/dev/null 2>&1; then
    echo "ERROR: 'docker' CLI not found on PATH" >&2
    missing=1
  fi
  return "${missing}"
}

# Auto-install the JFrog CLI if not present.
#
# Two environment variables control where jf is fetched from:
#
#   JF_BINARY_URL     Direct URL to the jf binary (Method 1 — fastest).
#                     e.g. https://artifactory.example.com/artifactory/
#                          jfrog-releases-remote/jfrog-cli/v2-jf/
#                          [RELEASE]/jfrog-cli-linux-amd64/jf
#
#   JF_INSTALLER_URL  URL to the JFrog CLI installer script (Method 2).
#                     Default: https://install.jfrog.io
#                     For air-gap: proxy this through an Artifactory
#                     generic-remote repo.
#
# Neither set? Falls back to JFrog's public installer.
_artifactory_install_jf() {
  echo "  jf CLI not found — auto-installing..."
  local install_dir="${JF_INSTALL_DIR:-/usr/local/bin}"

  # Method 1: direct binary URL (fastest, works in CI containers)
  if [ -n "${JF_BINARY_URL:-}" ]; then
    echo "  → downloading jf binary from JF_BINARY_URL"
    if curl -fsSL "${JF_BINARY_URL}" -o "${install_dir}/jf" && chmod +x "${install_dir}/jf"; then
      echo "  ✓ jf installed: $(jf --version 2>/dev/null || echo 'unknown version')"
      return 0
    fi
    echo "  ✗ binary download failed" >&2
    return 1
  fi

  # Method 2: installer script (variable-driven, air-gap safe)
  local installer_url="${JF_INSTALLER_URL:-https://install.jfrog.io}"
  echo "  → running installer from ${installer_url}"
  if curl -fsSL "${installer_url}" | bash -s 2>/dev/null; then
    if command -v jf >/dev/null 2>&1; then
      echo "  ✓ jf installed: $(jf --version 2>/dev/null)"
      return 0
    fi
  fi

  echo "ERROR: 'jf' CLI not found and auto-install failed" >&2
  echo "  Install manually: https://jfrog.com/getcli/" >&2
  echo "  For air-gap: set JF_BINARY_URL or JF_INSTALLER_URL" >&2
  return 1
}

_artifactory_jf_config() {
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD}}"
  local auth_flag
  local _url="${ARTIFACTORY_URL%/}"
  if [[ ! "${_url}" =~ ^https?:// ]]; then
    echo "ERROR: ARTIFACTORY_URL must start with http:// or https://" >&2
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

# FREE-tier build info with module linkage + env vars.
# 1. jf rt bp --collect-env --collect-git-info (baseline, jf's filtering)
# 2. GET the published record back
# 3. Merge modules (from storage API checksums) + filter env vars
# 4. PUT the enriched JSON
_artifactory_build_publish_free_with_modules() {
  local build_name="$1" build_number="$2" manifest_path="$3" target="$4"
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD}}"
  local _url="${ARTIFACTORY_URL%/}"
  _url="${_url%/artifactory}"
  local art_base="${_url}/artifactory"

  echo ""
  echo "── Free: publishing baseline build info via jf rt bp ──"
  jf rt bp "${build_name}" "${build_number}" \
    --collect-env --collect-git-info 2>/dev/null || true

  echo "── Free: fetching published build info for merge ──"
  local _bi_tmpfile
  _bi_tmpfile=$(mktemp)
  local _bi_http_code
  _bi_http_code=$(curl -sSL -o "${_bi_tmpfile}" -w "%{http_code}" \
    -u "${ARTIFACTORY_USER}:${secret}" \
    "${art_base}/api/build/${build_name}/${build_number}" 2>/dev/null)
  if [ "${_bi_http_code}" = "200" ] && [ -s "${_bi_tmpfile}" ]; then
    echo "  ✓ fetched (HTTP ${_bi_http_code}, $(wc -c < "${_bi_tmpfile}" | tr -d ' ') bytes)"
  else
    echo "  WARN: fetch returned HTTP ${_bi_http_code} — env vars won't be merged" >&2
    rm -f "${_bi_tmpfile}"
    _bi_tmpfile=""
  fi

  echo "── Free: building module linkage from storage API ──"

  local tag_dir="${manifest_path%/manifest.json}"
  local tag_subpath="${tag_dir#*/}"

  local listing
  listing=$(curl -fsSL -u "${ARTIFACTORY_USER}:${secret}" \
    "${art_base}/api/storage/${tag_dir}" 2>/dev/null) || {
    echo "  WARN: could not list ${tag_dir} — skipping module linkage" >&2
    return 0
  }

  local files_list
  files_list=$(printf '%s' "${listing}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for child in d.get('children', []):
        uri = child.get('uri', '').lstrip('/')
        if uri:
            print(uri)
except json.JSONDecodeError:
    pass
")

  if [ -z "${files_list}" ]; then
    echo "  WARN: no files found in ${tag_dir}" >&2
    return 0
  fi

  local tmpdir
  tmpdir=$(mktemp -d)
  local file_count=0

  if [ -n "${_bi_tmpfile}" ] && [ -f "${_bi_tmpfile}" ]; then
    mv "${_bi_tmpfile}" "${tmpdir}/published-bi.json"
  fi

  while IFS= read -r fname; do
    [ -z "${fname}" ] && continue
    curl -fsSL -u "${ARTIFACTORY_USER}:${secret}" \
      "${art_base}/api/storage/${tag_dir}/${fname}" \
      > "${tmpdir}/file_${file_count}.json" 2>/dev/null && \
      echo "${fname}" > "${tmpdir}/name_${file_count}.txt"
    file_count=$((file_count + 1))
  done <<< "${files_list}"

  # Count upstream base image layers for accurate dependency split
  local upstream_layer_count=0
  local _source_ref="${UPSTREAM_REF:-${UPSTREAM_REGISTRY:-}/${UPSTREAM_IMAGE:-}:${UPSTREAM_TAG:-}}"
  if [ -n "${_source_ref}" ] && [ "${_source_ref}" != "/:" ]; then
    upstream_layer_count=$(docker inspect "${_source_ref}" --format '{{len .RootFS.Layers}}' 2>/dev/null || echo 0)
    [ "${upstream_layer_count}" -gt 0 ] 2>/dev/null && \
      echo "  upstream base layers: ${upstream_layer_count}"
  fi

  local git_rev="" git_url=""
  if git rev-parse HEAD >/dev/null 2>&1; then
    git_rev=$(git rev-parse HEAD)
    git_url=$(git config --get remote.origin.url 2>/dev/null || echo "")
  fi

  local started
  started=$(date -u +"%Y-%m-%dT%H:%M:%S.000+0000")

  local _backend_dir
  _backend_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
  python3 "${_backend_dir}/../lib/build-info-merge.py" \
    "${tmpdir}" "${file_count}" "${tag_subpath}" \
    "${build_name}" "${build_number}" "${target}" \
    "${IMAGE_NAME}" "${IMAGE_TAG}" "${git_rev}" "${git_url}" \
    "${started}" "${upstream_layer_count}"

  echo "── Free: publishing enriched build info ──"
  local http_code
  http_code=$(curl -fsSL -o /dev/null -w "%{http_code}" \
    -X PUT -u "${ARTIFACTORY_USER}:${secret}" \
    -H "Content-Type: application/json" \
    --data-binary "@${tmpdir}/build-info.json" \
    "${art_base}/api/build" 2>/dev/null) || true

  if [ "${http_code}" = "204" ]; then
    echo "  ✓ build info published with module linkage"
  else
    echo "  WARN: enriched build info publish returned HTTP ${http_code}" >&2
  fi

  rm -rf "${tmpdir}"
}

_artifactory_set_props_all_layers() {
  local manifest_path="$1" build_name="$2" build_number="$3"
  local tag_dir="${manifest_path%/manifest.json}"
  local props="build.name=${build_name};build.number=${build_number}"
  local secret="${ARTIFACTORY_TOKEN:-${ARTIFACTORY_PASSWORD}}"
  local _url="${ARTIFACTORY_URL%/}"
  _url="${_url%/artifactory}"
  local art_base="${_url}/artifactory"

  local listing
  listing=$(curl -fsSL -u "${ARTIFACTORY_USER}:${secret}" \
    "${art_base}/api/storage/${tag_dir}" 2>/dev/null) || return 0

  local count=0
  local files_list
  files_list=$(printf '%s' "${listing}" | python3 -c "
import json, sys
try:
    d = json.load(sys.stdin)
    for child in d.get('children', []):
        uri = child.get('uri', '').lstrip('/')
        if uri:
            print(uri)
except json.JSONDecodeError:
    pass
")
  while IFS= read -r fname; do
    [ -z "${fname}" ] && continue
    jf rt set-props "${tag_dir}/${fname}" "${props}" 2>/dev/null && count=$((count + 1))
  done <<< "${files_list}"

  echo "  ✓ build.name/build.number set on ${count} files"
}

_artifactory_set_props() {
  local manifest_path="$1" build_name="$2" build_number="$3" env="$4"
  local props="environment=${env};build.name=${build_name};build.number=${build_number}"
  [ -n "${ARTIFACTORY_TEAM:-}" ] && props="${props};team=${ARTIFACTORY_TEAM}"
  [ -n "${GIT_SHA:-}" ]          && props="${props};git.commit=${GIT_SHA}"
  [ -n "${UPSTREAM_TAG:-}" ]      && props="${props};upstream.tag=${UPSTREAM_TAG}"
  # NOTE: sbom.path is NOT set here — it's set by sbom-post.sh AFTER
  # the SBOM upload succeeds, so the property always points to a real
  # artifact rather than a speculative path.
  [ -n "${ARTIFACTORY_PROPERTIES:-}" ] && props="${props};${ARTIFACTORY_PROPERTIES}"

  if ! jf rt set-props "${manifest_path}" "${props}" 2>/dev/null; then
    echo "  WARN: 'jf rt set-props' failed for ${manifest_path}" >&2
    echo "        (check manifest path matches the repo storage layout)" >&2
  fi
}
