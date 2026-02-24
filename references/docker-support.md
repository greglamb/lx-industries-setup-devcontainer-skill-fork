# Docker Support (Optional)

Docker CLI + Compose support is an optional cross-cutting feature. When enabled, it
installs the Docker CLI tools inside the devcontainer and bind-mounts the host's Docker
socket so the container can build images, run compose stacks, and execute Testcontainers.

No Docker daemon runs inside the container — the host daemon handles all execution via
the socket mount.

## Detection signals

Scan the project during Phase 1 analysis to determine if Docker support is needed.

**Strong signals** (recommend enabling):
- `docker-compose.yml` / `docker-compose.yaml` / `compose.yml` / `compose.yaml`
- `Dockerfile` or `Containerfile` outside `.devcontainer/`
- Testcontainers dependency:
  - Java: `org.testcontainers`
  - Python: `testcontainers`
  - Node: `testcontainers`
  - Go: `testcontainers-go`
  - Rust: `testcontainers`
- References to `docker build`, `docker compose`, `podman build` in task runner scripts
  (Makefile, justfile, Taskfile.yml, package.json scripts)

**Weak signals** (mention but don't auto-recommend):
- `.dockerignore` in project root
- Container registry references in CI config
- `DOCKER_HOST` in env files

Present findings to the user. If no signals found, still offer the option.

## Dockerfile: Docker CLI layer

Install `docker-ce-cli`, `docker-compose-plugin`, and `docker-buildx-plugin` from
Docker's official APT repository. No daemon (`docker-ce`) is installed.

```dockerfile
# ── Docker CLI + Compose plugin ──────────────────────────────────────
RUN <<'INSTALL_DOCKER'
  set -eux
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) \
    signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list
  apt-get update
  apt-get install -y --no-install-recommends \
    docker-ce-cli docker-compose-plugin docker-buildx-plugin
  rm -rf /var/lib/apt/lists/*
INSTALL_DOCKER
```

Key points:
- `docker-ce-cli` only — no daemon. Host daemon runs via socket mount.
- `docker-compose-plugin` — compose v2 as `docker compose` subcommand.
- `docker-buildx-plugin` — modern build engine for multi-platform builds.
- Installs latest available versions from Docker's APT repo. No Renovate annotation — APT packages in a third-party repo lack a suitable Renovate datasource. The repo is updated on `docker build` via `apt-get update`.
- Packages already installed by earlier layers (ca-certificates, curl, gnupg) are no-ops in APT.

Place this layer after the system packages layer and before forge CLI installations.

## Dockerfile: `/etc/group` writable

The entrypoint needs to inject the Docker socket's GID as a group entry. Add alongside
the existing `chmod 0666 /etc/passwd`:

```dockerfile
RUN chmod 0666 /etc/passwd /etc/group
```

## Entrypoint: Docker socket GID handling

Add after UID/GID resolution and passwd injection, before the firewall block. Only runs
when the socket is mounted and the entrypoint is running as root (IDE paths):

```bash
# -- Docker socket access (match host GID) ------------------------------------
if [[ -S /var/run/docker.sock ]] && [[ "$(id -u)" = "0" ]]; then
    docker_gid="$(stat -c '%g' /var/run/docker.sock)"
    if ! getent group "$docker_gid" >/dev/null 2>&1; then
        echo "docker:x:${docker_gid}:" >> /etc/group
    fi
    group_name="$(getent group "$docker_gid" | cut -d: -f1)"
    usermod -aG "$group_name" "$(getent passwd "$target_uid" | cut -d: -f1)" 2>/dev/null || true
fi
```

For the CLI `--user` path, `--group-add` in the task runner recipe handles Docker
access without needing the entrypoint.

## devcontainer.json: socket mount

Add to the `mounts` array:

```json
"source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"
```

No `runArgs` needed — the entrypoint handles GID.

## Task runner: socket mount + group-add

Add to the conditional mounts block:

```bash
# Docker socket (conditional — may not exist)
if [[ -S /var/run/docker.sock ]]; then
    run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    run_args+=(--group-add "$(stat -c '%g' /var/run/docker.sock)")
fi
```

## Firewall allowlist additions

When Docker support + firewall are both enabled, add Docker Hub registry domains:

```
# Docker Hub registry
registry-1.docker.io
auth.docker.io
production.cloudflare.docker.com
```

Scan `FROM` directives in Dockerfiles and `image:` fields in compose files to detect
additional registries:

| Registry | Domains |
|----------|---------|
| Docker Hub | `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` |
| GHCR | `ghcr.io` |
| GitLab | `registry.gitlab.com` |
| GCR | `gcr.io` |
| GAR | `*-docker.pkg.dev` (ask for specific region) |
| ECR | `*.dkr.ecr.*.amazonaws.com` (ask for specific region) |

## Verification checklist

When Docker support is enabled, add to Phase 7:

- `docker version` — CLI installed, daemon reachable via socket
- `docker compose version` — compose plugin installed
- `docker buildx version` — buildx plugin installed
- `docker info` — full daemon connectivity
- `docker run --rm hello-world` — end-to-end pull + run + cleanup
- `docker build -t test-build - <<< 'FROM alpine' && docker rmi test-build` — can build images (cleans up after)
- If firewall enabled: `docker pull alpine` succeeds (Docker Hub allowlisted)
