# container-images

Upstream container image promotion with DevSecOps pipeline.

Pulls third-party images through a registry proxy/cache, re-tags with a
traceable `<tag>-<commit>` identifier, scans for vulnerabilities, generates
SBOMs, signs with cosign, and pushes to your target registry.

All registry URLs, credentials, and settings are configurable via environment
variables or CI/CD pipeline variables — nothing is hardcoded.

## Quick Start

### Bump an existing image tag

1. Edit `images/<name>/image.env` — update `TAG`
2. Push to `main`
3. Pipeline builds, scans, signs only the changed image

### Add a new image

1. Copy an existing image directory:
   ```bash
   cp -r images/prometheus images/redis
   ```

2. Edit `images/redis/image.env` — set IMAGE_NAME, TAG, SOURCE

3. Edit `images/redis/ci.yml` — find-replace `prometheus` → `redis`

4. Add one include line to `.gitlab-ci.yml`:
   ```yaml
   - local: 'images/redis/ci.yml'
   ```

5. Push to `main`

### Build locally

```bash
export REGISTRY="registry.example.com"    # Your registry
./scripts/build.sh prometheus             # Build only
./scripts/build.sh prometheus --push      # Build and push
./scripts/build.sh --list                 # List available images
```

### Check for updates

```bash
./scripts/check-updates.sh                 # Report available updates
./scripts/check-updates.sh --create-mr     # GitLab: open MR per update
./scripts/check-updates.sh --create-pr     # GitHub/Bitbucket: open PR per update
```

Compares current TAG in each `image.env` against upstream registry tags.
Handles suffixed tags (e.g. `-alpine`, `-slim`) by matching only equivalent
variants. Run on a schedule to replace Renovate-style mutable tag pulling
with pinned version proposals.

### Force rebuild all images

Set `FORCE_ALL=true` in the CI/CD pipeline variables.

## Configuration

All settings come from environment variables or CI/CD pipeline variables.
`global.env` provides defaults that can be overridden.

| Variable | Where to set | Purpose |
|----------|-------------|---------|
| `REGISTRY` | global.env / CI variable | Target registry hostname |
| `REGISTRY_PROJECT` | global.env / CI variable | Target project/repo prefix |
| `VENDOR` | global.env / CI variable | Vendor label value |
| `REGISTRY_USER` | CI variable | Registry push username |
| `REGISTRY_PASSWORD` | CI variable (masked) | Registry push password |
| `CA_CERT` | CI variable | PEM content of CA cert to inject |
| `FORCE_ALL` | CI variable | `true` to rebuild all images |

## Repository Structure

```
container-images/
├── Dockerfile              # Shared template (labels + remediation + certs)
├── certs/                  # CA certs injected at build time (gitignored)
├── global.env              # Default config (REGISTRY, REGISTRY_PROJECT, VENDOR)
├── .ci/
│   └── promote.yml         # Reusable CI template (sources image.env at runtime)
├── scripts/
│   └── build.sh            # Agnostic local build script
├── images/
│   └── <name>/
│       ├── image.env       # TAG, SOURCE, enrichment flags (EDIT THIS)
│       ├── ci.yml          # GitLab CI jobs — boilerplate, no version strings
│       ├── remediate.sh    # (optional) CVE remediation script
│       └── Dockerfile      # (optional) Custom override — only if shared won't do
├── .gitlab-ci.yml          # Root pipeline (includes per-image ci.yml)
└── README.md
```

## Image Enrichment

The shared `Dockerfile` supports modular enrichment controlled by flags in `image.env`.
Docker conditional multi-stage builds ensure unused features add zero layers.

### CVE Remediation

Patch OS-level vulnerabilities without waiting for an upstream release.
Each image gets its own `remediate.sh` script that runs targeted package
upgrades. The shared Dockerfile runs it as a conditional build stage.

1. Create `images/<name>/remediate.sh`:
   ```bash
   #!/bin/sh
   # Alpine — upgrade vulnerable packages
   apk upgrade --no-cache libcrypto3 libssl3 libxml2

   # Debian — same idea
   # apt-get update && apt-get install -y --only-upgrade libssl3 && rm -rf /var/lib/apt/lists/*
   ```

2. Set flags in `image.env`:
   ```bash
   REMEDIATE="true"
   ORIGINAL_USER="nginx"    # Upstream USER to restore after patching
   ```

3. Push to `main` — the image rebuilds with patches applied.

When upstream releases a fix, bump `TAG` and delete `remediate.sh`.

