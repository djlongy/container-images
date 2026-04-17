# container-images

Upstream container image promotion with DevSecOps pipeline.

Pulls third-party images through a registry proxy/cache, re-tags with a
traceable `<tag>-<commit>` identifier, scans for vulnerabilities, generates
SBOMs, signs with cosign, and pushes to your target registry.

All registry URLs, credentials, and settings are configurable via environment
variables or CI/CD pipeline variables — nothing is hardcoded.

## Quick Start

### Bump an existing image tag

1. Edit `images/<name>/image.env.example` — update `UPSTREAM_TAG`
2. Push to `main`
3. Pipeline builds, scans, signs only the changed image

(If you have a local `images/<name>/image.env` for experimentation,
that file wins over the example but stays out of git. Bump the
example for shared/CI changes.)

### Add a new image

```bash
./scripts/add-image.sh redis
```

This scaffolds `images/redis/` with `image.env.example` and `ci.yml`, and
adds the include to `.gitlab-ci.yml`. Then:

1. Edit `images/redis/image.env.example` — set `UPSTREAM_REGISTRY`, `UPSTREAM_IMAGE`, `UPSTREAM_TAG`, `DISTRO`
2. Push to `main`

The `ci.yml` is auto-generated from `.ci/image-ci.yml.template` — never edit
it by hand. To change the pipeline structure for all images, edit the template
and run `./scripts/add-image.sh --regenerate`.

### First clone — create your local config

Two layers of config are shipped as `*.example` templates and gitignored
for local overrides. CI and fresh clones don't need any bootstrap — the
scripts all fall through to the `.example` files if the real file doesn't
exist, so everything works out of the box. Local customization is
opt-in: you copy only the files you want to tweak.

**Global** (registry hostnames, proxy URLs, vendor string):
```bash
cp global.env.example global.env
$EDITOR global.env
```

**Per-image** (pinned TAG, flag overrides — one team may want
`INJECT_CERTS=true` while another wants `false`; one team may want to
test a newer upstream TAG while the shared template stays stable):
```bash
cp images/nginx/image.env.example images/nginx/image.env
$EDITOR images/nginx/image.env
```

`build.sh`, `check-updates.sh`, and the CI templates all resolve via
`<file>` → `<file>.example` fallback, so CI runners that populate
variables via pipeline env vars instead of files still work without
modification.

**Local workspace (`local/`)**: for test runners, credential sourcing
scripts, private CLI cheatsheets, or any other file that references
real hostnames / team acronyms / tokens, create a `local/` directory
at the repo root. The entire directory is gitignored (see `.gitignore`),
so anything you put there stays on your machine and never needs
sanitization before a push. Typical contents:

```bash
mkdir -p local
# One-off: stash the vault lookups in a sourceable file
cat > local/credentials.env <<'EOF'
export VAULT_ADDR=https://vault.example.com:8200
export PUSH_REGISTRY_USER=admin
export PUSH_REGISTRY_PASSWORD=$(vault kv get -field=admin_password kv/apps/harbor/runtime)
export ARTIFACTORY_USER=abcd
export ARTIFACTORY_PASSWORD=$(vault kv get -field=abcd_password kv/apps/artifactory/runtime)
export ARTIFACTORY_TEAM=abcd
EOF
source local/credentials.env    # then run any build.sh command
```

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

