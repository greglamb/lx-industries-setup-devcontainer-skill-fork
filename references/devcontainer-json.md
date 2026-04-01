# Phase 3: devcontainer.json

**Ask the user:** should the container share the host's settings for the selected AI tool(s) (plugins, skills, preferences), or start fresh?

## Path A: With host settings

Shares the host's AI tool configuration with the container. Plugins, skills, permissions, and preferences carry over. Best for personal development.

```json
{
  "name": "<project-name>",
  "build": { "dockerfile": "Dockerfile" },
  "init": true,
  "containerUser": "dev",
  "remoteUser": "dev",
  "updateRemoteUserUID": true,
  "workspaceFolder": "${localWorkspaceFolder}",
  "workspaceMount": "source=${localWorkspaceFolder},target=${localWorkspaceFolder},type=bind",
  "mounts": [
    "source=${localEnv:HOME}/.config/glab-cli,target=/tmp/glab-config,type=bind",
    "source=${localEnv:HOME}/.config/gh,target=/tmp/gh-config,type=bind",
    "source=${localEnv:HOME}/.gitconfig,target=/tmp/home/.gitconfig,type=bind,readonly",
    "source=${localEnv:HOME}/.claude,target=/tmp/home/.claude,type=bind",
    "source=${localEnv:HOME}/.claude,target=${localEnv:HOME}/.claude,type=bind",
    "source=${localEnv:HOME}/.claude.json,target=/tmp/home/.claude.json,type=bind",
    "source=${localEnv:SSH_AUTH_SOCK},target=/tmp/ssh-agent.sock,type=bind"
  ],
  "remoteEnv": {
    "SSH_AUTH_SOCK": "/tmp/ssh-agent.sock",
    "GIT_SSH_COMMAND": "ssh -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts",
    "COLORTERM": "${localEnv:COLORTERM}"
  },
  "containerEnv": {
    "DEVCONTAINER_WORKSPACE": "${localWorkspaceFolder}"
  }
}
```

