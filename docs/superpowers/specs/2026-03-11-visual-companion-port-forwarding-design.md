# Visual Companion Port Forwarding for Devcontainers

**Date:** 2026-03-11
**Status:** Draft
**Summary:** Add port forwarding and env var configuration so the superpowers brainstorming visual companion (HTTP+WebSocket server) is reachable from the host browser when Claude Code runs inside a devcontainer.

## Problem

When Claude Code runs inside a devcontainer with the superpowers plugin, the brainstorming visual companion starts an HTTP+WebSocket server on a port inside the container. This port must be reachable from the host browser. Neither the IDE (VS Code) nor the CLI task runner automatically forward it without explicit configuration. Additionally, the server defaults to binding on `127.0.0.1`, which is unreachable from outside the container — it must bind to `0.0.0.0`.

## Scope

- **In scope:** Path A (host settings) only, where `~/.claude/` is bind-mounted and superpowers is detected.
- **Out of scope:** Path B (isolated mode) — superpowers config wouldn't be present. Voice mode and other audio features are a separate topic.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Default port | 19452 | Outside ephemeral range (49152-65535), avoids collisions with random assignments. User can override. |
| `onAutoForward` | `silent` | Companion already prints the URL — VS Code notification would be redundant. |
| Env var name | `BRAINSTORM_PORT` | Already used by the superpowers companion server code. |
| Server binding | `BRAINSTORM_HOST=0.0.0.0` | Required — `127.0.0.1` inside a container is unreachable from the host. The companion reads `BRAINSTORM_HOST` env var directly. |
| URL hostname | `BRAINSTORM_URL_HOST=localhost` | Controls what hostname the companion prints in its URL. `localhost` is correct for port-forwarded access. |
| `--host 0.0.0.0` responsibility | Devcontainer config (via `remoteEnv`) | The companion server reads `BRAINSTORM_HOST` from the environment. Setting it in `remoteEnv`/task runner `-e` handles this transparently — no user action needed. |
| Firewall + companion | Supported | Loopback traffic is already allowed by iptables rules (`-A INPUT -i lo -j ACCEPT`, `-A OUTPUT -o lo -j ACCEPT`). Port forwarding from Docker bridge is also handled by established/related conntrack rules. No firewall changes needed. |

## Design

### Phase 1: Detection

During project analysis, after existing detection steps (Docker signals, forge CLIs, DinD runners), check for superpowers:

- Check `~/.claude/settings.json` for `"enabledPlugins"` containing `"superpowers@claude-plugins-official": true`.
- If found, note it as a signal for Phase 3.
- Present finding to user: "Detected superpowers plugin — will propose visual companion port forwarding."

### Phase 3: devcontainer.json (Path A Only)

When superpowers is detected, propose to the user:

> "Superpowers visual companion needs a forwarded port to display in your host browser. Suggested port: 19452. Use a different one?"

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

- `silent` because the companion already prints the URL — no VS Code notification needed.
- `${localEnv:BRAINSTORM_PORT:19452}` allows the user's host env var to override the default.
- `BRAINSTORM_HOST=0.0.0.0` makes the companion bind to all interfaces (required for port forwarding to work).
- `BRAINSTORM_URL_HOST=localhost` ensures the printed URL uses `localhost` (correct for port-forwarded access from the host browser).

### Phase 6: Task Runner Recipe

Add a port variable with env override and port publishing. These flags are always added when superpowers is detected — the variable always has a default value (19452), so the flags are always valid.

**justfile example:**

```just
BRAINSTORM_PORT := env("BRAINSTORM_PORT", "19452")
```

In the `docker run` arguments, alongside existing conditional mounts:

```bash
# Visual companion port (superpowers brainstorming)
run_args+=(-p "${BRAINSTORM_PORT}:${BRAINSTORM_PORT}")
run_args+=(-e "BRAINSTORM_PORT=${BRAINSTORM_PORT}")
run_args+=(-e "BRAINSTORM_HOST=0.0.0.0")
run_args+=(-e "BRAINSTORM_URL_HOST=localhost")
```

This mirrors the `devcontainer.json` behavior: default to 19452, but respect the user's environment variable if set.

### Phase 7: Verification

Add to the verification checklist (when superpowers was detected):

- Verify `BRAINSTORM_PORT` is set inside the container: `echo $BRAINSTORM_PORT`
- Verify `BRAINSTORM_HOST` is `0.0.0.0`: `echo $BRAINSTORM_HOST`
- Verify the port mapping exists (IDE: implicit via `forwardPorts`; CLI: confirm with `docker port`)

### SKILL.md Updates

The following SKILL.md sections need conditional additions:

- **Phase 1** (project analysis): Add superpowers detection step after Docker/Compose detection. Check `~/.claude/settings.json` for `enabledPlugins` containing `superpowers@claude-plugins-official`.
- **Phase 3** (devcontainer.json): Add note for Path A — when superpowers detected, add `forwardPorts`, `portsAttributes`, and `remoteEnv` for `BRAINSTORM_PORT`, `BRAINSTORM_HOST`, `BRAINSTORM_URL_HOST`.
- **Phase 6** (task runner): Add note — when superpowers detected, add `BRAINSTORM_PORT` variable with env override, `-p` and `-e` flags.
- **Phase 7** (verification): Add superpowers verification checklist item.

### Reference File Updates

**`references/devcontainer-json.md`:**
- Add superpowers visual companion section under Path A documentation.
- Document `forwardPorts`, `portsAttributes`, and `remoteEnv` with `localEnv` fallback pattern.
- Document `BRAINSTORM_HOST` and `BRAINSTORM_URL_HOST` env vars.

**`references/task-runner.md`:**
- Add `BRAINSTORM_PORT` variable with env override pattern.
- Add `-p` and `-e` flags in the conditional mounts/args section.
- Add `BRAINSTORM_HOST` and `BRAINSTORM_URL_HOST` `-e` flags.

**`references/common-mistakes.md`:**
- Add: "Don't hardcode `BRAINSTORM_PORT` without allowing env override — always use `${localEnv:BRAINSTORM_PORT:19452}` in devcontainer.json and `env("BRAINSTORM_PORT", "19452")` in task runner."
- Add: "Not setting `BRAINSTORM_HOST=0.0.0.0` — the companion binds to `127.0.0.1` by default, which is unreachable from outside the container."
- Add: "Setting `BRAINSTORM_HOST=0.0.0.0` without setting `BRAINSTORM_URL_HOST=localhost` — the printed URL would show `0.0.0.0` which confuses users."

## Technical Context

The superpowers visual companion:
- Runs Express + WebSocket server inside the container.
- Uses `BRAINSTORM_PORT` env var (falls back to random ephemeral port 49152-65535).
- Uses `BRAINSTORM_HOST` env var to control bind address (defaults to `127.0.0.1`).
- Uses `BRAINSTORM_URL_HOST` env var to control the hostname in printed URLs.
- Does NOT auto-open a browser — prints the URL for the user.
- Setting `BRAINSTORM_PORT` makes the port deterministic, enabling pre-configured forwarding.

## No Changes Required

- **`references/dockerfile.md`** — no new packages needed.
- **`references/firewall.md`** — loopback traffic is already allowed by iptables rules. Docker bridge port forwarding is handled by established/related conntrack rules.
- **`references/docker-support.md`** — unrelated to Docker socket forwarding.
