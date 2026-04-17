#!/usr/bin/env bash
# renovate-smoke.sh
#
# Local smoke test for the Renovate config in this repo.
#
# Runs renovate/renovate:latest in --platform=local mode against the
# current working tree, using ./renovate.json as the config. It hits
# real Docker Hub to resolve upstream tags but never talks to GitLab
# or GitHub — no token required.
#
# Usage:
#   scripts/renovate-smoke.sh              # summary (pass/fail + update list)
#   scripts/renovate-smoke.sh --debug      # full renovate debug log to stdout
#   scripts/renovate-smoke.sh --validate   # just run renovate-config-validator
#
# Expected summary output:
#   ✓ config validated
#   ✓ regex manager matched 3 file(s): images/nginx/..., images/prometheus/..., images/renovate/...
#   updates detected:
#     library/nginx         1.29.8-alpine  →  1.30.0-alpine   (minor)
#     prom/prometheus       v3.11.2        →  (none)
#     renovate/renovate     43.127.0       →  (none)
#
# Requires: docker (Colima/Docker Desktop). First run pulls ~500MB.

set -eo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${REPO_ROOT}"

IMAGE="${RENOVATE_IMAGE:-renovate/renovate:latest}"
LOG_FILE="${TMPDIR:-/tmp}/renovate-smoke.$$.log"
trap 'rm -f "${LOG_FILE}"' EXIT

MODE="summary"
for arg in "$@"; do
  case "${arg}" in
    --debug)    MODE="debug" ;;
    --validate) MODE="validate" ;;
    -h|--help)
      sed -n '3,30p' "$0"
      exit 0
      ;;
  esac
done

if ! command -v docker >/dev/null 2>&1; then
  echo "error: docker not found (is Colima running?)" >&2
  exit 2
fi

if [[ ! -f renovate.json ]]; then
  echo "error: renovate.json not found at repo root" >&2
  exit 2
fi

# --- Always start with schema validation ---
echo ">>> validating renovate.json"
if ! docker run --rm -v "${REPO_ROOT}:/usr/src/app" -w /usr/src/app \
        "${IMAGE}" renovate-config-validator 2>&1 | tail -5 | grep -q "validated successfully"; then
  echo "✗ renovate-config-validator failed — re-running with full output:" >&2
  docker run --rm -v "${REPO_ROOT}:/usr/src/app" -w /usr/src/app \
    "${IMAGE}" renovate-config-validator
  exit 1
fi
echo "✓ config validated"

if [[ "${MODE}" == "validate" ]]; then
  exit 0
fi

# --- Run renovate in local-platform mode ---
echo ">>> running renovate --platform=local (this hits Docker Hub, ~30s)"
docker run --rm -v "${REPO_ROOT}:/usr/src/app" -w /usr/src/app \
  -e RENOVATE_PLATFORM=local \
  -e RENOVATE_CONFIG_FILE=/usr/src/app/renovate.json \
  -e LOG_LEVEL=debug \
  "${IMAGE}" renovate > "${LOG_FILE}" 2>&1 || {
  echo "✗ renovate run exited non-zero — see log at ${LOG_FILE}" >&2
  tail -30 "${LOG_FILE}" >&2
  exit 1
}

if [[ "${MODE}" == "debug" ]]; then
  cat "${LOG_FILE}"
  exit 0
fi

# --- Parse the log for a human summary ---
matched_line=$(grep "Matched .* file(s) for manager regex" "${LOG_FILE}" | tail -1 || true)
if [[ -z "${matched_line}" ]]; then
  echo "✗ custom regex manager did not match any files — is the annotation comment in place?" >&2
  exit 1
fi
echo "✓ ${matched_line#*DEBUG: }"

echo ""
echo "updates detected:"
# Each regex package has a `deps` block with depName, currentValue, updates[].
# Use python to walk the JSON-in-log for clean output.
python3 - "${LOG_FILE}" <<'PY'
import json, re, sys, pathlib
log = pathlib.Path(sys.argv[1]).read_text()
# Find the final package-file JSON dump — it appears after
# `DEBUG: packageFiles with updates (repository=local)`
m = re.search(r'DEBUG: packageFiles with updates \(repository=local\)\s*\n\s*"config":\s*(\{.*?\n       \})\s*\n', log, re.DOTALL)
if not m:
    print("  (could not parse packageFiles block — run with --debug to inspect)")
    sys.exit(0)
raw = m.group(1)
try:
    data = json.loads(raw)
except json.JSONDecodeError as e:
    print(f"  (json parse failed: {e})")
    sys.exit(0)
regex_pkgs = data.get("regex", [])
if not regex_pkgs:
    print("  (no regex packages in the dump — check the log manually)")
    sys.exit(0)
seen = set()
for pf in regex_pkgs:
    for dep in pf.get("deps", []):
        name = dep.get("depName", "?")
        cur  = dep.get("currentValue", "?")
        if (name, cur) in seen:
            continue
        seen.add((name, cur))
        ups  = dep.get("updates", [])
        if ups:
            u = ups[0]
            print(f"  {name:25s} {cur:25s} → {u.get('newValue','?'):25s} ({u.get('updateType','?')})")
        else:
            print(f"  {name:25s} {cur:25s} → (none)")
PY
