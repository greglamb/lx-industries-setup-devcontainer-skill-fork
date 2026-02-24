# Docker CLI + Compose Support Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add optional Docker CLI + Docker Compose support to the devcontainer skill via host socket bind-mount.

**Architecture:** Cross-cutting feature layered into existing phases. Detection in Phase 1, Docker CLI APT layer in Phase 2, socket mount in Phase 3/6, registry domains in Phase 5, verification in Phase 7. Entrypoint handles Docker socket GID for IDE users; task runner uses `--group-add` for CLI users.

**Tech Stack:** Docker APT repo (docker-ce-cli, docker-compose-plugin, docker-buildx-plugin), iptables/ipset (firewall), gosu (privilege drop), bash (entrypoint).

---

### Task 1: Create `references/docker-support.md`

**Files:**
- Create: `references/docker-support.md`

**Step 1: Write the reference file**

```markdown
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
- `docker-ce-cli` only — no daemon. Host daemon runs via socket mount.
- `docker-compose-plugin` — compose v2 as `docker compose` subcommand.
- `docker-buildx-plugin` — modern build engine for multi-platform builds.
- Renovate `ARG` pattern tracks version for cache busting.
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
- `docker build -t test-build - <<< 'FROM alpine'` — can build images
- If firewall enabled: `docker pull alpine` succeeds (Docker Hub allowlisted)
```

**Step 2: Verify the file exists and is well-formed**

Run: `wc -l references/docker-support.md`
Expected: ~140 lines

**Step 3: Commit**

```bash
git add references/docker-support.md
git commit -m "docs(references): add docker-support.md for Docker CLI + Compose patterns"
```

---

### Task 2: Update `references/dockerfile.md` — Docker CLI pattern

**Files:**
- Modify: `references/dockerfile.md` (add after "Layer ordering" section, before "Claude Code" section)

**Step 1: Add Docker CLI section**

After the "Layer ordering" section (line 50), add:

```markdown
## Docker CLI + Compose (optional)

When the project needs Docker access inside the devcontainer (detected in Phase 1), install the Docker CLI tools from Docker's official APT repo. See [docker-support.md](docker-support.md) for the full Dockerfile layer, detection signals, and entrypoint GID handling.

Key points:
- Install `docker-ce-cli`, `docker-compose-plugin`, and `docker-buildx-plugin` — never `docker-ce` (no daemon)
- Use Renovate `ARG` pattern for version tracking
- Place the layer after system packages and before forge CLI installs
- Add `chmod 0666 /etc/group` alongside `/etc/passwd` for Docker GID injection
```

**Step 2: Verify the edit**

Run: `grep -c "Docker CLI" references/dockerfile.md`
Expected: at least 1 match

**Step 3: Commit**

```bash
git add references/dockerfile.md
git commit -m "docs(references): add Docker CLI pattern to dockerfile.md"
```

---

### Task 3: Update `references/devcontainer-json.md` — socket mount

**Files:**
- Modify: `references/devcontainer-json.md` (add to "Key decisions" section)

**Step 1: Add Docker socket mount decision**

At the end of the "Key decisions (both paths)" section (after the `DEVCONTAINER_WORKSPACE` bullet, line 82), add:

```markdown
- **Docker socket mount** (optional): When Docker support is enabled, bind-mount `/var/run/docker.sock` into the container. The entrypoint detects the socket's GID and adds the target user to the matching group. No `runArgs` needed — GID handling is automatic. See [docker-support.md](docker-support.md) for details.
```

**Step 2: Verify the edit**

Run: `grep -c "docker.sock" references/devcontainer-json.md`
Expected: 1

**Step 3: Commit**

```bash
git add references/devcontainer-json.md
git commit -m "docs(references): add Docker socket mount to devcontainer-json.md"
```

---

### Task 4: Update `references/firewall.md` — Docker registry domains

**Files:**
- Modify: `references/firewall.md` (add to the allowlist template in section 5.1)

**Step 1: Add Docker Hub domains to registry table**

In the "Populate package registries" table (after the `rubygems` row, line 41), add a new row:

```markdown
| docker (Docker Hub) | `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` |
```

**Step 2: Add note about Docker registry scanning**

After the registry table, add:

```markdown
When Docker support is enabled, also scan `FROM` directives in project Dockerfiles and `image:` fields in compose files to detect additional registries (GHCR, GitLab, GCR, GAR, ECR). See [docker-support.md](docker-support.md) for the full registry detection table.
```

**Step 3: Verify**

Run: `grep -c "registry-1.docker.io" references/firewall.md`
Expected: 1

**Step 4: Commit**

