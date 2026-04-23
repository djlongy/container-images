#!/usr/bin/env bash
# Phase 3 of the Harbor restructure — env-at-project layout.
#
# Move every artifact out of the legacy team-named projects into the
# new env-named projects:
#
#   base-images/<repo>:tag       → shared/base/<repo>:tag
#   base-images/dev/<repo>:tag   → shared/base/<repo>:tag (idempotent — same digest)
#   base-images/prod/<repo>:tag  → shared/base/<repo>:tag (idempotent — same digest)
#   <team>/<repo>:tag            → prod/<team>/<repo>:tag
#   <team>/dev/<repo>:tag        → dev/<team>/<repo>:tag
#   <team>/prod/<repo>:tag       → prod/<team>/<repo>:tag
#
# Where <team> ∈ { platform, apps, auslandirect, bookkeep, conduit }
# and the empty 'charts' project produces no work.
#
# Implementation: Harbor's POST /api/v2.0/projects/<dst>/repositories/
# <repo>/artifacts?from=<src_project>/<src_repo>:<tag> handles cross-
# project copies via manifest mount — same digest preserved bit-for-bit,
# no blob re-upload.
#
# Usage:
#   scripts/harbor-migrate-phase3.sh             # dry-run
#   scripts/harbor-migrate-phase3.sh --go        # execute

set -euo pipefail

HARBOR_HOST="${HARBOR_HOST:-harbor.mgt.newen.au}"
HARBOR_USER="${HARBOR_USER:-admin}"

DRY_RUN=true
for arg in "$@"; do
  case "${arg}" in
    --go)        DRY_RUN=false ;;
    -h|--help)   sed -n '2,30p' "$0" | sed 's/^# \{0,1\}//' ; exit 0 ;;
    *)           echo "unknown arg: ${arg}" >&2 ; exit 2 ;;
  esac
done

# ── Resolve Harbor admin password ─────────────────────────────────────
if [ -z "${HARBOR_ADMIN_PASSWORD:-}" ]; then
  if command -v vault >/dev/null 2>&1; then
    HARBOR_ADMIN_PASSWORD=$(VAULT_ADDR="${VAULT_ADDR:-https://vault.mgt.newen.au:8200}" \
      vault kv get -mount=kv-mgt -field=harbor_admin_password apps/harbor/runtime 2>/dev/null || true)
  fi
fi
[ -z "${HARBOR_ADMIN_PASSWORD:-}" ] && {
  echo "ERROR: HARBOR_ADMIN_PASSWORD not set and Vault lookup failed." >&2
  exit 1
}

_api() { /usr/bin/curl -sS -u "${HARBOR_USER}:${HARBOR_ADMIN_PASSWORD}" "$@"; }