Compares current `UPSTREAM_TAG` in each `image.env` against upstream registry tags.
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
| `PULL_REGISTRY` | global.env / CI variable | Registry proxy host for pulls (single-host / path-routed model) |
| `DOCKERHUB_MIRROR` | global.env / CI variable | Docker Hub mirror host — default `${PULL_REGISTRY}/docker-hub`; override for subdomain-routed proxies |
| `GHCR_MIRROR` | global.env / CI variable | GHCR mirror host — default `${PULL_REGISTRY}/ghcr-proxy` |
| `QUAY_MIRROR` | global.env / CI variable | Quay mirror host — default `${PULL_REGISTRY}/quay-proxy` |
| `PUSH_REGISTRY` | global.env / CI variable | Registry built images are pushed TO (defaults to `${PULL_REGISTRY}`) |
| `PUSH_PROJECT` | global.env / CI variable | Target project/repo prefix |
| `VENDOR` | global.env / CI variable | Vendor label value |
| `PUSH_REGISTRY_USER` | CI variable | Registry push username |
| `PUSH_REGISTRY_PASSWORD` | CI variable (masked) | Registry push password |
| `CA_CERT` | CI variable | PEM content of CA cert to inject |
| `FORCE_ALL` | CI variable | `true` to rebuild all images |
| `ENABLE_PROD_PROMOTE` | CI variable | `true` to show manual promote-to-prod jobs |
| `APK_MIRROR` | global.env / CI variable | Alpine apk mirror base URL (replaces dl-cdn.alpinelinux.org/alpine) |
| `APT_MIRROR` | global.env / CI variable | Debian/Ubuntu apt proxy base URL for remediation |
| `REGISTRY_KIND` | CI variable | `artifactory` to route `--push` through the Artifactory backend |
| `ARTIFACTORY_URL` | CI variable | Artifactory base URL (`https://artifactory.example.com` or `https://yourorg.jfrog.io`) |
| `ARTIFACTORY_USER` | CI variable | User with Deploy rights |
| `ARTIFACTORY_TOKEN` | CI variable (masked) | Access token (preferred) or `ARTIFACTORY_PASSWORD` for basic auth |
| `ARTIFACTORY_TEAM` | CI variable | Team acronym — referenced by layout templates. **Never committed.** |
| `ARTIFACTORY_PRO` | CI variable | Set to `true` to enable Pro features: `jf docker push`, project-scoped build info, Xray scan |
| `ARTIFACTORY_PROJECT` | CI variable | Project key for `--project` flag (defaults to `ARTIFACTORY_TEAM`) |
| `ARTIFACTORY_SBOM_REPO` | CI variable | Xray-indexed generic repo for SBOM upload via `scripts/sbom-post.sh` |
| `JF_BINARY_URL` | CI variable | Direct URL to `jf` binary for air-gapped auto-install |
| `JF_INSTALLER_URL` | CI variable | URL to JFrog CLI installer script (default: `https://install.jfrog.io`) |
| `AUTHORS` | CI variable | `org.opencontainers.image.authors` label (default: `Platform Engineering`) |
| `PROD_PUSH_REGISTRY` | CI variable | Production registry hostname |
| `PROD_PUSH_PROJECT` | CI variable | Prod project/path (defaults to `PUSH_PROJECT`) |
| `PROD_PUSH_REGISTRY_USER` | CI variable | Prod registry username |
| `PROD_PUSH_REGISTRY_PASSWORD` | CI variable (masked) | Prod registry password |

## Repository Structure