```bash
git add references/firewall.md
git commit -m "docs(references): add Docker Hub registry domains to firewall.md"
```

---

### Task 5: Update `references/task-runner.md` — socket mount + group-add

**Files:**
- Modify: `references/task-runner.md`

**Step 1: Add Docker socket block to the recipe template**

In the "Example recipe structure" section, after the conditional host config mounts block (line 65, after the `~/.claude.json` conditional), add:

```bash
    # Docker socket (conditional — may not exist)
    if [[ -S /var/run/docker.sock ]]; then
        run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
        run_args+=(--group-add "$(stat -c '%g' /var/run/docker.sock)")
    fi
```

**Step 2: Add key design point**

In the "Key design points" section, add a new bullet:

```markdown
- **Docker socket mount** — conditional on socket existence (`-S /var/run/docker.sock`). Uses `--group-add` to add the host Docker GID as a supplementary group. Works with both `--user` (normal mode) and root+gosu (firewall mode). Only added when Docker support is enabled.
```

**Step 3: Verify**

Run: `grep -c "docker.sock" references/task-runner.md`
Expected: at least 2

**Step 4: Commit**

```bash
git add references/task-runner.md
git commit -m "docs(references): add Docker socket mount to task-runner.md recipe"
```

---

### Task 6: Update `references/common-mistakes.md` — Docker anti-patterns

**Files:**
- Modify: `references/common-mistakes.md`

**Step 1: Add Docker mistake rows to the table**

After the last row of the "Common Mistakes" table (line 37, `No DEVCONTAINER_WORKSPACE env var`), add:

```markdown
| Installing `dockerd` (daemon) inside devcontainer | Use socket mount — host daemon handles all execution via `/var/run/docker.sock` |
| Hardcoding Docker GID (e.g., 999 or 998) | Detect at runtime: `stat -c '%g' /var/run/docker.sock` in task runner, entrypoint for IDE paths |
| `/etc/group` not writable for Docker GID injection | `chmod 0666 /etc/group` alongside `/etc/passwd` in Dockerfile |
| Socket mount without GID handling | Use `--group-add` in task runner, or entrypoint GID injection for IDE paths |
| Missing Docker Hub domains in firewall allowlist | Add `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` when Docker is enabled |
| Using standalone `docker-compose` (v1) | Install `docker-compose-plugin` (v2) — runs as `docker compose` subcommand |
| Mounting Docker socket unconditionally in task runner | Check `-S /var/run/docker.sock` first — socket may not exist on all hosts |
| Not scanning compose/Dockerfiles for registries | Firewall silently blocks unlisted registries — scan `FROM` and `image:` for additional domains |
```

**Step 2: Add Docker red flags**

In the "Red Flags" / "Never" section, add:

```markdown
- Install `dockerd` or `containerd` inside a devcontainer — use the host daemon via socket mount
- Hardcode the Docker socket GID — it varies per host (999, 998, 133, etc.)
```

In the "Always" section, add:

```markdown
- Detect Docker signals during Phase 1 project analysis (compose files, Dockerfiles, Testcontainers deps)
- Use `--group-add` for CLI and entrypoint GID injection for IDE Docker socket access
```

**Step 3: Verify**

Run: `grep -c "dockerd" references/common-mistakes.md`
Expected: at least 2

**Step 4: Commit**

```bash
git add references/common-mistakes.md
git commit -m "docs(references): add Docker anti-patterns to common-mistakes.md"
```

---

### Task 7: Update `SKILL.md` — Phase 1 Docker detection

**Files:**
- Modify: `SKILL.md`

**Step 1: Add Docker detection to Phase 1**

In Phase 1 (after step 3 "Identify additional tools needed beyond CI", around line 47), add a new step:

```markdown
**4. Check for Docker/Compose usage:**

Look for signals that the project needs Docker access inside the devcontainer:
- Compose files: `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`
- Container build files: `Dockerfile` or `Containerfile` outside `.devcontainer/`
- Testcontainers dependencies in package manifests
- References to `docker build`, `docker compose`, `podman build` in task runner scripts

See [references/docker-support.md](references/docker-support.md) for the full detection signal list.

If signals found, recommend enabling Docker CLI + Compose support. If none found, still offer the option.
```

Renumber existing step 4 ("Present findings") to step 5.

**Step 2: Verify the edit**

Run: `grep -c "Docker" SKILL.md`
Expected: at least 3 new occurrences

**Step 3: Commit**

```bash
git add SKILL.md
git commit -m "docs: add Docker detection to SKILL.md Phase 1"
```

---

