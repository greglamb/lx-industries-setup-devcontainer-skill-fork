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
| Forge CLI config created by build as root | `glab --version` / `gh --version` during build creates config owned by root:0600 — `rm -rf` and `mkdir -m 1777` after the version check |
| Missing `COLORTERM` in container | Docker doesn't forward `COLORTERM` — add to `remoteEnv` and `-e` flags so CLI tools use truecolor |
| Hardcoded IPs in firewall allowlist | Use domain names in `firewall-allowlist.txt` and resolve at startup — IPs change, domains don't |
| Missing `registry.npmjs.org` in firewall allowlist | Claude Code runs `npm install` for MCP servers even in non-Node.js projects — always allow npmjs |
| Missing `github.com` in firewall allowlist | Claude Code distribution uses GitHub regardless of project forge — always allow it |
| Flushing iptables without saving Docker DNS | Preserve `127.0.0.11` rules before flushing — without them, container DNS resolution breaks |
| Running firewall as non-root | iptables requires root + `NET_ADMIN` capability — in firewalled mode, start as root and drop privileges via `gosu` after firewall setup |
| Granting `NET_ADMIN` in normal mode | Only add `--cap-add=NET_ADMIN --cap-add=NET_RAW` in firewalled mode — they are security-sensitive capabilities not needed for normal development |

## Red Flags

**Never:**
- Install tools without version pinning
- Set `WORKDIR` to a fixed path when worktrees may be used
- Skip digest pinning on FROM lines
- Add Renovate annotations without the correct datasource
- Use `initializeCommand` — it runs on the **host**, not in the container. A malicious or compromised `devcontainer.json` can use it to execute arbitrary code with the user's full privileges before the container even starts. Prefer `onCreateCommand` or `postCreateCommand` (which run inside the container) instead
- Hardcode domain IPs in the firewall — resolve from domain names at startup
- Enable the firewall by default — it breaks normal development; require explicit opt-in (`--firewall`)

**Always:**
- Analyze the project before writing the Dockerfile
- Reuse existing CI images when available
- Test with `--user $(id -u):$(id -g)` (arbitrary UID)
- Mount the project at its host-native path
- Validate devcontainer.json against the spec schema in CI
- Include `registry.npmjs.org` and `github.com` in the firewall allowlist regardless of project language/forge
- Self-test the firewall (verify a blocked domain is unreachable, verify an allowed domain is reachable)