```
container-images/
├── Dockerfile                   # Shared template (labels + remediation + certs)
├── certs/                       # CA certs injected at build time (gitignored)
├── global.env.example           # Versioned template — cp to global.env and edit
├── global.env                   # Local overrides (gitignored)
├── local/                       # Gitignored workspace for test runners, creds, cheat sheets
├── .ci/
│   ├── promote.yml              # Reusable GitLab CI template (delegates to scripts/build.sh)
│   ├── image-ci.yml.template    # Per-image ci.yml generator template
│   ├── check-updates.yml        # Upstream tag drift scanner (GitLab)
│   └── validate-ci.yml          # Lint / sanity stages
├── bamboo-specs/
│   └── bamboo.yaml              # Bamboo plan spec — 1:1 parity with .ci/promote.yml
├── scripts/
│   ├── build.sh                 # Agnostic local build + push script (single source of truth)
│   ├── add-image.sh             # Scaffold images/<name>/ + ci.yml
│   ├── check-updates.sh         # Upstream tag drift scanner
│   ├── sbom-post.sh             # Ship CycloneDX SBOM to webhook / Dependency-Track / Artifactory Xray
│   ├── remediate/               # Distro-aware remediation defaults (alpine/debian/ubuntu/ubi)
│   ├── lib/
│   │   └── build-info-merge.py  # Shared: merges module linkage into Artifactory build info (Free tier)
│   └── push-backends/
│       └── artifactory.sh       # Pluggable push backend for REGISTRY_KIND=artifactory
├── images/
│   └── <name>/
│       ├── image.env.example    # Versioned template — cp to image.env
│       ├── image.env            # Local overrides (gitignored)
│       ├── ci.yml               # GitLab CI jobs — boilerplate, no version strings
│       ├── remediate.sh         # (optional) CVE remediation override
│       └── Dockerfile           # (optional) Custom override — only if shared won't do
├── .gitlab-ci.yml               # Root GitLab pipeline (includes per-image ci.yml)
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

**`PULL_REGISTRY`** — Docker image proxy host (single-host / path-routed model).
See "Multi-Upstream Mirrors" below if your registry serves each upstream from a
different subdomain instead of a different path.

**`APK_MIRROR`** — Alpine package mirror base URL. Replaces
`dl-cdn.alpinelinux.org/alpine` in `/etc/apk/repositories` so `apk` fetches
packages through your proxy. Version paths (`v3.21/main`, `v3.21/community`)
are preserved automatically.

```bash
# global.env — example for Nexus
APK_MIRROR="${APK_MIRROR:-https://nexus.example.com/repository/alpine-proxy}"
```

#### Multi-Upstream Mirrors

Not every image comes from Docker Hub. GHCR, Quay, and registry.k8s.io are
common second-hop upstreams for things like `trivy`, `cosign`, and
`kube-state-metrics`. There are two ways to route them:

**Path-routed proxy (Harbor, Nexus, JCR Free/Pro path mode)** — one hostname
fronts every upstream via different path prefixes:

```bash
# images/<name>/image.env
UPSTREAM_REGISTRY="${PULL_REGISTRY}/docker-hub/library"
UPSTREAM_REGISTRY="${PULL_REGISTRY}/ghcr-proxy/owner"
UPSTREAM_REGISTRY="${PULL_REGISTRY}/quay-proxy/aquasec"
```

**Subdomain-routed proxy (Artifactory Pro subdomain mode, or an nginx sidecar
with a `map $host $docker_repo` block)** — each upstream gets its own
hostname. `global.env` exposes one var per upstream:

```bash
# global.env
DOCKERHUB_MIRROR="${DOCKERHUB_MIRROR:-dockerhub.artifactory.example.com}"
GHCR_MIRROR="${GHCR_MIRROR:-ghcr.artifactory.example.com}"
QUAY_MIRROR="${QUAY_MIRROR:-quay.artifactory.example.com}"
```

```bash
# images/<name>/image.env — pick the right mirror per upstream
UPSTREAM_REGISTRY="${DOCKERHUB_MIRROR}/library"
UPSTREAM_REGISTRY="${GHCR_MIRROR}/owner"
UPSTREAM_REGISTRY="${QUAY_MIRROR}/aquasec"
```

The named vars default to `${PULL_REGISTRY}/docker-hub`, `${PULL_REGISTRY}/ghcr-proxy`,
and `${PULL_REGISTRY}/quay-proxy` respectively, so a path-routed setup still
works if your `image.env` files reference the named vars — you get the
subdomain-style indirection without having to run real subdomains.

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

### Registry backends (optional enrichment)

`build.sh --push` defaults to a plain `docker push` against
`${PUSH_REGISTRY}/${PUSH_PROJECT}/<image>:<tag>` — the Harbor baseline,
no bells and whistles. If your target registry supports extra metadata
(structured properties, build info, multi-tenant routing), you can
opt in by setting `REGISTRY_KIND`:

```bash
REGISTRY_KIND="${REGISTRY_KIND:-}"
# Supported: artifactory
```

When set, `build.sh` delegates the push step to
`scripts/push-backends/${REGISTRY_KIND}.sh` which exposes a
`push_to_backend()` function. Adding a new backend is dropping a new
file into that directory — no changes to `build.sh` itself.

#### artifactory

Routes the image through JFrog Artifactory / JCR, captures build info
(git SHA, branch, env vars via `jf rt bp --collect-env --collect-git-info`),
and tags the manifest with structured properties for downstream queries.

Required env at push time (hard fail if missing):

| Var | Purpose |
|---|---|
| `ARTIFACTORY_URL` | e.g. `https://artifactory.example.com` |
| `ARTIFACTORY_USER` | username with push rights to the target repo |
| `ARTIFACTORY_TOKEN` **or** `ARTIFACTORY_PASSWORD` | access token (preferred) or basic-auth password |
| `ARTIFACTORY_TEAM` | routing prefix — your team acronym (commonly a 4-letter code the platform team assigns). **Never committed to the repo**; every pipeline exports its own at runtime, so the same repo can push to different team repos depending on who's running it. |