# ── Routing rules ─────────────────────────────────────────────────────
# Given a (src_project, src_repo) pair (where src_repo may include
# dev/ or prod/ subpath prefix), return (dst_project, dst_repo).
# Echoed as two space-separated values.
_route() {
  local src_proj="$1" src_repo="$2"
  local dst_proj dst_repo

  case "${src_proj}" in
    base-images)
      # Everything in base-images becomes shared/base/<image>.
      # Strip any leading dev/ or prod/ from src_repo.
      dst_proj="shared"
      case "${src_repo}" in
        dev/*|prod/*) dst_repo="base/${src_repo#*/}" ;;
        *)            dst_repo="base/${src_repo}" ;;
      esac
      ;;
    *)
      # All other team projects: keep <team>/ as the first segment of
      # the dst repo, env subpath becomes the dst project.
      case "${src_repo}" in
        dev/*)  dst_proj="dev";  dst_repo="${src_proj}/${src_repo#dev/}"  ;;
        prod/*) dst_proj="prod"; dst_repo="${src_proj}/${src_repo#prod/}" ;;
        *)      dst_proj="prod"; dst_repo="${src_proj}/${src_repo}"       ;;
      esac
      ;;
  esac
  echo "${dst_proj} ${dst_repo}"
}

_list_repos() {
  # All repos in a project, including subpath ones (dev/x, prod/x).
  local project="$1"
  _api "https://${HARBOR_HOST}/api/v2.0/projects/${project}/repositories?page_size=100" \
    | python3 -c "
import json, sys
for r in json.load(sys.stdin):
    n = r['name']
    print(n.split('/', 1)[1] if '/' in n else n)
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
  local project="$1" repo="$2" tag="$3"
  local enc="${repo//\//%252F}"
  _api "https://${HARBOR_HOST}/api/v2.0/projects/${project}/repositories/${enc}/artifacts/${tag}" \
    2>/dev/null | python3 -c "
import json, sys
try: print(json.load(sys.stdin).get('digest', ''))
except Exception: pass
" 2>/dev/null
}

_copy_artifact() {
  local src_proj="$1" src_repo="$2" dst_proj="$3" dst_repo="$4" tag="$5"
  local enc_dst="${dst_repo//\//%252F}"
  local code
  code=$(_api -o /dev/null -w "%{http_code}" -X POST \
    "https://${HARBOR_HOST}/api/v2.0/projects/${dst_proj}/repositories/${enc_dst}/artifacts?from=${src_proj}/${src_repo}:${tag}")
  [ "${code}" = "201" ]
}

# ── Plan + execute ────────────────────────────────────────────────────
SRC_PROJECTS=(base-images platform apps auslandirect bookkeep conduit charts)

total_planned=0 ; total_skipped=0 ; total_copied=0 ; total_failed=0

for src_proj in "${SRC_PROJECTS[@]}"; do
  echo ""
  echo "════════════════════════════════════════════════════════════════"
  echo "  Source project: ${src_proj}"
  echo "════════════════════════════════════════════════════════════════"

  http=$(_api -o /dev/null -w "%{http_code}" "https://${HARBOR_HOST}/api/v2.0/projects/${src_proj}")
  if [ "${http}" != "200" ]; then
    echo "SKIP: project '${src_proj}' doesn't exist."
    continue
  fi

  repos=$(_list_repos "${src_proj}")
  if [ -z "${repos}" ]; then
    echo "  (empty)"
    continue
  fi

  while IFS= read -r repo; do
    [ -z "${repo}" ] && continue
    read -r dst_proj dst_repo < <(_route "${src_proj}" "${repo}")
    echo ""
    echo "── ${src_proj}/${repo}  →  ${dst_proj}/${dst_repo} ──"

    tags=$(_list_tags "${src_proj}" "${repo}")
    if [ -z "${tags}" ]; then
      echo "  (no tagged artifacts)"
      continue
    fi

    while IFS=' ' read -r tag src_digest; do
      [ -z "${tag}" ] && continue
      total_planned=$((total_planned + 1))

      existing=$(_dst_digest "${dst_proj}" "${dst_repo}" "${tag}")
      if [ -n "${existing}" ] && [ "${existing}" = "${src_digest}" ]; then
        echo "  = ${tag}  (already at ${dst_proj}/${dst_repo}:${tag})"
        total_skipped=$((total_skipped + 1))
        continue
      fi

      if [ "${DRY_RUN}" = "true" ]; then
        echo "  ~ ${tag}  ${src_digest:0:19}  (dry-run)"
        continue
      fi

      if _copy_artifact "${src_proj}" "${repo}" "${dst_proj}" "${dst_repo}" "${tag}"; then
        new=$(_dst_digest "${dst_proj}" "${dst_repo}" "${tag}")
        if [ "${new}" = "${src_digest}" ]; then
          echo "  ✓ ${tag}  ${src_digest:0:19}"
          total_copied=$((total_copied + 1))
        else
          echo "  ! ${tag}  digest mismatch: src=${src_digest:0:19} dst=${new:0:19}" >&2
          total_failed=$((total_failed + 1))
        fi
      else
        echo "  ✗ ${tag}  copy failed (often: dst project missing immutability conflict)" >&2
        total_failed=$((total_failed + 1))
      fi
    done <<< "${tags}"
  done <<< "${repos}"
done

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Summary"
echo "════════════════════════════════════════════════════════════════"
[ "${DRY_RUN}" = "true" ] \
  && echo "  Mode:    DRY-RUN. Re-run with --go." \
  || echo "  Mode:    EXECUTE"
echo "  Planned: ${total_planned}"
echo "  Copied:  ${total_copied}"
echo "  Skipped: ${total_skipped}  (already present, matching digest)"
echo "  Failed:  ${total_failed}"
[ "${total_failed}" -eq 0 ] || exit 1
