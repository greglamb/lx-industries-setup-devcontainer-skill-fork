---
name: setup-devcontainer
description: Generates a hardened .devcontainer/ setup for Claude Code autonomous mode and IDE use. Analyzes project toolchain, reuses CI images, pins dependencies with Renovate annotations, handles arbitrary UIDs, git worktrees, SSH agent forwarding, and optional network firewall. Triggers on "devcontainer", "dev container", "containerize development", "run Claude in a container".
license: MIT
compatibility: Requires docker and bash. Generates configs for the Dev Container spec (VS Code, JetBrains, DevPod, devcontainer CLI).
metadata:
  author: lx-industries
  version: "1.0"
---

# Set Up a Dev Container

Create a `.devcontainer/` setup following the [Dev Container spec](https://containers.dev/) that works for Claude Code autonomous mode (`--dangerously-skip-permissions`) and as a generic IDE dev container (VS Code, JetBrains).

## Process

### Phase 1: Project Analysis

Before writing any files, investigate the project thoroughly.

**1. Identify the language ecosystem and build tools:**

```
- Primary language(s) and version(s)
- Package manager(s) and their registry URLs (cargo → crates.io, npm → registry.npmjs.org, pip → pypi.org, go → proxy.golang.org, etc.)
- Build tools (just, make, gradle, etc.)
- Task runner (justfile, Makefile, Taskfile.yml, package.json scripts)
- Required system libraries
```

Registry URLs are needed for Phase 5 (firewall allowlist) if the user opts in.

**2. Check for existing CI container images:**

Look in CI configuration, container registries, and Dockerfiles:
- `.gitlab-ci.yml`, `.github/workflows/`, `Jenkinsfile`
- `images/`, `docker/`, or similar directories
- Container registry for the project (if any)

If the project already builds CI images with the right toolchain, **reuse them as base images** via multi-stage build. This avoids duplicating toolchain setup and keeps the dev container in sync with CI.

**3. Identify additional tools needed beyond CI:**

The dev container likely needs tools CI images lack:
- Claude Code (self-contained native binary — no Node.js dependency)
- Git forge CLIs — both `glab` and `gh` are always installed regardless of project forge; host config directories (`~/.config/glab-cli`, `~/.config/gh`) determine which are pre-authenticated
- SSH client for git operations
- Any interactive development tools

**4. Detect ecosystem dev tools:**

Identify dev/lint/format/test tools the project depends on by scanning two sources:

- **CI configs** — look for tool invocations in scripts (e.g., `cargo clippy`, `ruff check`, `golangci-lint run`, `prettier --check`)
- **Project manifests** — look for tool declarations in dependency files and config files (e.g., `pyproject.toml` dev groups, `package.json` devDependencies, `.golangci.yml`, `.clippy.toml`)

For each detected tool, determine the install scope:
- **Project-managed** — declared in the project's dependency file → skip Dockerfile install, the project's package manager handles it
- **Global** — invoked in CI or configured in the project but not a project dependency → install in the Dockerfile

See [references/dev-tools.md](references/dev-tools.md) for detection signals, install scope rules, and Dockerfile patterns per ecosystem.

**5. Check for Kubernetes tooling:**

Look for signals that the project uses Kubernetes, Helm, or Helmfile:
- Manifests: `Chart.yaml`, `helmfile.yaml`, `helmfile.yml`, `kustomization.yaml`, `values.yaml`
- Config: `kubeconfig`, `.helmignore`, `Chart.lock`, `requirements.yaml`
- CI commands: `kubectl apply`, `helm install`, `helm upgrade`, `helm lint`, `helmfile sync`, `helmfile diff`, `kustomize build`
- Task runner scripts referencing `kubectl`, `helm`, or `helmfile`

If signals found, install kubectl/helm/helmfile in the Dockerfile (see [references/dev-tools.md](references/dev-tools.md) for patterns) and forward `KUBECONFIG` + mount `~/.kube` into the container (see [references/devcontainer-json.md](references/devcontainer-json.md) and [references/task-runner.md](references/task-runner.md)).

**6. Check for Docker/Compose usage:**

Look for signals that the project needs Docker access inside the devcontainer:
- Compose files: `docker-compose.yml`, `docker-compose.yaml`, `compose.yml`, `compose.yaml`
- Container build files: `Dockerfile` or `Containerfile` outside `.devcontainer/`
- Testcontainers dependencies in package manifests
- References to `docker build`, `docker compose`, `podman build` in task runner scripts

See [references/docker-support.md](references/docker-support.md) for the full detection signal list.

If signals found, recommend enabling Docker CLI + Compose support. If none found, still offer the option.

**7. Detect DinD runners (GitLab only):**

If the forge is GitLab and `glab` is authenticated, detect Docker-in-Docker runners available to the project:

1. Run `glab api projects/:id/runners --paginate` to list all runners (`:id` is auto-resolved by `glab` from the current git remote)
2. Sort runners by priority: project → group → instance scope, online before offline
3. Fetch runner details in priority order (`glab api runners/<runner-id>`) to get `tag_list` (the list endpoint does not return tags). Stop after the first runner whose `tag_list` contains a tag matching `dind` or `docker-in-docker` (case-insensitive substring match)
4. If the runner list exceeds 30 entries and no project/group runner matched, skip instance runners and fall back to manual input — large shared runner pools rarely have identifiable DinD tags
5. Store the matched runner's DinD-related tags for use in Phase 4

If `glab` is not available or not authenticated, or no DinD runner is found: warn the user and ask them to provide the DinD runner tag manually.

**8. Check for superpowers plugin:**

If `~/.claude/settings.json` is readable on the host, check whether `enabledPlugins` contains `"superpowers@claude-plugins-official": true`.

If found, note it for Phase 3 — when the user chooses Path A (host settings), the brainstorming visual companion needs port forwarding to be reachable from the host browser.

**9. Check for voice mode support (Path A only):**

Ask: "Do you want voice mode support (audio passthrough for `/voice`)?"

If yes, detect the host's PulseAudio socket (`$XDG_RUNTIME_DIR/pulse/native`) and cookie (`$HOME/.config/pulse/cookie` or `$HOME/.pulse-cookie`). If not found, prompt with common paths. Validate the socket exists. See [references/voice-mode.md](references/voice-mode.md) for full detection logic.

**10. Present findings to the user** before proceeding.

### Phase 2: Dockerfile

Generate `.devcontainer/Dockerfile` and `.devcontainer/entrypoint.sh`.

See [references/dockerfile.md](references/dockerfile.md) for complete Dockerfile patterns covering: base image pinning with digests, Renovate annotations, NPM supply-chain hardening, layer ordering, Claude Code native install, forge CLI config cleanup, git/SSH configuration, permissions (sticky bit), arbitrary UID entrypoint, and worktree compatibility.

Key principles:
- Pin every image with `tag@sha256:digest`
- Every versioned dependency gets a `# renovate:` annotation + `ARG`
- `ENV HOME` and `ENV PATH` set **before** any tool installs
- Never set `WORKDIR` (worktree compatibility)
- `chmod 1777` not `chmod 777`

If Docker support was enabled in Phase 1, also add the Docker CLI layer and `/etc/group` writable. See [references/docker-support.md](references/docker-support.md) for the Dockerfile additions and entrypoint GID handling.

If ecosystem dev tools were detected in Phase 1, add the appropriate install layers. See [references/dev-tools.md](references/dev-tools.md) for Dockerfile patterns, Renovate annotations, and layer placement per ecosystem. Only install tools that need global scope — skip tools managed by the project's dependency file.

If Kubernetes tooling was detected in Phase 1, add kubectl/helm/helmfile install layers. See [references/dev-tools.md](references/dev-tools.md) for Dockerfile patterns and Renovate annotations.

If voice mode was enabled in Phase 1, add the audio packages layer (sox, pulseaudio-utils, libportaudio2, libasound2-plugins, ffmpeg) and PulseAudio client config (`enable-shm = false`). See [references/voice-mode.md](references/voice-mode.md) for the Dockerfile layer.

### Phase 3: devcontainer.json

Generate `.devcontainer/devcontainer.json`. Ask the user whether to share host Claude Code settings or start isolated.

See [references/devcontainer-json.md](references/devcontainer-json.md) for both paths (host settings vs isolated), mount configurations, and the rationale for each key decision (`init`, workspace mount, SSH agent, COLORTERM, dual `.claude` mount workaround).

Key decisions:
- **Path A** (host settings): dual `~/.claude` bind mount + `~/.claude.json` mount
- **Path B** (isolated): named Docker volume, no host config
- Both paths: `"init": true`, host-native `workspaceFolder`, read-only `.gitconfig`, SSH agent socket, `COLORTERM` forwarding

If Docker support was enabled in Phase 1, add the Docker socket bind-mount (`/var/run/docker.sock`). The entrypoint handles GID — no `runArgs` needed.

If Kubernetes tooling was detected in Phase 1, add `~/.kube` bind mount and `KUBECONFIG` env var to `remoteEnv`. See [references/devcontainer-json.md](references/devcontainer-json.md) for the mount and env var configuration.

If superpowers was detected in Phase 1 (Path A only), propose visual companion port forwarding:

> "Superpowers visual companion needs a forwarded port to display in your host browser. Suggested port: 19452. Use a different one?"

Add `forwardPorts`, `portsAttributes` (label: "Brainstorm Companion", onAutoForward: "silent"), and `remoteEnv` entries for `BRAINSTORM_PORT` (with `${localEnv:BRAINSTORM_PORT:19452}` fallback), `BRAINSTORM_HOST` (`0.0.0.0`), and `BRAINSTORM_URL_HOST` (`localhost`). See [references/devcontainer-json.md](references/devcontainer-json.md) for the full snippet.

If voice mode was enabled in Phase 1 (Path A only), add the PulseAudio socket and cookie bind mounts (readonly) and `PULSE_SERVER`/`PULSE_COOKIE` env vars to `remoteEnv`. See [references/voice-mode.md](references/voice-mode.md) for the mount and env var configuration.

### Phase 4: CI Validation

Add CI jobs that run on changes to `.devcontainer/`:

**Schema validation** (no Docker required):

```yaml
devcontainer:validate:
  # Use python variant — bare uv image has uv as entrypoint
  image: ghcr.io/astral-sh/uv:<python-variant>@sha256:<digest>
  script:
    - uvx check-jsonschema --schemafile "https://raw.githubusercontent.com/devcontainers/spec/main/schemas/devContainer.schema.json" .devcontainer/devcontainer.json
  rules:
    - changes:
        - .devcontainer/**/*
        - .gitlab-ci.yml
```

**Build verification** (requires DinD):

If the target `.gitlab-ci.yml` already has a `.docker` hidden job, verify it includes a `tags:` entry with the DinD tag detected in Phase 1. Add the tag if missing. Do not add `rules:` to `.docker` — put rules on the consuming jobs so the anchor stays reusable.

If no `.docker` hidden job exists, generate the full block using the DinD tag(s) from Phase 1:

```yaml
.docker:
  image: docker:<version>@sha256:<digest>
  services:
    - docker:<version>-dind@sha256:<digest>
  tags:
    - <detected-dind-tag>

devcontainer:build:
  extends: .docker
  script:
    - docker build .devcontainer/
  rules:
    - changes:
        - .devcontainer/**/*
        - .gitlab-ci.yml
```

Both jobs should only trigger on changes to `.devcontainer/**/*` or the CI file itself.

### Phase 5: Network Firewall (Optional)

**Ask the user:** will this container be used for autonomous/sandbox mode? If not, skip this phase — the firewall breaks normal development.

See [references/firewall.md](references/firewall.md) for complete firewall implementation: allowlist file generation (auto-detected from Phase 1 registries/forge), `firewall.sh` script, Dockerfile additions (iptables, ipset, gosu), entrypoint modifications (firewall + privilege drop via gosu), and devcontainer.json additions for IDE-based firewall mode.

Key principles:
- Allowlist file with domains, resolved to IPs at startup
- Default DROP policy, allow only DNS/SSH/HTTP/HTTPS to listed domains
- Self-test (verify blocked domain is unreachable)
- `gosu` for privilege drop after firewall setup
- Always include `registry.npmjs.org` and `github.com` regardless of project

If Docker support was enabled in Phase 1, add Docker Hub registry domains (`registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com`) to the allowlist. Scan project Dockerfiles and compose files for additional registries. See [references/docker-support.md](references/docker-support.md).

### Phase 6: Task Runner Integration

**Wrap the container launch** in a task runner recipe so the entry point is `just dev-shell` (or equivalent).

See [references/task-runner.md](references/task-runner.md) for detection logic, recipe structure, and the `--firewall` flag for firewalled autonomous mode.

Key principles:
- Detect existing task runner (justfile, Makefile, Taskfile.yml, package.json)
- Ask user before adding recipes
- Conditional mounts (only mount configs that exist on host)
- TTY auto-detection
- `--firewall` flag for opt-in firewall mode
- Single recipe, not separate isolated/full variants

If Docker support was enabled in Phase 1, add a conditional Docker socket mount with `--group-add` to the recipe. See [references/docker-support.md](references/docker-support.md).

If superpowers was detected in Phase 1, add `BRAINSTORM_PORT` variable with env override (default: 19452) and publish the port with `-p` and `-e` flags for `BRAINSTORM_PORT`, `BRAINSTORM_HOST`, and `BRAINSTORM_URL_HOST`. See [references/task-runner.md](references/task-runner.md) for the recipe additions.

If Kubernetes tooling was detected in Phase 1, add a conditional `~/.kube` mount and `KUBECONFIG` env var to the task runner recipe. See [references/task-runner.md](references/task-runner.md) for the recipe additions.

If voice mode was enabled in Phase 1, add a conditional PulseAudio socket mount with cookie detection to the task runner recipe. See [references/voice-mode.md](references/voice-mode.md) for the recipe additions.

### Phase 7: Testing

Run verifications inside the built container using the task runner recipe from Phase 6 (e.g., `just dev-shell <command>`). If no task runner was configured, use `docker run` directly.

**Verification checklist:**
- [ ] All language toolchain commands work (compiler, package manager)
- [ ] `whoami` resolves (entrypoint injected passwd entry for arbitrary UID)
- [ ] `git status` works with arbitrary UID
- [ ] PID 1 is `tini`/`docker-init` (check `cat /proc/1/cmdline`)
- [ ] Git identity resolves from read-only `.gitconfig` (`git config user.name`)
- [ ] `.gitconfig` is not writable (`git config --global user.name test` should fail)
- [ ] NPM hardening envs are set (`NPM_CONFIG_IGNORE_SCRIPTS=true`, `NPM_CONFIG_MINIMUM_RELEASE_AGE=1440`)
- [ ] SSH agent is accessible (`ssh-add -l` lists keys)
- [ ] SSH-based git operations work (`git ls-remote` or `ssh -T git@<forge>`)
- [ ] Both forge CLIs are available (`glab --version`, `gh --version`)
- [ ] Forge CLIs with mounted config authenticate (`glab auth status`, `gh auth status` for whichever has host config)
- [ ] `claude --version` works with mounted config
- [ ] `claude plugin list` shows all plugins enabled (Path A only)
- [ ] Any project-specific build commands succeed
- [ ] Ecosystem dev tools work, if installed (e.g., `cargo clippy --version`, `ruff --version`, `golangci-lint --version`)

**Kubernetes verification (Kubernetes tooling only):**
- [ ] `kubectl version --client` — kubectl is installed and on PATH
- [ ] `helm version` — Helm is installed (if detected)
- [ ] `helmfile --version` — Helmfile is installed (if detected)
- [ ] `echo $KUBECONFIG` — env var is set and points to a readable file
- [ ] `kubectl config view` — kubeconfig is loaded and contexts are visible

**Docker verification (Docker support only):**
- [ ] `docker version` — CLI installed, daemon reachable via socket
- [ ] `docker compose version` — compose plugin installed
- [ ] `docker buildx version` — buildx plugin installed
- [ ] `docker info` — full daemon connectivity
- [ ] `docker run --rm hello-world` — end-to-end pull + run + cleanup
- [ ] `docker build -t test-build - <<< 'FROM alpine' && docker rmi test-build` — can build images
- [ ] If firewall enabled: `docker pull alpine` succeeds (Docker Hub allowlisted)

**Superpowers visual companion verification (Path A with superpowers only):**
- [ ] `echo $BRAINSTORM_PORT` — env var is set (default: 19452)
- [ ] `echo $BRAINSTORM_HOST` — is `0.0.0.0`
- [ ] Port mapping exists (IDE: implicit via `forwardPorts`; CLI: confirm with `docker port`)

**Voice mode verification (voice mode only):**
- [ ] `sox --version` — SoX is installed
- [ ] `pactl info` — PulseAudio client reaches host server through socket

**Firewall verification (Phase 5 only):**

Run with the firewall flag (e.g., `just dev-shell --firewall <command>`):
- [ ] `curl https://example.com` is rejected (firewall blocks unlisted domains)
- [ ] `curl https://api.anthropic.com` succeeds (Claude API is allowed)
- [ ] `ssh -T git@<forge>` succeeds (forge SSH is allowed)
- [ ] `firewall-list` shows resolved IPs
- [ ] `whoami` still resolves (gosu dropped to correct UID)
- [ ] `id -u` matches host UID (privilege drop worked)

## Reference

Before generating any file, consult the relevant reference for detailed patterns and code blocks:

- **[references/dockerfile.md](references/dockerfile.md)** — Dockerfile patterns, layer ordering, Claude Code install, entrypoint
- **[references/devcontainer-json.md](references/devcontainer-json.md)** — devcontainer.json for both host-settings and isolated modes
- **[references/firewall.md](references/firewall.md)** — Network firewall: allowlist, script, Dockerfile/entrypoint additions
- **[references/task-runner.md](references/task-runner.md)** — Task runner recipe with `--firewall` flag
- **[references/common-mistakes.md](references/common-mistakes.md)** — Common mistakes and red flags to avoid
- **[references/docker-support.md](references/docker-support.md)** — Docker CLI + Compose: detection signals, Dockerfile layer, socket GID handling, firewall domains
- **[references/dev-tools.md](references/dev-tools.md)** — Ecosystem dev tools: detection signals, install scope rules, Dockerfile patterns
- **[references/voice-mode.md](references/voice-mode.md)** — Voice mode audio: PulseAudio socket detection, Dockerfile layer, mounts, task runner recipe, verification