Optional:

| Var | Default | Purpose |
|---|---|---|
| `ARTIFACTORY_PUSH_HOST` | host portion of `ARTIFACTORY_URL` | Docker push hostname. Override for subdomain layouts (e.g. `docker.artifactory.example.com`). |
| `ARTIFACTORY_IMAGE_REF` | Layout A fallback | Shell-template for the docker push URL. See "Switching layouts" below. |
| `ARTIFACTORY_MANIFEST_PATH` | Layout A fallback | Shell-template for the REST storage path used by `jf rt set-props`. |
| `ARTIFACTORY_ENVIRONMENT` | `dev` | Exposed to templates as `${ARTIFACTORY_ENVIRONMENT}`; derived `${ARTIFACTORY_REPO_SUFFIX}` maps `dev`→`local`, `prod`→`prod`. Layouts that don't split dev/prod simply don't reference either var. |
| `ARTIFACTORY_BUILD_NAME` | `${IMAGE_NAME}` | Build name in Artifactory UI |
| `ARTIFACTORY_BUILD_NUMBER` | `$CI_JOB_ID` / `$CI_PIPELINE_ID` / `$BUILD_NUMBER` / timestamp | Build number |
| `ARTIFACTORY_PROPERTIES` | (none) | Extra `;`-separated props, e.g. `security.scan=pending;hardened=false` |

##### Switching layouts

The backend has zero hardcoded repo paths. Both the docker push URL and
the REST storage path are resolved from shell-parameter-expansion
templates you supply via `ARTIFACTORY_IMAGE_REF` and
`ARTIFACTORY_MANIFEST_PATH`. Template variables available inside them:
`${ARTIFACTORY_PUSH_HOST}`, `${ARTIFACTORY_TEAM}`,
`${ARTIFACTORY_ENVIRONMENT}`, `${ARTIFACTORY_REPO_SUFFIX}`,
`${IMAGE_NAME}`, `${IMAGE_TAG}`.

`global.env.example` ships with **five named presets** — copy it to
`global.env` (gitignored) and uncomment the block for whichever layout
matches your Artifactory setup. Leaving all five commented falls back
to Layout A so existing configs keep working.

| Preset | Docker push URL | Storage path |
|---|---|---|
| **A** Per-team repos *(default fallback)* | `host/<team>/<image>:<tag>` | `<team>-docker-<suffix>/<image>/<tag>/manifest.json` |
| **B** Shared repo with team subfolder | `host/docker/<team>/<image>:<tag>` | `docker/<team>/<image>/<tag>/manifest.json` |
| **C** Subdomain-routed shared repo *(JFrog recommended)* | `docker.host/<team>/<image>:<tag>` | `docker/<team>/<image>/<tag>/manifest.json` |
| **D** Subdomain-per-team | `<team>.host/<image>:<tag>` | `<team>-docker-<suffix>/<image>/<tag>/manifest.json` |
| **E** Team-dispatch subdomain | `docker.host/<team>/<image>:<tag>` | `<team>-docker-<suffix>/<image>/<tag>/manifest.json` *(team segment stripped by sidecar before storage — requires an external nginx `map` that rewrites host+path→repo)* |

##### Nginx reverse proxy for Docker V2 routing

**Artifactory Pro/Enterprise** handles Docker V2 subdomain routing
natively — configure it in Admin → HTTP Settings → Docker Access Method →
Sub Domain, set the server name, and your existing load balancer just
does a dumb `proxy_pass` to Artifactory. No rewrites needed.

**JCR Free** does NOT serve `/v2/` at the root. Docker clients always
hit `/v2/` first and get a 404. You need an nginx reverse proxy (or
sidecar) that rewrites Docker V2 paths to Artifactory's internal API
format: `/v2/*` → `/artifactory/api/docker/<repo>/v2/*`.

The config below works with any standard nginx (not NPM-specific). It
supports all five layouts via a `map` block that resolves the hostname
to the correct Artifactory repo name. Paste it into your nginx
`server {}` block or use it as a standalone sidecar container.

