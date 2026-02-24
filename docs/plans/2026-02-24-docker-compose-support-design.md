# Docker-in-Docker / Docker Compose Support

**Date:** 2026-02-24
**Status:** Approved

## Summary

Add optional Docker CLI + Docker Compose support to the devcontainer skill.
Uses host Docker socket bind-mount — no daemon inside the container.
Detection during Phase 1 project analysis, layered into existing phases as a
cross-cutting concern.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Docker access strategy | Host socket bind-mount | Simplest, fastest, shares host image cache, Testcontainers-compatible |
| Installation method | docker-ce-cli + docker-compose-plugin + docker-buildx-plugin from Docker APT repo | Pinned, Renovate-tracked, auditable. No daemon installed. |
| Networking | Standard compose networking via host daemon | Services get their own compose network. Devcontainer accesses via mapped ports. No special config. |
| Phase integration | Cross-cutting across existing phases | No new phase. Docker support layers into Phases 1, 2, 3, 5, 6, 7 conditionally. |
| GID handling (IDE) | Entrypoint detects socket GID, injects group, adds user | Works for all IDE paths (VS Code, Zed, JetBrains). Needs `/etc/group` writable. |
| GID handling (CLI) | `--group-add` in task runner recipe | Cleaner than entrypoint manipulation. `stat -c '%g'` on host socket. |

## Detection (Phase 1 Enhancement)

During project analysis, scan for Docker signals.

**Strong signals** (recommend enabling Docker support):
- `docker-compose.yml` / `docker-compose.yaml` / `compose.yml` / `compose.yaml`
- `Dockerfile` or `Containerfile` outside `.devcontainer/`
- Testcontainers dependency:
  - Java: `org.testcontainers`
  - Python: `testcontainers`
  - Node: `testcontainers`
  - Go: `testcontainers-go`
  - Rust: `testcontainers`
- References to `docker build`, `docker compose`, `podman build` in task runner
  scripts (Makefile, justfile, Taskfile.yml, package.json scripts)

**Weak signals** (mention but don't auto-recommend):
- `.dockerignore` in project root
- Container registry references in CI config
- `DOCKER_HOST` in env files

Present findings to user. If no signals found, still offer the option.

## Dockerfile Additions (Phase 2)

### Docker CLI layer

```dockerfile
# ── Docker CLI + Compose plugin ──────────────────────────────────────
# renovate: datasource=docker depName=docker versioning=docker
ARG DOCKER_VERSION=28.1.1
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
- `docker-ce-cli` only — no daemon
- `docker-compose-plugin` — compose v2 as `docker compose`
- `docker-buildx-plugin` — modern build engine
- Renovate `ARG` pattern tracks version for cache busting
- Already-installed packages (ca-certificates, curl, gnupg) are no-ops in APT

### /etc/group writable

```dockerfile
RUN chmod 0666 /etc/group
```

Added alongside the existing `chmod 0666 /etc/passwd`. Enables entrypoint to
inject Docker group with matching host GID.

### Entrypoint Docker socket GID block

Added after UID resolution, before firewall:

```bash
# Docker socket access — match host GID
if [[ -S /var/run/docker.sock ]] && [[ "$(id -u)" = "0" ]]; then
    docker_gid="$(stat -c '%g' /var/run/docker.sock)"
    if ! getent group "$docker_gid" >/dev/null 2>&1; then
        echo "docker:x:${docker_gid}:" >> /etc/group
    fi
    group_name="$(getent group "$docker_gid" | cut -d: -f1)"
    usermod -aG "$group_name" "$(getent passwd "$target_uid" | cut -d: -f1)" 2>/dev/null || true
fi
```

Only runs when:
- Docker socket is mounted (detected via `-S`)
- Running as root (IDE paths that start as root before gosu drop)

For the CLI `--user` path, `--group-add` handles it (no entrypoint needed).

## devcontainer.json Additions (Phase 3)

Add socket bind-mount:

```jsonc
{
  "mounts": [
    "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind"
  ]
}
```

No `runArgs` needed — entrypoint handles GID.

## Firewall Allowlist Additions (Phase 5)

When Docker + firewall are both enabled:

```
# Docker Hub registry
registry-1.docker.io
auth.docker.io
production.cloudflare.docker.com
```

Scan `FROM` directives in Dockerfiles and `image:` fields in compose files to
detect additional registries:

| Registry | Domains |
|----------|---------|
| Docker Hub | `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` |
| GHCR | `ghcr.io` |
| GitLab | `registry.gitlab.com` |
| GCR | `gcr.io` |
| GAR | `*-docker.pkg.dev` (ask for specific region) |
| ECR | `*.dkr.ecr.*.amazonaws.com` (ask for specific region) |

## Task Runner Additions (Phase 6)

Conditional socket mount + group-add:

```bash
# Docker socket (conditional — may not exist)
if [[ -S /var/run/docker.sock ]]; then
    run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
    run_args+=(--group-add "$(stat -c '%g' /var/run/docker.sock)")
fi
```

Added to the existing conditional mount block.

## Verification Additions (Phase 7)

When Docker support is enabled, verify:

- `docker version` — CLI installed, daemon reachable
- `docker compose version` — compose plugin installed
- `docker buildx version` — buildx plugin installed
- `docker info` — full daemon connectivity
- `docker run --rm hello-world` — end-to-end pull + run
- `docker build -t test-build - <<< 'FROM alpine'` — can build images
- If firewall: `docker pull alpine` succeeds (Docker Hub allowlisted)

## Reference Documentation Updates

### Existing files to update

- `references/dockerfile.md` — Docker CLI installation pattern
- `references/devcontainer-json.md` — socket mount pattern
- `references/firewall.md` — Docker Hub registry domains
- `references/task-runner.md` — socket mount + group-add pattern
- `references/common-mistakes.md` — Docker anti-patterns:
  - Installing `dockerd` inside devcontainer
  - Hardcoding docker GID
  - Forgetting `/etc/group` writable
  - Socket mount without GID handling
  - Missing Docker Hub domains in firewall allowlist
  - Using standalone `docker-compose` v1

### New file

- `references/docker-support.md` — detection signals, Docker CLI layer,
  socket GID handling, all Docker patterns in one reference

### SKILL.md updates

- Phase 1: add Docker detection to project analysis checklist
- Phase 2: add Docker CLI layer (conditional)
- Phase 3: add socket mount (conditional)
- Phase 5: add Docker registry domains (conditional)
- Phase 6: add socket mount to recipe (conditional)
- Phase 7: add Docker verification steps (conditional)

## Anti-Patterns

| Mistake | Fix |
|---------|-----|
| Install `dockerd` inside devcontainer | Use socket mount — host daemon handles execution |
| Hardcode docker GID (e.g., 999) | Detect at runtime via `stat -c '%g'` |
| `/etc/group` not writable | `chmod 0666 /etc/group` in Dockerfile |
| Socket mount without GID handling | Entrypoint (IDE) or `--group-add` (CLI) |
| Missing Docker Hub domains in firewall | Add `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` |
| Standalone `docker-compose` v1 | Use `docker-compose-plugin` (v2, `docker compose` subcommand) |
| Mounting socket unconditionally in task runner | Check `-S /var/run/docker.sock` first |
| Not scanning compose/Dockerfiles for registries | Firewall will block unlisted registries silently |