### Task 8: Update `SKILL.md` — Phase 2, 3, 5, 6, 7 conditional Docker additions

**Files:**
- Modify: `SKILL.md`

**Step 1: Add Docker note to Phase 2**

After the "Key principles" list in Phase 2 (line 63), add:

```markdown
If Docker support was enabled in Phase 1, also add the Docker CLI layer and `/etc/group` writable. See [references/docker-support.md](references/docker-support.md) for the Dockerfile additions and entrypoint GID handling.
```

**Step 2: Add Docker note to Phase 3**

After the "Key decisions" list in Phase 3 (line 74), add:

```markdown
If Docker support was enabled in Phase 1, add the Docker socket bind-mount (`/var/run/docker.sock`). The entrypoint handles GID — no `runArgs` needed.
```

**Step 3: Add Docker note to Phase 5**

After "Key principles" in Phase 5 (line 112), add:

```markdown
If Docker support was enabled in Phase 1, add Docker Hub registry domains (`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`) to the allowlist. Scan project Dockerfiles and compose files for additional registries. See [references/docker-support.md](references/docker-support.md).
```

**Step 4: Add Docker note to Phase 6**

After "Key principles" in Phase 6 (line 126), add:

```markdown
If Docker support was enabled in Phase 1, add a conditional Docker socket mount with `--group-add` to the recipe. See [references/docker-support.md](references/docker-support.md).
```

**Step 5: Add Docker verification to Phase 7**

After the main verification checklist (before "Firewall verification"), add:

```markdown
**Docker verification (Docker support only):**
- [ ] `docker version` — CLI installed, daemon reachable via socket
- [ ] `docker compose version` — compose plugin installed
- [ ] `docker buildx version` — buildx plugin installed
- [ ] `docker info` — full daemon connectivity
- [ ] `docker run --rm hello-world` — end-to-end pull + run + cleanup
- [ ] `docker build -t test-build - <<< 'FROM alpine'` — can build images
- [ ] If firewall enabled: `docker pull alpine` succeeds (Docker Hub allowlisted)
```

**Step 6: Add Docker reference to the Reference section**

In the "Reference" section at the bottom (line 165), add a new bullet:

```markdown
- **[references/docker-support.md](references/docker-support.md)** — Docker CLI + Compose: detection signals, Dockerfile layer, socket GID handling, firewall domains
```

**Step 7: Verify**

Run: `grep -c "docker-support.md" SKILL.md`
Expected: at least 4 (one per phase mention + reference section)

**Step 8: Commit**

```bash
git add SKILL.md
git commit -m "docs: add conditional Docker support to SKILL.md Phases 2-7"
```

---

### Task 9: Update `.devcontainer/Dockerfile` — Docker CLI layer + /etc/group

**Files:**
- Modify: `.devcontainer/Dockerfile:36-43` (after git-delta, before gosu)

**Step 1: Add Docker CLI layer**

After the git-delta layer (line 35) and before the gosu layer (line 37), insert:

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

**Step 2: Update chmod to include /etc/group**

Change line 93:

```dockerfile
RUN chmod 0666 /etc/passwd
```

to:

```dockerfile
RUN chmod 0666 /etc/passwd /etc/group
```

**Step 3: Verify syntax**

Run: `docker build --check .devcontainer/` (if available) or just verify file parses:
Run: `grep -c "docker-ce-cli" .devcontainer/Dockerfile`
Expected: 1

**Step 4: Commit**

```bash
git add .devcontainer/Dockerfile
git commit -m "feat: add Docker CLI + Compose plugin layer to Dockerfile"
```

---

### Task 10: Update `.devcontainer/entrypoint.sh` — Docker socket GID

**Files:**
- Modify: `.devcontainer/entrypoint.sh:25-26` (after passwd injection, before firewall)

**Step 1: Add Docker socket GID block**

After the passwd injection block (line 25) and before the firewall block (line 27), insert:

```bash
# -- Docker socket access (match host GID) ------------------------------------
# Only needed when running as root (IDE paths). CLI --user + --group-add handles it.
if [[ -S /var/run/docker.sock ]] && [[ "$(id -u)" = "0" ]]; then
    docker_gid="$(stat -c '%g' /var/run/docker.sock)"
    if ! getent group "$docker_gid" >/dev/null 2>&1; then
        echo "docker:x:${docker_gid}:" >> /etc/group
    fi
    group_name="$(getent group "$docker_gid" | cut -d: -f1)"
    usermod -aG "$group_name" "$(getent passwd "$target_uid" | cut -d: -f1)" 2>/dev/null || true
fi
```

**Step 2: Verify**

