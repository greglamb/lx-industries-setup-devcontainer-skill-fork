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
6. Non-root user creation (for `remoteUser` + `updateRemoteUserUID`)

## Docker CLI + Compose (optional)

When the project needs Docker access inside the devcontainer (detected in Phase 1), install the Docker CLI tools from Docker's official APT repo. See [docker-support.md](docker-support.md) for the full Dockerfile layer, detection signals, and entrypoint GID handling.

Key points:
- Install `docker-ce-cli`, `docker-compose-plugin`, and `docker-buildx-plugin` — never `docker-ce` (no daemon)
- Installs latest available versions from Docker's APT repo. No Renovate annotation — APT packages in a third-party repo lack a suitable Renovate datasource.
- Place the layer after system packages and before forge CLI installs
- Add `chmod 0666 /etc/group` alongside `/etc/passwd` for Docker GID injection

## Voice mode audio (optional)

When the user opts in to voice mode during Phase 1, add the audio packages layer. Place after system packages, before Claude Code install:

```dockerfile
# Voice mode audio support (optional)
RUN apt-get update && apt-get install -y --no-install-recommends \
    sox \
    pulseaudio-utils \
    libportaudio2 \
    libasound2-plugins \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*

# PulseAudio client config — disable shared memory (required for socket passthrough in containers)
RUN mkdir -p /etc/pulse && \
    printf 'enable-shm = false\n' > /etc/pulse/client.conf
```

Key points:
- No Renovate annotations — distro packages pinned by base image.
- `--no-install-recommends` to avoid unnecessary dependencies.
- `enable-shm = false` is required — PulseAudio shared memory does not work across container boundaries.
- No build-time deps (`libasound2-dev`, `python3-dev`) — only runtime libraries needed.

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

Both `glab` (GitLab) and `gh` (GitHub) CLIs are always installed regardless of project forge. Each CLI creates config files when run during the build (e.g., `--version`). These files are owned by root with restrictive permissions (`0600`), causing "permission denied" errors for non-root users at runtime. Clean up after the version check and recreate the directory as world-writable:

```dockerfile
ENV GLAB_CONFIG_DIR=/tmp/glab-config
ENV GH_CONFIG_DIR=/tmp/gh-config

# -- GitLab CLI (glab) ---------------------------------------------------------
# renovate: datasource=gitlab-releases depName=gitlab-org/cli registryUrl=https://gitlab.com
ARG GLAB_VERSION="<version>"
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${arch}.deb" -o /tmp/glab.deb \
    && dpkg -i /tmp/glab.deb \
    && rm /tmp/glab.deb \
    && glab --version \
    && rm -rf /tmp/glab-config \
    && mkdir -m 1777 /tmp/glab-config

# -- GitHub CLI (gh) -----------------------------------------------------------
# renovate: datasource=github-releases depName=cli/cli
ARG GH_VERSION="<version>"
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/cli/cli/releases/download/v${GH_VERSION}/gh_${GH_VERSION}_linux_${arch}.deb" -o /tmp/gh.deb \
    && dpkg -i /tmp/gh.deb \
    && rm /tmp/gh.deb \
    && gh --version \
    && rm -rf /tmp/gh-config \
    && mkdir -m 1777 /tmp/gh-config
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

## Non-root user (remoteUser + updateRemoteUserUID)

Create exactly one non-root user in the image. The devcontainer spec's `updateRemoteUserUID` mechanism requires a non-root user to remap — without one, it has nothing to remap and the container runs as root.

```dockerfile
# -- Non-root user (for remoteUser + updateRemoteUserUID) --------------------
# IDEs that support the devcontainer spec remap this UID to match the host.
# IDEs that don't (Zed) rely on the entrypoint to detect and drop to the
# workspace owner UID via gosu.
RUN groupadd --gid 1000 dev \
 && useradd --uid 1000 --gid 1000 --no-create-home --home-dir /tmp/home --shell /bin/bash dev
```

Place this **before** the permissions section (`chmod -R 1777 /tmp/home`) — the user needs to exist before permissions are set, and `--no-create-home` avoids conflicting with the already-existing `/tmp/home` directory.

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
# Resolve target UID — priority: explicit env var > workspace owner > current UID
target_uid="${DEVCONTAINER_UID:-$(id -u)}"
target_gid="${DEVCONTAINER_GID:-$(id -g)}"

# If root without explicit UID, infer from workspace owner (handles IDEs like Zed)
if [[ "$(id -u)" = "0" ]] && [[ -z "${DEVCONTAINER_UID:-}" ]]; then
    workspace="${DEVCONTAINER_WORKSPACE:-$(pwd)}"
    if [[ -d "$workspace" ]]; then
        target_uid="$(stat -c '%u' "$workspace")"
        target_gid="$(stat -c '%g' "$workspace")"
    fi
fi

if ! getent passwd "$target_uid" >/dev/null 2>&1; then
    echo "dev:x:${target_uid}:${target_gid}:dev:${HOME}:/bin/bash" >> /etc/passwd
fi

# Drop privileges if running as root with a non-root target
if [[ "$(id -u)" = "0" ]] && [[ "${target_uid}" != "0" ]]; then
    exec gosu "${target_uid}:${target_gid}" "$@"
fi

exec "$@"
```

The `gosu` command is required for the privilege-drop block. If Phase 5 (firewall) is configured, `gosu` is already installed as part of the firewall packages. If not, install it standalone:

```dockerfile
# renovate: datasource=github-releases depName=tianon/gosu
ARG GOSU_VERSION="1.19"
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${arch}" -o /usr/local/bin/gosu \
    && chmod +x /usr/local/bin/gosu \
    && gosu --version
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