```nginx
upstream artifactory {
    server artifactory-host:8082;
}

# ── Subdomain → repo mapping ────────────────────────────────────────
# One entry per subdomain. Add/remove as needed for your layout.
map $host $docker_repo {
    # Layout C/E: shared push registry (folder RBAC inside docker-local)
    docker.artifactory.example.com        docker-local;

    # Pull-through Docker Hub cache
    dockerhub.artifactory.example.com     docker-hub-proxy;

    # Environment-split virtual repos (aggregates locals + remote)
    docker-dev.artifactory.example.com    docker-dev-virtual;
    docker-prod.artifactory.example.com   docker-prod-virtual;

    # Layout D: per-team subdomain → per-team repo
    teamA.artifactory.example.com         teamA-docker-local;
    teamB.artifactory.example.com         teamB-docker-local;

    # Fallback for unknown hosts
    default                                docker-local;
}

server {
    listen 443 ssl;
    server_name *.artifactory.example.com;

    ssl_certificate     /path/to/wildcard-artifactory.crt;
    ssl_certificate_key /path/to/wildcard-artifactory.key;

    client_max_body_size 0;
    chunked_transfer_encoding on;

    # ── Docker V2 ping ──────────────────────────────────────────────
    location = /v2/ {
        proxy_pass http://artifactory/artifactory/api/docker/$docker_repo/v2/;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto https;
    }

    # ── Location-header redirects ───────────────────────────────────
    # Artifactory returns Location: /v2/<repo-name>/image/blobs/uploads/...
    # in 202 responses. This block catches those redirected requests so the
    # repo name in the path is used directly (not double-prefixed).
    location ~ ^/v2/(teamA-docker-local|teamB-docker-local|docker-local|docker-hub-proxy|docker-dev-virtual|docker-prod-virtual)/(.*)$ {
        rewrite ^/v2/([^/]+)/(.*)$ /artifactory/api/docker/$1/v2/$2 break;
        proxy_pass http://artifactory;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 900;
        proxy_send_timeout 900;
        proxy_buffering off;
        proxy_request_buffering off;
    }

    # ── Default: all other /v2/ requests ────────────────────────────
    # Uses $docker_repo from the host map. The full Docker path
    # (team/image/tag) is preserved as-is inside the target repo.
    location /v2/ {
        rewrite ^/v2/(.*)$ /artifactory/api/docker/$docker_repo/v2/$1 break;
        proxy_pass http://artifactory;
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_read_timeout 900;
        proxy_send_timeout 900;
        proxy_buffering off;
        proxy_request_buffering off;
    }
}
```

**Key details:**

- `X-Forwarded-Proto https` — ensures Artifactory's `Location` response
  headers return `https://` URLs. Without this, Docker follows an HTTP
  redirect and gets a TLS error.
- The redirect handler (`location ~ ^/v2/(repo-name)/`) is critical.
  Artifactory's 202 blob upload response includes the repo name in the
  redirect URL. Without this block, the next Docker request would hit the
  default location and double-prefix the repo name.
- `client_max_body_size 0` — no upload limit (Docker layers can be large).
- The `map` block is the only part that changes between layouts. The
  location blocks are layout-agnostic.
- Add repo names to the redirect regex whenever you create new repos.

**When you DON'T need this:** Artifactory Pro with "Sub Domain" Docker
Access Method configured. The built-in router handles `/v2/` → repo
resolution internally based on the Host header. Your LB just needs a
plain `proxy_pass` with `proxy_set_header Host $http_host`.

Templates must be **single-quoted** in `global.env` so `${VAR}` stays
literal until `build.sh` expands it. Shell exports override file
values, so you can test a different layout per-invocation without
editing the file:

```bash
export ARTIFACTORY_PUSH_HOST=docker.artifactory.example.com
export ARTIFACTORY_IMAGE_REF='${ARTIFACTORY_PUSH_HOST}/${ARTIFACTORY_TEAM}/${IMAGE_NAME}:${IMAGE_TAG}'
export ARTIFACTORY_MANIFEST_PATH='${ARTIFACTORY_TEAM}-docker-local/${IMAGE_NAME}/${IMAGE_TAG}/manifest.json'
./scripts/build.sh prometheus --push
```

