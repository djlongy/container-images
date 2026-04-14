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

```bash
./scripts/add-image.sh redis
```

This scaffolds `images/redis/` with `image.env` and `ci.yml`, and adds the
include to `.gitlab-ci.yml`. Then:

1. Edit `images/redis/image.env` — set `TAG` and `SOURCE`
2. Push to `main`

The `ci.yml` is auto-generated from `.ci/image-ci.yml.template` — never edit
it by hand. To change the pipeline structure for all images, edit the template
and run `./scripts/add-image.sh --regenerate`.

### First clone — create your local config

`global.env` is gitignored so your real registry hostnames, proxy URLs,
and vendor strings never get committed. On a fresh clone:

```bash
cp global.env.example global.env
$EDITOR global.env     # set PULL_REGISTRY, PUSH_REGISTRY, etc.
```

`build.sh`, `check-updates.sh`, and the CI templates fall back to
`global.env.example` when `global.env` doesn't exist, so CI runners
that populate variables via pipeline env vars instead of a file still
work without modification.

### Build locally

```bash
# Values come from global.env; shell exports still win as overrides
./scripts/build.sh prometheus             # Build only
./scripts/build.sh prometheus --push      # Build and push
./scripts/build.sh --list                 # List available images

# One-off override without editing global.env
PULL_REGISTRY=harbor.example.com ./scripts/build.sh nginx
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
| `PULL_REGISTRY` | global.env / CI variable | Registry proxy/cache base images are pulled FROM |
| `PUSH_REGISTRY` | global.env / CI variable | Registry built images are pushed TO (defaults to `${PULL_REGISTRY}`) |
| `PUSH_PROJECT` | global.env / CI variable | Target project/repo prefix |
| `VENDOR` | global.env / CI variable | Vendor label value |
| `PUSH_REGISTRY_USER` | CI variable | Registry push username |
| `PUSH_REGISTRY_PASSWORD` | CI variable (masked) | Registry push password |
| `CA_CERT` | CI variable | PEM content of CA cert to inject |
| `FORCE_ALL` | CI variable | `true` to rebuild all images |
| `ENABLE_PROD_PROMOTE` | CI variable | `true` to show manual promote-to-prod jobs |
| `BUILDER_IMAGE` | global.env / CI variable | Alpine image for cert builder stage (via registry proxy) |
| `APK_MIRROR` | global.env / CI variable | Alpine apk mirror base URL (replaces dl-cdn.alpinelinux.org/alpine) |
| `PROD_PUSH_REGISTRY` | CI variable | Production registry hostname |
| `PROD_PUSH_PROJECT` | CI variable | Prod project/path (defaults to `PUSH_PROJECT`) |
| `PROD_PUSH_REGISTRY_USER` | CI variable | Prod registry username |
| `PROD_PUSH_REGISTRY_PASSWORD` | CI variable (masked) | Prod registry password |

## Repository Structure

```
container-images/
├── Dockerfile              # Shared template (labels + remediation + certs)
├── certs/                  # CA certs injected at build time (gitignored)
├── global.env.example      # Versioned template — cp to global.env and edit
├── global.env              # Local overrides (gitignored)
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
Remediation is **distro-aware**: each image declares `DISTRO` in `image.env`
and `build.sh` picks the matching default script from `scripts/remediate/`.
An image that needs custom logic can drop its own `images/<name>/remediate.sh`
to override the default.

**Resolution order when `REMEDIATE=true`:**

1. `images/<name>/remediate.sh` — per-image override (wins if present)
2. `scripts/remediate/${DISTRO}.sh` — shared distro default
3. Hard error if neither exists

**Shipped defaults:**

| DISTRO | Script | Command |
|--------|--------|---------|
| `alpine` | `scripts/remediate/alpine.sh` | `apk upgrade --no-cache` |
| `debian` | `scripts/remediate/debian.sh` | `apt-get -y --only-upgrade upgrade` |
| `ubuntu` | `scripts/remediate/ubuntu.sh` | `apt-get -y --only-upgrade upgrade` |
| `ubi` | `scripts/remediate/ubi.sh` | `microdnf -y update` (or `dnf`) |

**Usage:**

1. Set flags in `image.env`:
   ```bash
   DISTRO="alpine"          # Required — chooses the remediation script
   REMEDIATE="true"
   ORIGINAL_USER="nginx"    # Upstream USER to restore after patching
   ```

2. Push to `main` — the image rebuilds with the distro default applied.

3. (Optional) Drop `images/<name>/remediate.sh` for image-specific patches.

When upstream releases a fix, bump `TAG` and remove any per-image script.

**Note:** This only works for OS-level CVEs (Alpine/Debian packages). CVEs
in compiled binaries (Go stdlib, Rust deps) require an upstream release —
they can't be patched by package upgrades.

### CA Certificate Injection

Inject company root CAs into the image trust store. Works with any base image
(Alpine, Debian, distroless, scratch) via a multi-stage builder pattern that
merges your CA with the upstream bundle (nothing is lost).

CA certs are **never stored in the repo** — they're injected at build time
from one of three sources (checked in order):

1. **`CA_CERT` env / CI variable** — paste PEM content directly:
   ```bash
   # CI: set CA_CERT as a pipeline variable (GitLab, Bamboo, GitHub Actions)
   # Local:
   export CA_CERT="$(cat /path/to/your-ca.crt)"
   ./scripts/build.sh nginx
   ```