Run: `grep -c "docker.sock" .devcontainer/entrypoint.sh`
Expected: 1

**Step 3: Commit**

```bash
git add .devcontainer/entrypoint.sh
git commit -m "feat: add Docker socket GID handling to entrypoint"
```

---

### Task 11: Update `.devcontainer/devcontainer.json` — socket mount

**Files:**
- Modify: `.devcontainer/devcontainer.json:16` (add to mounts array)

**Step 1: Add Docker socket mount**

Add a new mount entry before the SSH_AUTH_SOCK mount (line 16):

```json
    "source=/var/run/docker.sock,target=/var/run/docker.sock,type=bind",
```

**Step 2: Verify valid JSON**

Run: `python3 -c "import json; json.load(open('.devcontainer/devcontainer.json'))"`
Expected: no error

**Step 3: Commit**

```bash
git add .devcontainer/devcontainer.json
git commit -m "feat: add Docker socket mount to devcontainer.json"
```

---

### Task 12: Update `justfile` — Docker socket mount + group-add

**Files:**
- Modify: `justfile:37` (after the conditional claude.json mount, before the final if/else)

**Step 1: Add Docker socket conditional mount**

After line 37 (`[[ -f "$HOME/.claude.json" ]] && ...`) and before line 38 (`if [[ $# -eq 0 ]]; then`), insert:

```bash
    # Docker socket (conditional — may not exist on all hosts)
    if [[ -S /var/run/docker.sock ]]; then
        run_args+=(-v /var/run/docker.sock:/var/run/docker.sock)
        run_args+=(--group-add "$(stat -c '%g' /var/run/docker.sock)")
    fi
```

**Step 2: Verify**

Run: `grep -c "docker.sock" justfile`
Expected: 2 (mount + group-add within the same block)

**Step 3: Commit**

```bash
git add justfile
git commit -m "feat: add conditional Docker socket mount to justfile recipe"
```

---

### Task 13: Update `.gitlab-ci.yml` — smoke test Docker CLI

**Files:**
- Modify: `.gitlab-ci.yml:36-38` (add docker, docker-compose to smoke test command list)

**Step 1: Add docker commands to smoke test**

In the `devcontainer:smoke-test` job, add `docker` to the command list (after `gosu`, before `iptables`):

The `for cmd` line should become:

```yaml
        for cmd in \
          curl git ssh jq less fzf ps unzip gpg python3 delta \
          glab claude gosu \
          docker \
          iptables ipset ip dig \
        ; do
```

Note: `docker compose` and `docker buildx` are subcommands/plugins, not standalone binaries. The smoke test just checks that `docker` is on PATH.

**Step 2: Verify**

Run: `grep -c "docker" .gitlab-ci.yml`
Expected: at least 4 (existing docker references + new one)

**Step 3: Commit**

```bash
git add .gitlab-ci.yml
git commit -m "ci: add docker CLI to smoke test"
```

---

### Task 14: Build and verify

**Files:** None (verification only)

**Step 1: Build the devcontainer image**

Run: `docker build -t devcontainer-test .devcontainer/`
Expected: successful build, Docker CLI layer installs without errors

**Step 2: Verify Docker CLI is installed**

Run: `docker run --rm devcontainer-test docker --version`
Expected: `Docker version 28.x.x, build ...`

**Step 3: Verify Docker Compose plugin is installed**

Run: `docker run --rm devcontainer-test docker compose version`
Expected: `Docker Compose version v2.x.x`

**Step 4: Verify Docker Buildx plugin is installed**

Run: `docker run --rm devcontainer-test docker buildx version`
Expected: `github.com/docker/buildx v0.x.x ...`

**Step 5: Verify /etc/group is writable**

Run: `docker run --rm devcontainer-test test -w /etc/group && echo "writable"`
Expected: `writable`

**Step 6: Run the full smoke test**

Run: `docker run --rm devcontainer-test bash -c 'set -e; for cmd in curl git ssh jq less fzf ps unzip gpg python3 delta glab claude gosu docker iptables ipset ip dig; do command -v "$cmd" >/dev/null || { echo "MISSING: $cmd"; exit 1; }; done; echo "All utilities present"'`
Expected: `All utilities present`

**Step 7: Verify socket mount works (if host has Docker)**

Run: `docker run --rm -v /var/run/docker.sock:/var/run/docker.sock --group-add "$(stat -c '%g' /var/run/docker.sock)" devcontainer-test docker info`
Expected: Shows daemon info (storage driver, OS, etc.)

**Step 8: Commit (no changes — verification only)**

No commit needed. All changes already committed in previous tasks.
