# Phase 2: Dockerfile

Create `.devcontainer/Dockerfile` following these rules:

## Base image selection

- Prefer reusing project CI images as base (multi-stage if needed)
- If no CI images exist, use an official language image (e.g., `rust:1.x`, `node:22`, `python:3.x`)
- Always pin images with tag AND digest: `image:tag@sha256:...`

## Dependency management

Every new dependency must use:

```dockerfile
# renovate: datasource=<source> depName=<name>
ARG <NAME>_VERSION="<full-version>"
```

This enables Renovate bot to auto-update dependencies. Common datasources:
- `docker` for container images
- `node-version` for Node.js
- `npm` for npm packages
- `github-releases` / `gitlab-releases` for CLI tools
- `pypi` for Python packages

**Exception:** Claude Code uses a native binary that auto-updates itself — do not pin its version or add Renovate tracking.

## NPM supply-chain hardening

Claude Code runs `npm install` for MCP servers at runtime. Add these environment variables to block postinstall scripts (common malware vector) and require packages to be at least 24 hours old before installation (supply-chain delay):

```dockerfile
# -- NPM supply-chain hardening ------------------------------------------------
# Block postinstall scripts and require 24h package age for supply-chain safety.
ENV NPM_CONFIG_IGNORE_SCRIPTS=true
ENV NPM_CONFIG_MINIMUM_RELEASE_AGE=1440
```

Place these in the environment section alongside `HOME`, `PATH`, etc.

## Layer ordering (most stable first)

1. Base image and multi-stage COPY operations
2. Environment variables (`ENV HOME`, `ENV PATH`, NPM hardening — set early so installers use correct paths)
3. System packages (`apt-get`, `apk`)
4. Versioned tool installations (CLI tools, etc.)
5. Runtime configuration (git, SSH)

## Claude Code (native binary, auto-updates)

The native binary is self-contained (bundles its own Node.js runtime). Set `HOME` and `PATH` **before** the install so the installer places the binary at the correct location:

```dockerfile
# -- Environment (set early so tool installers use the right paths) -----------

ENV HOME=/tmp/home
ENV PATH="${HOME}/.local/bin:${PATH}"

# ... other install steps ...

# -- Claude Code (native binary, auto-updates) --------------------------------
# HOME is set above so the installer places the binary at $HOME/.local/bin/claude

RUN curl -fsSL https://claude.ai/install.sh | bash \
    && claude --version
```

Key details:
- `HOME` must be set before running the installer — it installs to `$HOME/.local/bin/claude` (symlink) and `$HOME/.local/share/claude/versions/<ver>` (binary)
- Must pipe to `bash` (not `sh`) — the install script uses bash syntax
- No Renovate annotation needed — Claude Code auto-updates at runtime
- After the install, `chmod -R 1777 /tmp/home` makes everything readable by any UID

## Forge CLI config directory cleanup

CLI tools like `glab` and `gh` create config files when run during the build (e.g., `glab --version`). These files are owned by root with restrictive permissions (`0600`), causing "permission denied" errors for non-root users at runtime. Clean up after the version check and recreate the directory as world-writable:

```dockerfile
ENV <FORGE_CLI>_CONFIG_DIR=/tmp/<forge>-config

# `<forge-cli> --version` creates $<FORGE_CLI>_CONFIG_DIR owned by root with 0600 files.
# Remove it and recreate as world-writable so non-root users can either:
#   - bind-mount their host config at runtime, or
#   - let the CLI create a fresh config on first use
RUN <install-forge-cli> \
    && <forge-cli> --version \
    && rm -rf /tmp/<forge>-config \
    && mkdir -m 1777 /tmp/<forge>-config
```

This ensures both modes work: bind-mounting host config (overrides the directory) and running without a mount (CLI creates fresh config in the writable directory).

## Git and SSH configuration

```dockerfile
# Wildcard — mount path unknown at build time
RUN git config --system safe.directory '*'

# Populate known hosts (no interactive prompt)
# Include github.com — Claude Code distribution uses GitHub
RUN mkdir -p /etc/ssh \
    && ssh-keyscan -t ecdsa,rsa,ed25519 <forge>.com github.com >> /etc/ssh/ssh_known_hosts 2>/dev/null
```

Always include `github.com` alongside the project forge — Claude Code connects to GitHub for distribution and updates.

## Permissions

```dockerfile
# Use sticky bit for shared temp dirs
# Claude Code install already created /tmp/home/.local/bin above
RUN chmod -R 1777 /tmp/home
```

Never use `chmod 777` — always `chmod 1777` for world-writable directories.

## Arbitrary UID support (`/etc/passwd` + entrypoint)

Tools like SSH, `whoami`, and `git` need to resolve the current UID to a user in `/etc/passwd`. When the container runs with `--user $(id -u):$(id -g)`, the UID typically has no entry. Without one, SSH authentication fails ("No user exists for uid ...") and other tools misbehave.

Make `/etc/passwd` writable and create an entrypoint that injects a user entry at runtime:

```dockerfile
# Allow entrypoint to add a passwd entry for the running UID
RUN chmod 0666 /etc/passwd

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]
```

Create `.devcontainer/entrypoint.sh`:

```bash
#!/bin/bash
# Inject a passwd entry for the current UID if one does not exist.
# This allows SSH and other tools to resolve the user when running
# with an arbitrary --user UID:GID.
if ! getent passwd "$(id -u)" >/dev/null 2>&1; then
    echo "dev:x:$(id -u):$(id -g):dev:${HOME}:/bin/bash" >> /etc/passwd
fi
exec "$@"
```

## Worktree compatibility — do NOT set WORKDIR

```dockerfile
# No WORKDIR — project mounted at host-native absolute path
# for git worktree compatibility (.git file contains absolute paths)
```

Set `HOME`, `PATH`, and any config directories as environment variables **early in the Dockerfile** (before tool installations) so installers use the correct paths:

```dockerfile
ENV HOME=/tmp/home
ENV PATH="${HOME}/.local/bin:${PATH}"
```

This is critical for Claude Code's native installer — it installs to `$HOME/.local/bin/claude`, so `HOME` must be set before running the install script.
