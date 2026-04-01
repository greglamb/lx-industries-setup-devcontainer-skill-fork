# Common Mistakes and Red Flags

## Common Mistakes

| Mistake | Fix |
|---------|-----|
| `chmod 777` on directories | Use `chmod 1777` (sticky bit) |
| `WORKDIR /project` with fixed mount | Mount at `${localWorkspaceFolder}` (worktree compat) |
| `safe.directory /project` | Use `safe.directory '*'` (wildcard) |
| `:latest` tag on base images | Pin with `tag@sha256:digest` |
| Missing Renovate annotations | Every versioned dep needs `# renovate:` + `ARG` |
| `.git` mounted read-only | Git needs write access (lock files) |
| FROM without digest | Always `image:tag@sha256:...` |
| No `/etc/passwd` entry for arbitrary UID | `chmod 0666 /etc/passwd` + entrypoint that injects user entry |
| Mounting `~/.ssh` instead of SSH agent | Bind-mount `SSH_AUTH_SOCK` — the agent handles auth; raw key files are not needed |
| `ENV HOME` set after Claude Code install | The installer uses `$HOME` to decide where to place the binary — set `HOME` before running it |
| Only mounting `~/.claude/` at container HOME | Also bind-mount at the host-native path (dual mount) — plugin manifests store absolute host paths ([#10379](https://github.com/anthropics/claude-code/issues/10379)); symlinks don't work because the workspace mount creates the host home dir owned by root |
| Only mounting `~/.claude/` for Claude Code | Also mount `~/.claude.json` — stores onboarding state and preferences (separate file, not inside the directory) |
| Installing Claude Code via npm | Use the native installer (`curl -fsSL https://claude.ai/install.sh \| bash`) — npm method is deprecated |
| Missing `github.com` in SSH known hosts | Claude Code connects to GitHub for distribution — include it alongside the project forge |
| Piping install script to `sh` instead of `bash` | The Claude Code install script uses bash syntax — `sh` fails with syntax errors |
| Missing `"init": true` in devcontainer.json | Without tini as PID 1, signals aren't handled properly and zombie processes accumulate |
| Writable `.gitconfig` mount | Mount `.gitconfig` with `:ro` — prevents container from modifying host git config |
| No NPM supply-chain hardening | Set `NPM_CONFIG_IGNORE_SCRIPTS=true` and `NPM_CONFIG_MINIMUM_RELEASE_AGE=1440` — Claude Code runs `npm install` for MCP servers |
| Forge CLI config mounted read-only | Forge CLIs (glab, gh) create temp files in their config directory during normal operations (atomic writes) — mount without `:ro` |
| Forge CLI config created by build as root | `glab --version` / `gh --version` during build creates config owned by root:0600 — `rm -rf` and `mkdir -m 1777` after the version check |
| Missing `COLORTERM` in container | Docker doesn't forward `COLORTERM` — add to `remoteEnv` and `-e` flags so CLI tools use truecolor |
| Hardcoded IPs in firewall allowlist | Use domain names in `firewall-allowlist.txt` and resolve at startup — IPs change, domains don't |
| Missing `registry.npmjs.org` in firewall allowlist | Claude Code runs `npm install` for MCP servers — allow npmjs when Claude Code is selected or the project uses npm |
| Missing `github.com` in firewall allowlist | Claude Code distribution uses GitHub — allow when Claude Code is selected or the project forge is GitHub |
| Flushing iptables without saving Docker DNS | Preserve `127.0.0.11` rules before flushing — without them, container DNS resolution breaks |
| Running firewall as non-root | iptables requires root + `NET_ADMIN` capability — in firewalled mode, start as root and drop privileges via `gosu` after firewall setup |
| Granting `NET_ADMIN` in normal mode | Only add `--cap-add=NET_ADMIN --cap-add=NET_RAW` in firewalled mode — they are security-sensitive capabilities not needed for normal development |
| No `remoteUser` in devcontainer.json | Add `"containerUser": "dev"`, `"remoteUser": "dev"`, `"updateRemoteUserUID": true` — without these, IDEs run as root and file ownership diverges from CLI usage |
| Running as root without workspace UID inference | Entrypoint must detect root-without-explicit-UID and `stat` the workspace to infer the target UID — otherwise IDEs like Zed (which ignore `remoteUser`) create files owned by root |
| gosu condition only checks `DEVCONTAINER_UID` | Check `target_uid != 0` instead — gosu must also trigger when the target was inferred from the workspace owner, not just when explicitly set via env var |
| No `DEVCONTAINER_WORKSPACE` env var | Pass `DEVCONTAINER_WORKSPACE` in devcontainer.json (`containerEnv`) and task runner (`-e` flag) — the entrypoint falls back to `$(pwd)` but explicit is more reliable |
| Installing `dockerd` (daemon) inside devcontainer | Use socket mount — host daemon handles all execution via `/var/run/docker.sock` |
| Hardcoding Docker GID (e.g., 999 or 998) | Detect at runtime: `stat -c '%g' /var/run/docker.sock` in task runner, entrypoint for IDE paths |
| `/etc/group` not writable for Docker GID injection | `chmod 0666 /etc/group` alongside `/etc/passwd` in Dockerfile |
| Socket mount without GID handling | Use `--group-add` in task runner, or entrypoint GID injection for IDE paths |
| Missing Docker Hub domains in firewall allowlist | Add `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` when Docker is enabled |
| Using standalone `docker-compose` (v1) | Install `docker-compose-plugin` (v2) — runs as `docker compose` subcommand |
| Mounting Docker socket unconditionally in task runner | Check `-S /var/run/docker.sock` first — socket may not exist on all hosts |
| Not scanning compose/Dockerfiles for registries | Firewall silently blocks unlisted registries — scan `FROM` and `image:` for additional domains |
| Missing dev tools that CI validates against | Scan CI configs and project manifests for lint/format/test tools — if CI runs it, the devcontainer needs it. See [dev-tools.md](dev-tools.md) |
| Installing project-managed dev tools globally in Dockerfile | If the tool is declared in a project dependency file (pyproject.toml dev group, package.json devDependencies), skip the Dockerfile install — the project's package manager handles it |
| Pinning rustup components with Renovate | clippy and rustfmt are bundled with the Rust toolchain — they follow the toolchain version, not their own |
| Hardcoding `BRAINSTORM_PORT` without env override | Use `${localEnv:BRAINSTORM_PORT:19452}` in devcontainer.json and `env("BRAINSTORM_PORT", "19452")` in task runner |
| Not setting `BRAINSTORM_HOST=0.0.0.0` for visual companion | The companion binds to `127.0.0.1` by default — unreachable from outside the container |
| Setting `BRAINSTORM_HOST=0.0.0.0` without `BRAINSTORM_URL_HOST=localhost` | The printed URL shows `0.0.0.0` which confuses users — set `BRAINSTORM_URL_HOST=localhost` |
| Mounting `~/.kube` read-only | kubectl writes to `~/.kube/cache` and auth plugins (gke-gcloud-auth-plugin, kubelogin) refresh tokens in the config — mount writable |
| Forwarding raw `KUBECONFIG` host path to container | Host path (e.g., `/home/user/.kube/config`) doesn't exist at that path in the container — set `KUBECONFIG` to the container-mapped path (`/tmp/home/.kube/config`) |
| Missing `~/.kube` mount when Kubernetes tools are detected | kubectl/helm/helmfile can't reach clusters without the kubeconfig — always mount `~/.kube` when Kubernetes tooling is present |
| Forgetting `enable-shm = false` in `/etc/pulse/client.conf` | PulseAudio shared memory does not work across container boundaries — socket passthrough requires `enable-shm = false` |
| Mounting PipeWire native socket (`pipewire-0`) instead of PulseAudio compat socket (`pulse/native`) | SoX speaks PulseAudio, not PipeWire — use the PulseAudio compat socket (created by `pipewire-pulse` on PipeWire hosts) |
| Mounting PulseAudio cookie unconditionally | Check for cookie at both `~/.config/pulse/cookie` (XDG) and `~/.pulse-cookie` (legacy) — omit mount if neither exists (anonymous auth) |
| Hardcoding `/run/user/1000/` for PulseAudio socket | Use `$XDG_RUNTIME_DIR/pulse/native` for detection; fall back to prompted path with `$(id -u)` hints |
| Installing opencode via npm when install script is available | Use `curl -fsSL https://opencode.ai/install \| bash` — consistent with the project's install method |
| Missing opencode config directories in Path A mounts | Mount all three XDG paths: `~/.config/opencode`, `~/.local/share/opencode`, `~/.cache/opencode` |
| Mounting opencode auth (`~/.local/share/opencode`) read-only | Auth plugins may refresh tokens — mount writable |
| Dual-mounting opencode config at host-native path | Not needed — opencode uses XDG paths relative to `$HOME`, no absolute host path issue like Claude Code's plugin manifests |
| Including `registry.npmjs.org` in firewall when only opencode is selected | Only include if the project itself uses npm — opencode uses bun for plugins, not npm |
| Including `github.com` in firewall when only opencode is selected | Only include if the project forge is GitHub — opencode installs from `opencode.ai`, not GitHub |
| Hardcoding a single LLM provider domain in firewall for opencode | Ask the user which provider(s) they'll use — opencode supports 75+ providers with different API domains |

## Red Flags

**Never:**
- Install tools without version pinning
- Set `WORKDIR` to a fixed path when worktrees may be used
- Skip digest pinning on FROM lines
- Add Renovate annotations without the correct datasource
- Use `initializeCommand` — it runs on the **host**, not in the container. A malicious or compromised `devcontainer.json` can use it to execute arbitrary code with the user's full privileges before the container even starts. Prefer `onCreateCommand` or `postCreateCommand` (which run inside the container) instead
- Hardcode domain IPs in the firewall — resolve from domain names at startup
- Enable the firewall by default — it breaks normal development; require explicit opt-in (`--firewall`)
- Install `dockerd` or `containerd` inside a devcontainer — use the host daemon via socket mount
- Hardcode the Docker socket GID — it varies per host (999, 998, 133, etc.)
- Hardcode `BRAINSTORM_PORT` without allowing env override — the user may need a different port
- Mount `/dev/snd` for container audio — use PulseAudio socket passthrough instead (avoids exclusive device access and host conflicts)
- Assume opencode needs the same dual-mount workaround as Claude Code — it doesn't (XDG paths are relative to `$HOME`)
- Include Claude Code-specific firewall entries (npmjs, github.com, api.anthropic.com) when only opencode is selected

**Always:**
- Analyze the project before writing the Dockerfile
- Reuse existing CI images when available
- Test with `--user $(id -u):$(id -g)` (arbitrary UID)
- Mount the project at its host-native path
- Validate devcontainer.json against the spec schema in CI
- Include `registry.npmjs.org` in the firewall allowlist when Claude Code is selected or the project uses npm; include `github.com` when Claude Code is selected or the project forge is GitHub
- Self-test the firewall (verify a blocked domain is unreachable, verify an allowed domain is reachable)
- Set `containerUser`, `remoteUser`, and `updateRemoteUserUID` in devcontainer.json
- Test the container started as root without `--user` to verify the entrypoint drops to the workspace owner UID
- Scan for Docker support signals during Phase 1 project analysis (compose files, Dockerfiles, Testcontainers deps)
- Use `--group-add` for CLI and entrypoint GID injection for IDE Docker socket access
- Scan CI configs and project manifests for ecosystem dev tools during Phase 1 project analysis
- Set `BRAINSTORM_HOST=0.0.0.0` and `BRAINSTORM_URL_HOST=localhost` alongside `BRAINSTORM_PORT` when configuring the visual companion
- Set `enable-shm = false` in `/etc/pulse/client.conf` when mounting PulseAudio socket into a container
- Use the PulseAudio-compatible socket (`pulse/native`) even on PipeWire hosts — SoX speaks PulseAudio
- Ask which AI tool(s) to install (Claude Code, opencode, or both) before generating any files
- Mount all three opencode XDG directories when opencode is selected (config, data, cache)
- Ask which LLM provider(s) opencode will use when generating a firewall allowlist