2. **HashiCorp Vault** — `build.sh` pulls automatically if `vault` CLI is available:
   ```bash
   # Uses VAULT_KV_MOUNT (default: secret) and VAULT_CA_PATH (default: pki/root-ca)
   ./scripts/build.sh nginx
   ```

3. **Files in `certs/` directory** — drop `.crt` files directly (gitignored):
   ```bash
   # Useful for local testing or runners that pre-populate certs/
   cp /path/to/company-root-ca.crt certs/
   ./scripts/build.sh nginx
   ```

The Dockerfile picks up **all** `.crt` files from `certs/` regardless of how
they got there. Multiple CAs are supported — just add more `.crt` files.

Then set flags in `image.env`:
```bash
INJECT_CERTS="true"
ORIGINAL_USER="nobody"    # Upstream USER to restore after cert injection
```

The `ORIGINAL_USER` must match the upstream image's USER (check with
`docker inspect <image> --format='{{.Config.User}}'`).

### Air-Gapped / Proxy Environments

If your environment has no direct internet access, all external dependencies
can be routed through a registry proxy (Nexus, Artifactory, Harbor, etc.).
Three variables control this — all set in `global.env` or as CI variables:

**`PULL_REGISTRY`** — Docker image proxy (already required for `SOURCE` in image.env).

**`BUILDER_IMAGE`** — The Alpine image used internally for cert building.
Defaults to `${PULL_REGISTRY}/docker-hub/library/alpine:3.21` so it pulls through
your Docker Hub proxy instead of hitting Docker Hub directly.

**`APK_MIRROR`** — Alpine package mirror base URL. Replaces
`dl-cdn.alpinelinux.org/alpine` in `/etc/apk/repositories` so `apk` fetches
packages through your proxy. Version paths (`v3.21/main`, `v3.21/community`)
are preserved automatically.

```bash
# global.env — example for Nexus
BUILDER_IMAGE="${BUILDER_IMAGE:-${PULL_REGISTRY}/docker-hub/library/alpine:3.21}"
APK_MIRROR="${APK_MIRROR:-https://nexus.example.com/repository/alpine-proxy}"
```

#### Nexus Sonatype Setup

Create an Alpine proxy repository using the **raw** format (Alpine repos are
static file trees, not a package API):

1. Nexus Admin → Repositories → Create repository → **raw (proxy)**
2. **Name**: `alpine-proxy`
3. **Remote URL**: `https://dl-cdn.alpinelinux.org/alpine`
4. **Content max age**: 1440 (24h) — packages are immutable per version
5. **Metadata max age**: 60 (1h) — APKINDEX refreshes periodically
6. **Strict content type validation**: disabled (Alpine serves mixed types)

Then set `APK_MIRROR` to the repo URL:
```bash
APK_MIRROR="https://nexus.example.com/repository/alpine-proxy"
```

#### Self-Signed CA Bootstrap (Chicken-and-Egg)

If your proxy uses a TLS certificate signed by an internal CA, there is a
bootstrapping problem: the container needs to trust the CA to reach the proxy,
but it needs the proxy to install `ca-certificates`.

This is handled automatically. The Dockerfile injects CA certs from `certs/`
directly into `/etc/ssl/certs/ca-certificates.crt` (a plain `cat` append)
**before** any `apk` command runs. This requires no package install — the
file already exists in base Alpine and is read by OpenSSL/libssl. The sequence:

1. `COPY certs/*.crt` → `cat` into system trust bundle (bootstrap)
2. `apk` now trusts the proxy's TLS cert and can install packages
3. `update-ca-certificates` runs later to build the proper merged bundle

For CI jobs, the same bootstrap uses the `CA_CERT` CI variable:
```yaml
# Automatically injected before apk in validate-ci and check-updates jobs
- if [ -n "${CA_CERT}" ]; then echo "${CA_CERT}" >> /etc/ssl/certs/ca-certificates.crt; fi
```

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
IMAGE_NAME="prometheus"                                   # Repo name in target registry
TAG="v3.11.0"                                             # Upstream tag to pull
DISTRO="busybox"                                          # Base distro (alpine|debian|ubuntu|ubi|busybox|scratch)
SOURCE="${PULL_REGISTRY}/docker-hub/prom/prometheus"      # Pull path (via proxy/cache)

# ── Optional: registry destination ───────────────────────────────────
# Override global PUSH_PROJECT for per-tenant or per-team paths.
# PUSH_PROJECT="myproject"    # → ${PUSH_REGISTRY}/myproject/prometheus

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

1. **build** — BuildKit pulls from proxy/cache, adds provenance labels, pushes to QA/dev registry
2. **scan** — Trivy vulnerability gate + Syft SBOM generation (CycloneDX)
3. **sign** — Cosign signature + attestations (SBOM, SLSA provenance, vuln)
4. **gate** — Supply chain readiness check
5. **promote** *(manual, optional)* — Copy exact image (same digest) to production registry

Only images whose directory changed are built (GitLab `rules: changes:`).

The promote stage uses `crane copy` for bit-for-bit registry-to-registry transfer —
no rebuild, no new layers, same digest guaranteed. Requires manual approval (click
"play" in the pipeline UI). Disabled by default — set `ENABLE_PROD_PROMOTE=true`
to enable.

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