The `~/.claude` directory requires **two bind mounts** — one at `$HOME/.claude` (container HOME) and one at the host-native path (e.g. `/home/user/.claude`). This is a workaround for [claude-code#10379](https://github.com/anthropics/claude-code/issues/10379): plugin manifests store absolute host paths for marketplace and install locations. Without the second mount, plugins fail with "not found in marketplace". A symlink won't work because the host-native workspace mount creates the host home directory owned by root, blocking symlink creation by non-root users. Both bind mounts of the same host directory share the underlying filesystem — writes at either path are immediately visible at the other.

### opencode config passthrough (conditional on opencode selected)

When opencode is selected, mount its three XDG-standard directories. Since `HOME=/tmp/home` in the container, paths resolve naturally — **no dual mount workaround needed** (opencode uses relative XDG paths, not absolute host paths in manifests).

Add to the generated `devcontainer.json` mounts:

```json
"source=${localEnv:HOME}/.config/opencode,target=/tmp/home/.config/opencode,type=bind",
"source=${localEnv:HOME}/.local/share/opencode,target=/tmp/home/.local/share/opencode,type=bind",
"source=${localEnv:HOME}/.cache/opencode,target=/tmp/home/.cache/opencode,type=bind"
```

Key points:
- **All three mounts are writable**: auth storage (`~/.local/share/opencode/auth.json`) needs token refresh, plugin cache (`~/.cache/opencode/`) needs bun install, config is writable for consistency.
- **No dual mount needed**: Unlike Claude Code's `~/.claude` (which needs a mount at both `$HOME/.claude` and the host-native path due to absolute paths in plugin manifests), opencode uses XDG paths that resolve relative to `$HOME`. A single mount at the container `$HOME` path is sufficient.
- **No separate preferences file**: opencode stores everything in its config directory — no equivalent of Claude Code's `~/.claude.json`.
- **Claude Code mounts are conditional**: When only opencode is selected, omit the `~/.claude`, dual `~/.claude` mount, and `~/.claude.json` mounts entirely.

### Kubernetes config passthrough (optional, both paths)

When Kubernetes tooling is detected in Phase 1, mount the host's `~/.kube` directory so kubectl/helm/helmfile can access cluster credentials and contexts. Set `KUBECONFIG` to the container-mapped path.

Add to the generated `devcontainer.json` mounts:

```json
"source=${localEnv:HOME}/.kube,target=/tmp/home/.kube,type=bind"
```

Add to `remoteEnv`:

```json
"KUBECONFIG": "/tmp/home/.kube/config"
```

Key points:
- **Writable mount**: kubectl writes to `~/.kube/cache` and some auth plugins (e.g., `gke-gcloud-auth-plugin`, `kubelogin`) update token fields in the config file. A read-only mount breaks these flows.
- **`KUBECONFIG` env var**: Set explicitly to the container path. When unset, kubectl defaults to `$HOME/.kube/config` which resolves correctly since `HOME=/tmp/home`, but setting it explicitly avoids surprises if tools use different default logic.
- **No dual mount needed**: Unlike `~/.claude`, kubeconfig paths are not stored as absolute host paths in any tool metadata. A single mount at `$HOME/.kube` is sufficient.
- **Non-default KUBECONFIG**: If the host has `KUBECONFIG` set to a path outside `~/.kube`, the devcontainer.json approach doesn't handle it — the task runner recipe is more flexible for this case. For devcontainer.json, document that users should adjust the mount source if they use a custom `KUBECONFIG` path. Colon-separated multi-file `KUBECONFIG` (e.g., `~/.kube/config:~/.kube/staging`) is not supported — each file would need its own mount and the paths remapped. This is rare enough to handle as a manual adjustment.
- **Helm and helmfile cache**: Helm uses `$XDG_CACHE_HOME/helm` (defaults to `~/.cache/helm`). This is inside the container HOME, so it works automatically — no extra mount needed.
- **Both paths**: Include this mount in both Path A and Path B configurations. Even isolated containers need cluster access for development.

### Superpowers visual companion (optional, Path A only)

When the superpowers plugin is detected in `~/.claude/settings.json` (`enabledPlugins` contains `superpowers@claude-plugins-official`), propose a fixed port for the brainstorming visual companion. The companion starts an HTTP+WebSocket server inside the container that must be reachable from the host browser.

Add to the generated `devcontainer.json`:

```json
{
  "forwardPorts": [19452],
  "portsAttributes": {
    "19452": {
      "label": "Brainstorm Companion",
      "onAutoForward": "silent"
    }
  },
  "remoteEnv": {
    "BRAINSTORM_PORT": "${localEnv:BRAINSTORM_PORT:19452}",
    "BRAINSTORM_HOST": "0.0.0.0",
    "BRAINSTORM_URL_HOST": "localhost"
  }
}
```

Key points:
- **`BRAINSTORM_PORT`**: The companion reads this env var. `${localEnv:BRAINSTORM_PORT:19452}` uses the host env var if set, falls back to 19452. Without a fixed port, the companion picks a random ephemeral port that can't be pre-configured for forwarding.
- **`BRAINSTORM_HOST=0.0.0.0`**: The companion binds to `127.0.0.1` by default, which is unreachable from outside the container. Setting this makes it bind to all interfaces so port forwarding works.
- **`BRAINSTORM_URL_HOST=localhost`**: Controls the hostname in the URL the companion prints. Without this, the URL would show `0.0.0.0`, which confuses users. `localhost` is correct for port-forwarded access.
- **`onAutoForward: "silent"`**: The companion already prints its URL — a VS Code notification would be redundant.
- Propose 19452 as the default and ask the user: "Use a different one?"
- **`forwardPorts` limitation**: The devcontainer spec does not support variable substitution in `forwardPorts`, so the port number is hardcoded there. If the user overrides `BRAINSTORM_PORT` via a host env var, they must also update the `forwardPorts` value to match — otherwise IDE-based port forwarding will forward the wrong port. The task runner path (`-p` flag) uses the variable and is not affected.

### Voice mode audio passthrough (optional, Path A only)

When voice mode is enabled in Phase 1, mount the host's PulseAudio socket and cookie into the container so voice commands (Claude Code's `/voice`) can capture audio.

Add to the generated `devcontainer.json` mounts:

```json
"source=<detected_socket_path>,target=/tmp/pulse.socket,type=bind,readonly",
"source=<detected_cookie_path>,target=/tmp/pulse.cookie,type=bind,readonly"
```

Where `<detected_socket_path>` is the PulseAudio socket confirmed during Phase 1 (e.g., `/run/user/1000/pulse/native`). Where `<detected_cookie_path>` is the cookie file found during Phase 1 (e.g., `${localEnv:HOME}/.config/pulse/cookie`). Omit the cookie mount if no cookie was found.

Add to `remoteEnv`:

```json
"PULSE_SERVER": "unix:/tmp/pulse.socket",
"PULSE_COOKIE": "/tmp/pulse.cookie"
```

Key points:
- **`PULSE_SERVER`**: Tells PulseAudio client where the server socket is. The `unix:` prefix specifies Unix domain socket transport.
- **`PULSE_COOKIE`**: Authentication cookie. Omit if the host uses anonymous auth (no cookie file found).
- **Socket is read-only**: The container only reads audio data through the socket.
- **No `forwardPorts`**: This is a Unix socket mount, not a TCP port.
- **No `runArgs` or capabilities**: PulseAudio socket passthrough works without elevated privileges.
- Mount targets are in `/tmp/` — consistent with SSH agent (`/tmp/ssh-agent.sock`). The env vars tell PulseAudio where to find them.

## Path B: Without host settings (isolated)

Fresh environment with no host config sharing for the selected AI tool(s). Plugins must be installed inside the container. Uses named Docker volumes so config persists across container rebuilds but is independent of the host. Best for CI, shared team containers, or sandboxed environments.