Whichever layout you pick, RBAC at the backing Artifactory repo still
applies — the template resolves the URL, but Artifactory decides
whether the push succeeds.

Example (local shell, assuming your team acronym is `abcd`):

```bash
export REGISTRY_KIND=artifactory
export ARTIFACTORY_URL=https://artifactory.example.com
export ARTIFACTORY_USER=abcd                      # your team/service user
export ARTIFACTORY_TOKEN="…"                      # access token (preferred)
export ARTIFACTORY_TEAM=abcd
export ARTIFACTORY_PROPERTIES="security.scan=pending;approval.status=draft"
./scripts/build.sh nginx --push
```

With no `ARTIFACTORY_IMAGE_REF` / `ARTIFACTORY_MANIFEST_PATH` set, this
falls through to Layout A: pulls the base, builds, tags as
`artifactory.example.com/abcd/nginx:1.27.5-alpine-<sha>`, pushes it to
the `abcd-docker-local` backing repo, publishes build info, and tags
the manifest with `team`, `environment`, `build.name`, `build.number`,
`git.commit`, plus the props above. Other layouts push to the URL/repo
their templates resolve to — see "Switching layouts" above.

**Pro vs Free (JCR).** The backend supports both tiers with a single
codebase. Set `ARTIFACTORY_PRO=true` to unlock Pro features:

| Feature | Free (default) | Pro (`ARTIFACTORY_PRO=true`) |
|---|---|---|
| Docker push | `docker push` | `jf docker push` (automatic module linkage) |
| Build info | Manual JSON assembly with module linkage via storage API | `jf rt bp` with `--project` (project-scoped) |
| Env vars | Captured via `jf rt bp --collect-env` + include-first filter | Same |
| Git context | Captured via `jf rt bp --collect-git-info` | Same |
| Layer props | `jf rt set-props` on all files | Automatic via `jf docker push` |
| Xray scan | Not available | `jf build-scan` |

Both paths produce the same metadata in the Artifactory UI: modules,
artifacts, dependencies, env vars, VCS info, and layer-level properties.
The `jf` CLI auto-installs if not on PATH (set `JF_BINARY_URL` or
`JF_INSTALLER_URL` for air-gapped environments).

## image.env Reference

Variable names match the container-image-template repo exactly:

```bash
# ── Required: upstream source ────────────────────────────────────────
IMAGE_NAME="prometheus"                                   # Repo name in target registry
UPSTREAM_REGISTRY="${DOCKERHUB_MIRROR}/prom"              # Registry + path prefix
UPSTREAM_IMAGE="prometheus"                               # Image name under the registry
# renovate: datasource=docker depName=prom/prometheus
UPSTREAM_TAG="v3.11.0"                                    # Upstream tag to pin
DISTRO="busybox"                                          # Base distro (alpine|debian|ubuntu|ubi|busybox)

# ── Optional: image enrichment ────────────────────────────────────────
REMEDIATE="false"             # true = run scripts/remediate/${DISTRO}.sh for CVE patches
INJECT_CERTS="false"          # true = inject CA certs into trust store
ORIGINAL_USER="nobody"        # Upstream USER (check: docker inspect <img> --format='{{.Config.User}}')
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
| `org.opencontainers.image.authors` | build | Team / contact (default: `Platform Engineering`) |
| `org.opencontainers.image.created` | build | Promotion build timestamp (ISO 8601) |
| `org.opencontainers.image.revision` | build | Git commit SHA of the promotion repo |
| `org.opencontainers.image.version` | build | Promoted tag (`<tag>-<commit>`) |
| `org.opencontainers.image.ref.name` | build | Same as version |
| `org.opencontainers.image.base.name` | build | Upstream registry/image:tag that was pulled |
| `org.opencontainers.image.base.digest` | build | Upstream manifest digest (if crane available) |
| `org.opencontainers.image.source` | build | Git remote URL |
| `org.opencontainers.image.url` | build | Same as source |
| `promoted.from` | build | Same as base.name — the pull origin |
| `promoted.tag` | build | Same as version — the promoted tag |
| *(upstream labels)* | inherited | title, description, licenses, maintainer, etc. |
| *(custom labels)* | labels.env | Optional per-image metadata |
