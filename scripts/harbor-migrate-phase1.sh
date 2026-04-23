#!/usr/bin/env bash
# Phase 1 of the Harbor env-split migration.
#
# Crane-copies every repo+tag under the legacy base-images/ project to
# the new base-images-prod/ project (same behaviour for charts/ if it
# had any artifacts). Copy is done by digest — bit-for-bit identical,
# same layer blobs, same manifest, same OCI referrers (cosign sigs and
# attestations). Existing consumers keep working because the old
# project is untouched during the grace period.
#
# Scope is intentionally limited to Phase 1 projects (base-images,
# charts). The script is designed to be deleted after Phase 5 — it's
# one-shot migration code, not ongoing tooling.
#
# Usage:
#   scripts/harbor-migrate-phase1.sh             # dry-run (default)
#   scripts/harbor-migrate-phase1.sh --go        # actually copy
#   scripts/harbor-migrate-phase1.sh --go --force-overwrite
#                                                # re-copy tags that
#                                                # already exist in dst
#
# Prereqs:
#   - HARBOR_ADMIN_PASSWORD or Vault access for kv-mgt/apps/harbor/runtime
#   - Destination projects (base-images-prod, charts-prod) MUST exist
#     (ansible creates them — run the role first).
#
# Implementation note:
#   Uses Harbor's native artifact-copy REST API (POST /api/v2.0/projects/
#   <dst>/repositories/<repo>/artifacts?from=<src>/<repo>:<tag>) rather
#   than crane copy. Reasons:
#     - Server-side operation — no local bandwidth / file descriptors.
#     - Crane has a pathological "bad file descriptor" failure mode on
#       macOS against some TLS endpoints that no amount of ulimit
#       tuning fixes.
#     - Same Harbor instance — the API guarantees bit-for-bit identical
#       manifest+layers (no re-push, just registry metadata linkage).
#
# Safety:
#   - Dry-run by default. Lists every planned copy with source+dest
#     digests. Only --go performs the actual copy.
#   - Skips tags that already exist in dst with matching digest (safe
#     to re-run). Use --force-overwrite to re-copy regardless.
#   - Never deletes anything from src. Legacy base-images/ stays intact
#     for the grace period.

set -euo pipefail

HARBOR_HOST="${HARBOR_HOST:-harbor.mgt.newen.au}"
HARBOR_USER="${HARBOR_USER:-admin}"
MIGRATE_PROJECTS=(base-images charts)

DRY_RUN=true
FORCE_OVERWRITE=false
for arg in "$@"; do
  case "${arg}" in
    --go)              DRY_RUN=false ;;
    --force-overwrite) FORCE_OVERWRITE=true ;;
    -h|--help)
      sed -n '2,35p' "$0" | sed 's/^# \{0,1\}//'
      exit 0 ;;
    *)
      echo "unknown arg: ${arg}" >&2
      exit 2 ;;
  esac
done

# ── Resolve Harbor admin password ─────────────────────────────────────
if [ -z "${HARBOR_ADMIN_PASSWORD:-}" ]; then
  if command -v vault >/dev/null 2>&1; then
    HARBOR_ADMIN_PASSWORD=$(VAULT_ADDR="${VAULT_ADDR:-https://vault.mgt.newen.au:8200}" \
      vault kv get -mount=kv-mgt -field=harbor_admin_password apps/harbor/runtime 2>/dev/null || true)
  fi
fi
if [ -z "${HARBOR_ADMIN_PASSWORD:-}" ]; then
  echo "ERROR: HARBOR_ADMIN_PASSWORD not set and Vault lookup failed." >&2
  echo "       Set it explicitly or run: export VAULT_ADDR=https://vault.mgt.newen.au:8200" >&2
  exit 1
fi

command -v /usr/bin/curl >/dev/null 2>&1 || {
  echo "ERROR: curl not available at /usr/bin/curl" >&2
  exit 1
}

# ── Discover repos + tags in each source project ─────────────────────
_api() {
  /usr/bin/curl -sS -u "${HARBOR_USER}:${HARBOR_ADMIN_PASSWORD}" "$@"
}

_list_repos() {
  local project="$1"
  _api "https://${HARBOR_HOST}/api/v2.0/projects/${project}/repositories?page_size=100" \
    | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    # Harbor returns name as 'project/repo'; strip project prefix.
    print(r['name'].split('/', 1)[1])
"
}