```json
{
  "name": "<project-name>",
  "build": { "dockerfile": "Dockerfile" },
  "init": true,
  "containerUser": "dev",
  "remoteUser": "dev",
  "updateRemoteUserUID": true,
  "workspaceFolder": "${localWorkspaceFolder}",
  "workspaceMount": "source=${localWorkspaceFolder},target=${localWorkspaceFolder},type=bind",
  "mounts": [
    "source=${localEnv:HOME}/.config/glab-cli,target=/tmp/glab-config,type=bind",
    "source=${localEnv:HOME}/.config/gh,target=/tmp/gh-config,type=bind",
    "source=${localEnv:HOME}/.gitconfig,target=/tmp/home/.gitconfig,type=bind,readonly",
    "source=claude-config-${devcontainerId},target=/tmp/home/.claude,type=volume",
    "source=${localEnv:SSH_AUTH_SOCK},target=/tmp/ssh-agent.sock,type=bind"
  ],
  "remoteEnv": {
    "SSH_AUTH_SOCK": "/tmp/ssh-agent.sock",
    "GIT_SSH_COMMAND": "ssh -o UserKnownHostsFile=/etc/ssh/ssh_known_hosts",
    "COLORTERM": "${localEnv:COLORTERM}"
  },
  "containerEnv": {
    "DEVCONTAINER_WORKSPACE": "${localWorkspaceFolder}"
  }
}
```

No dual mount needed — there are no host paths to resolve. The named volume (`claude-config-${devcontainerId}`) persists across container rebuilds. No `~/.claude.json` mount needed — Claude Code creates it fresh on first run.

### opencode isolated volumes (conditional on opencode selected)

When opencode is selected in isolated mode, use named volumes:

```json
"source=opencode-config-${devcontainerId},target=/tmp/home/.config/opencode,type=volume",
"source=opencode-data-${devcontainerId},target=/tmp/home/.local/share/opencode,type=volume",
"source=opencode-cache-${devcontainerId},target=/tmp/home/.cache/opencode,type=volume"
```

Key points:
- Three separate named volumes (config, data, cache) rather than one — follows XDG separation of concerns.
- Volumes persist across container rebuilds but are independent of the host.
- When only opencode is selected, omit the Claude Code named volume (`claude-config-${devcontainerId}`).

## Key decisions (both paths)

- **`"init": true`**: Runs [tini](https://github.com/krallin/tini) as PID 1. Without it, the shell or the AI coding tool becomes PID 1, which doesn't handle signals properly (SIGTERM ignored) and doesn't reap zombie child processes. One line, zero cost.
- **`workspaceFolder` and `workspaceMount`** both use `${localWorkspaceFolder}` so the project mounts at the same absolute path as on the host — required for git worktree `.git` file path resolution.
- **`.gitconfig` read-only mount**: Shares the host's git identity (user.name, user.email, aliases) without allowing the container to modify host config. Both paths need this — even isolated containers need git identity for commits.
- **SSH agent socket**: bind-mount `SSH_AUTH_SOCK` from the host and set it in `remoteEnv` — the agent handles authentication (holds decrypted keys), so mounting `~/.ssh` is not needed. Note: the VS Code Dev Containers extension auto-forwards the host SSH agent without any configuration, but the devcontainer CLI does not — the explicit socket mount ensures SSH works in both VS Code and headless/CLI environments (Claude Code, DevPod, CI).
- **`COLORTERM` forwarding**: Docker does not forward `COLORTERM` from the host. Without it, CLI tools (including Claude Code) fall back to basic colors. Forward it via `remoteEnv` in devcontainer.json (`"COLORTERM": "${localEnv:COLORTERM}"`) and `-e COLORTERM="${COLORTERM:-}"` in the task runner recipe. VS Code's integrated terminal handles this automatically, but headless/CLI usage requires explicit forwarding.
- **Forge CLI config**: Both `glab` and `gh` configs are mounted as writable binds (`~/.config/glab-cli` → `/tmp/glab-config`, `~/.config/gh` → `/tmp/gh-config`). Must be writable because forge CLIs create temporary files in their config directory during normal operations (e.g., atomic writes for config updates). A read-only mount causes "read-only file system" errors.
- **`containerUser` / `remoteUser` / `updateRemoteUserUID`**: Creates the `dev` user in the Dockerfile (UID 1000). IDEs that support the devcontainer spec (VS Code, DevPod) remap UID 1000 to match the host UID automatically via `updateRemoteUserUID`. IDEs that don't support `remoteUser` (Zed — see [zed#46252](https://github.com/zed-industries/zed/issues/46252)) start as root; the entrypoint detects this and drops to the workspace owner UID via `gosu`. Both paths converge to the host UID.
- **`DEVCONTAINER_WORKSPACE`**: Tells the entrypoint which directory to `stat` for workspace owner inference. Falls back to `$(pwd)` if unset. Set explicitly for reliability — some IDEs may change the working directory before running the entrypoint.
- **Docker socket mount** (optional): When Docker support is enabled, bind-mount `/var/run/docker.sock` into the container. The entrypoint detects the socket's GID and adds the target user to the matching group. No `runArgs` needed — GID handling is automatic. See [docker-support.md](docker-support.md) for details.