**Note:** This only works for OS-level CVEs (Alpine/Debian packages). CVEs
in compiled binaries (Go stdlib, Rust deps) require an upstream release —
they can't be patched by package upgrades.

### CA Certificate Injection

Inject company root CAs into the image trust store. Works with any base image
(Alpine, Debian, distroless, scratch) via a multi-stage builder pattern that
merges your CA with the upstream bundle (nothing is lost).

CA certs are **never stored in the repo** — they're injected at build time:

**In CI** — set `CA_CERT` as a CI/CD variable (paste the PEM content):
```
# GitLab: Settings → CI/CD → Variables → Add variable
# Bamboo: Plan Variables or Global Variables
# Key: CA_CERT   Value: <paste PEM content>
```

**Locally** — set `CA_CERT` env var or let `build.sh` pull from Vault:
```bash
# Option 1: env var
export CA_CERT="$(cat /path/to/your-ca.crt)"
./scripts/build.sh nginx

# Option 2: build.sh pulls from Vault (if vault CLI available)
./scripts/build.sh nginx
```

Then set flags in `image.env`:
```bash
INJECT_CERTS="true"
ORIGINAL_USER="nobody"    # Upstream USER to restore after cert injection
```

The `ORIGINAL_USER` must match the upstream image's USER (check with
`docker inspect <image> --format='{{.Config.User}}'`).

### Custom Dockerfile Override

For images that need build logic beyond what the shared template provides
(e.g., stripping shells, adding config files, patching binaries):

1. Create `images/<name>/Dockerfile` with your custom build
2. Set `CUSTOM_DOCKERFILE="true"` in `image.env`

The custom Dockerfile has access to the full repo as build context
(including `certs/`).

## image.env Reference

```bash
# ── Required: used to pull and build the image ────────────────────────
IMAGE_NAME="prometheus"                             # Repo name in target registry
TAG="v3.11.0"                                       # Upstream tag to pull
SOURCE="${REGISTRY}/docker-hub/prom/prometheus"      # Pull path (via proxy/cache)

# ── Optional: registry destination ───────────────────────────────────
# Override global REGISTRY_PROJECT for per-tenant or per-team paths.
# REGISTRY_PROJECT="cDSS"    # → registry.example.com/cDSS/prometheus

# ── Optional: custom labels ──────────────────────────────────────────
# Create images/<name>/labels.env with one key=value per line.
# Upstream labels are inherited as-is — we never overwrite them.

# ── Optional: image enrichment ────────────────────────────────────────
REMEDIATE="false"             # true = run images/<name>/remediate.sh for CVE patches
INJECT_CERTS="false"          # true = inject CA certs into trust store
ORIGINAL_USER="nobody"        # Upstream USER (required when REMEDIATE or INJECT_CERTS=true)
CUSTOM_DOCKERFILE="false"     # true = use images/<name>/Dockerfile instead of shared
```

## Tag Format

`<upstream-tag>-<git-commit-short-hash>` — e.g. `v3.11.0-a1b2c3d`

- **Tag prefix**: identifies the upstream tag at a glance
- **Commit hash**: traces back to the exact commit that promoted this version
- **Immutable**: re-promoting the same tag produces a new promoted tag (different commit)

## Pipeline Stages

Each image runs through:

1. **build** — BuildKit pulls from proxy/cache, adds provenance labels, pushes to target registry
2. **scan** — Trivy vulnerability gate + Syft SBOM generation (CycloneDX)
3. **sign** — Cosign signature + attestations (SBOM, SLSA provenance, vuln)
4. **gate** — Supply chain readiness check

Only images whose directory changed are built (GitLab `rules: changes:`).

## OCI Metadata

Upstream labels (title, description, licenses, maintainer, etc.) are
**inherited from the base image** and never overwritten. We only add
promotion provenance labels:

| Label | Source | Purpose |
|-------|--------|---------|
| `org.opencontainers.image.vendor` | build | Organisation that promoted the image |
| `org.opencontainers.image.created` | build | Promotion build timestamp (ISO 8601) |
| `org.opencontainers.image.revision` | build | Git commit SHA of the promotion repo |
| `org.opencontainers.image.ref.name` | build | Promoted tag (`<tag>-<commit>`) |
| `org.opencontainers.image.base.name` | build | Actual SOURCE:TAG that was pulled |
| `promoted.from` | build | Same as base.name — the pull origin |
| `promoted.tag` | build | Same as ref.name — the promoted tag |
| *(upstream labels)* | inherited | title, description, licenses, maintainer, etc. |
| *(custom labels)* | image.env | Optional in-house metadata via `LABELS` |
