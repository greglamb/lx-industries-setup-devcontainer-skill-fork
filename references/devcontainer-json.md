# Phase 3: devcontainer.json

**Ask the user:** should the container share the host's Claude Code settings (plugins, skills, preferences), or start fresh?

## Path A: With host Claude Code settings

Shares the host's `~/.claude` and `~/.claude.json` with the container. Plugins, skills, permissions, and preferences carry over. Best for personal development.

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
    "source=<forge-cli-config>,target=<container-config-path>,type=bind",
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

## Path B: Without host settings (isolated)

Fresh Claude Code with no host config sharing. Plugins must be installed inside the container. Uses named Docker volumes so config persists across container rebuilds but is independent of the host. Best for CI, shared team containers, or sandboxed environments. This is the approach used by the [official Claude Code devcontainer](https://github.com/anthropics/claude-code/tree/main/.devcontainer).

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
    "source=<forge-cli-config>,target=<container-config-path>,type=bind",
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

## Key decisions (both paths)

- **`"init": true`**: Runs [tini](https://github.com/krallin/tini) as PID 1. Without it, the shell or Claude Code becomes PID 1, which doesn't handle signals properly (SIGTERM ignored) and doesn't reap zombie child processes. One line, zero cost.
- **`workspaceFolder` and `workspaceMount`** both use `${localWorkspaceFolder}` so the project mounts at the same absolute path as on the host — required for git worktree `.git` file path resolution.
- **`.gitconfig` read-only mount**: Shares the host's git identity (user.name, user.email, aliases) without allowing the container to modify host config. Both paths need this — even isolated containers need git identity for commits.
- **SSH agent socket**: bind-mount `SSH_AUTH_SOCK` from the host and set it in `remoteEnv` — the agent handles authentication (holds decrypted keys), so mounting `~/.ssh` is not needed. Note: the VS Code Dev Containers extension auto-forwards the host SSH agent without any configuration, but the devcontainer CLI does not — the explicit socket mount ensures SSH works in both VS Code and headless/CLI environments (Claude Code, DevPod, CI).
- **`COLORTERM` forwarding**: Docker does not forward `COLORTERM` from the host. Without it, CLI tools (including Claude Code) fall back to basic colors. Forward it via `remoteEnv` in devcontainer.json (`"COLORTERM": "${localEnv:COLORTERM}"`) and `-e COLORTERM="${COLORTERM:-}"` in the task runner recipe. VS Code's integrated terminal handles this automatically, but headless/CLI usage requires explicit forwarding.
- **Forge CLI config**: writable mount (path varies — `~/.config/glab-cli` for glab, `~/.config/gh` for gh). Must be writable because forge CLIs create temporary files in their config directory during normal operations (e.g., atomic writes for config updates). A read-only mount causes "read-only file system" errors.
- **`containerUser` / `remoteUser` / `updateRemoteUserUID`**: Creates the `dev` user in the Dockerfile (UID 1000). IDEs that support the devcontainer spec (VS Code, DevPod) remap UID 1000 to match the host UID automatically via `updateRemoteUserUID`. IDEs that don't support `remoteUser` (Zed — see [zed#46252](https://github.com/zed-industries/zed/issues/46252)) start as root; the entrypoint detects this and drops to the workspace owner UID via `gosu`. Both paths converge to the host UID.
- **`DEVCONTAINER_WORKSPACE`**: Tells the entrypoint which directory to `stat` for workspace owner inference. Falls back to `$(pwd)` if unset. Set explicitly for reliability — some IDEs may change the working directory before running the entrypoint.
- **Docker socket mount** (optional): When Docker support is enabled, bind-mount `/var/run/docker.sock` into the container. The entrypoint detects the socket's GID and adds the target user to the matching group. No `runArgs` needed — GID handling is automatic. See [docker-support.md](docker-support.md) for details.
