#!/usr/bin/env bash
# Phase 1 of the Harbor env-subpath migration.
#
# Re-homes every legacy flat repo (base-images/nginx, charts/foo, etc.)
# into the prod/ subpath inside the same Harbor project via Harbor's
# native artifact-copy REST API. Existing tags are preserved at their
# old flat location during the grace period so GitOps references keep
# resolving; Phase 5 deletes the flat duplicates once every consumer
# has been repointed.
#
# Before:   harbor.mgt.newen.au/base-images/nginx:1.29.8-alpine-abc
# After:    harbor.mgt.newen.au/base-images/prod/nginx:1.29.8-alpine-abc
#           (same digest — intra-project manifest mount)
#
# Dev-subpath pushes (harbor.mgt.newen.au/base-images/dev/nginx:tag)
# come from future CI builds, not this script. Retention rule on
# dev/** prunes to last 6 tags; prod/** is immutable.
#
# Scope: Phase 1 projects only (base-images, charts). The script is
# one-shot migration code — delete after Phase 5.
#
# Usage:
#   scripts/harbor-migrate-phase1.sh                          # dry-run, Phase 1 default projects
#   scripts/harbor-migrate-phase1.sh --go                     # actually copy
#   scripts/harbor-migrate-phase1.sh --go --force-overwrite
#   scripts/harbor-migrate-phase1.sh --projects=platform,conduit
#                                                             # override the project list (Phase 2+)
#
# Prereqs:
#   - HARBOR_ADMIN_PASSWORD or Vault access at
#     kv-mgt/apps/harbor/runtime:harbor_admin_password
#
# Implementation: Harbor's POST /api/v2.0/projects/<dst>/repositories/
# <repo>/artifacts?from=<src>/<repo>:<tag> endpoint. Intra-project
# copies are manifest-mount operations — no blob re-upload, same digest
# guaranteed. The destination <dst> is the SAME project as <src>; only
# the <repo> path differs (nginx → prod/nginx).
#
# Safety:
#   - Dry-run by default. --go required to execute.
#   - Skips tags already present at dst with matching digest.
#   - Never deletes anything from src. Legacy flat tags stay for the
#     grace period until Phase 5.

set -euo pipefail

HARBOR_HOST="${HARBOR_HOST:-harbor.mgt.newen.au}"
HARBOR_USER="${HARBOR_USER:-admin}"
MIGRATE_PROJECTS=(base-images charts)
PROMOTION_SUBPATH="prod"

DRY_RUN=true
FORCE_OVERWRITE=false
for arg in "$@"; do
  case "${arg}" in
    --go)              DRY_RUN=false ;;
    --force-overwrite) FORCE_OVERWRITE=true ;;
    --projects=*)
      IFS=',' read -r -a MIGRATE_PROJECTS <<< "${arg#--projects=}" ;;
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

_api() {
  /usr/bin/curl -sS -u "${HARBOR_USER}:${HARBOR_ADMIN_PASSWORD}" "$@"
}

_list_repos_flat() {
  # List repos directly under <project>/ (i.e. no subpath prefix).
  # Skips anything already under dev/ or prod/ — those are either
  # post-migration or future CI builds, not legacy.
  local project="$1"
  _api "https://${HARBOR_HOST}/api/v2.0/projects/${project}/repositories?page_size=100" \
    | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    # Harbor returns 'project/repo' or 'project/sub/repo'
    name = r['name'].split('/', 1)[1] if '/' in r['name'] else r['name']
    if '/' not in name:
        print(name)
"
}

_list_tags() {
  local project="$1" repo="$2"
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
  # Usage: _dst_digest <project> <repo_with_subpath> <tag>
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
  # Usage: _copy_artifact <project> <src_repo> <dst_repo> <tag>
  # Intra-project copy: src and dst are the same project; only the
  # repo path differs (nginx → prod/nginx).
  local project="$1" src_repo="$2" dst_repo="$3" tag="$4"
  local enc="${dst_repo//\//%252F}"
  local code
  code=$(_api -o /dev/null -w "%{http_code}" -X POST \
    "https://${HARBOR_HOST}/api/v2.0/projects/${project}/repositories/${enc}/artifacts?from=${project}/${src_repo}:${tag}")
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
  echo "  Project: ${project}/  →  ${project}/${PROMOTION_SUBPATH}/"
  echo "════════════════════════════════════════════════════════════════"

  # Project exists?
  http=$(_api -o /dev/null -w "%{http_code}" "https://${HARBOR_HOST}/api/v2.0/projects/${project}")
  if [ "${http}" != "200" ]; then
    echo "SKIP: project '${project}' doesn't exist."
    continue
  fi

  repos=$(_list_repos_flat "${project}")
  if [ -z "${repos}" ]; then
    echo "  (no top-level repos to migrate — either empty or already under dev/prod/)"
    continue
  fi

  while IFS= read -r repo; do
    [ -z "${repo}" ] && continue
    dst_repo="${PROMOTION_SUBPATH}/${repo}"
    echo ""
    echo "── ${project}/${repo} → ${project}/${dst_repo} ──"

    tags=$(_list_tags "${project}" "${repo}")
    if [ -z "${tags}" ]; then
      echo "  (no tagged artifacts)"
      continue
    fi

    while IFS=' ' read -r tag src_digest; do
      [ -z "${tag}" ] && continue
      total_planned=$((total_planned + 1))

      existing=$(_dst_digest "${project}" "${dst_repo}" "${tag}")
      if [ -n "${existing}" ] && [ "${existing}" = "${src_digest}" ] \
         && [ "${FORCE_OVERWRITE}" = "false" ]; then
        echo "  = ${tag}  (already at ${dst_repo}:${tag} with matching digest)"
        total_skipped=$((total_skipped + 1))
        continue
      fi

      if [ "${DRY_RUN}" = "true" ]; then
        echo "  ~ ${tag}  ${src_digest:0:19} → ${dst_repo}:${tag}  (dry-run)"
        continue
      fi

      if _copy_artifact "${project}" "${repo}" "${dst_repo}" "${tag}"; then
        new_digest=$(_dst_digest "${project}" "${dst_repo}" "${tag}")
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