_list_tags() {
  local project="$1" repo="$2"
  # Path-encode forward slashes in repo name for the REST endpoint.
  local enc="${repo//\//%252F}"
  _api "https://${HARBOR_HOST}/api/v2.0/projects/${project}/repositories/${enc}/artifacts?with_tag=true&page_size=100" \
    | python3 -c "
import json, sys
for a in json.load(sys.stdin):
    for t in a.get('tags') or []:
        print(t['name'], a['digest'])
"
}

_dst_digest() {
  # Fetch digest of an artifact by tag from Harbor's API. Usage:
  #   _dst_digest <project> <repo> <tag>
  local project="$1" repo="$2" tag="$3"
  local enc="${repo//\//%252F}"
  _api "https://${HARBOR_HOST}/api/v2.0/projects/${project}/repositories/${enc}/artifacts/${tag}" \
    2>/dev/null | python3 -c "
import json, sys
try:
    print(json.load(sys.stdin).get('digest', ''))
except Exception:
    pass
" 2>/dev/null
}

_copy_artifact() {
  # Harbor native artifact copy. Usage:
  #   _copy_artifact <src_project> <dst_project> <repo> <tag>
  local src="$1" dst="$2" repo="$3" tag="$4"
  local enc="${repo//\//%252F}"
  local code
  code=$(_api -o /dev/null -w "%{http_code}" -X POST \
    "https://${HARBOR_HOST}/api/v2.0/projects/${dst}/repositories/${enc}/artifacts?from=${src}/${repo}:${tag}")
  [ "${code}" = "201" ]
}

# ── Plan + execute ────────────────────────────────────────────────────
total_planned=0
total_skipped=0
total_copied=0
total_failed=0

for project in "${MIGRATE_PROJECTS[@]}"; do
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Project: ${project}  →  ${project}-prod"
  echo "════════════════════════════════════════════════════════════════"

  # Destination exists?
  http=$(_api -o /dev/null -w "%{http_code}" "https://${HARBOR_HOST}/api/v2.0/projects/${project}-prod")
  if [ "${http}" != "200" ]; then
    echo "SKIP: destination project '${project}-prod' doesn't exist yet."
    echo "      Run the sw_supply_chain ansible role first."
    continue
  fi

  repos=$(_list_repos "${project}")
  if [ -z "${repos}" ]; then
    echo "  (no repos in ${project} — nothing to migrate)"
    continue
  fi

  while IFS= read -r repo; do
    [ -z "${repo}" ] && continue
    echo ""
    echo "── ${project}/${repo} ──"

    tags=$(_list_tags "${project}" "${repo}")
    if [ -z "${tags}" ]; then
      echo "  (no tagged artifacts)"
      continue
    fi

    while IFS=' ' read -r tag src_digest; do
      [ -z "${tag}" ] && continue
      total_planned=$((total_planned + 1))

      existing=$(_dst_digest "${project}-prod" "${repo}" "${tag}")
      if [ -n "${existing}" ] && [ "${existing}" = "${src_digest}" ] \
         && [ "${FORCE_OVERWRITE}" = "false" ]; then
        echo "  = ${tag}  (already in dst at ${existing:0:19}, skipping)"
        total_skipped=$((total_skipped + 1))
        continue
      fi

      if [ "${DRY_RUN}" = "true" ]; then
        echo "  ~ ${tag}  ${src_digest:0:19} → ${project}-prod/${repo}:${tag}  (dry-run)"
        continue
      fi

      if _copy_artifact "${project}" "${project}-prod" "${repo}" "${tag}"; then
        new_digest=$(_dst_digest "${project}-prod" "${repo}" "${tag}")
        if [ "${new_digest}" = "${src_digest}" ]; then
          echo "  ✓ ${tag}  ${src_digest:0:19}"
          total_copied=$((total_copied + 1))
        else
          echo "  ! ${tag}  digest mismatch — src=${src_digest:0:19} dst=${new_digest:0:19}" >&2
          total_failed=$((total_failed + 1))
        fi
      else
        echo "  ✗ ${tag}  Harbor copy API rejected request" >&2
        total_failed=$((total_failed + 1))
      fi
    done <<< "${tags}"
  done <<< "${repos}"
done

# ── Summary ───────────────────────────────────────────────────────────
echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Summary"
echo "════════════════════════════════════════════════════════════════"
if [ "${DRY_RUN}" = "true" ]; then
  echo "  Mode:    DRY-RUN (no changes made). Re-run with --go to apply."
else
  echo "  Mode:    EXECUTE"
fi
echo "  Planned: ${total_planned}"
echo "  Copied:  ${total_copied}"
echo "  Skipped: ${total_skipped}  (already present with matching digest)"
echo "  Failed:  ${total_failed}"

[ "${total_failed}" -eq 0 ] || exit 1
