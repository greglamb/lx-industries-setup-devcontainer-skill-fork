# Voice Mode Audio Passthrough for Devcontainers

**Date:** 2026-03-11
**Status:** Draft
**Summary:** Add PulseAudio socket passthrough so Claude Code's `/voice` command (STT via SoX) works inside a devcontainer by mounting the host's audio server socket.

## Problem

Claude Code shipped native voice mode (March 3, 2026) via the `/voice` command. It uses SoX (`rec`) on Linux for audio capture through PulseAudio. Running in a devcontainer, the container needs access to the host's audio server via socket passthrough. There is a known issue (GitHub #31065) where voice mode fails in containers without audio access.

Voice mode is STT-only (no TTS). Audio is captured locally, pre-processed, then sent as compressed tokens through the existing `api.anthropic.com` endpoint. No additional network domains are required.

## Scope

- **In scope:** Path A (host settings mode) only. PulseAudio socket passthrough, generation-time socket detection, opt-in user prompt.
- **Out of scope:** Path B (isolated mode) — voice mode inherently depends on host audio hardware.

## Decisions

| Decision | Choice | Rationale |
|----------|--------|-----------|
| Opt-in | Ask during Phase 1 | Not every user has/wants audio; adds unnecessary packages and mounts for most workflows. |
| Path A only | No Path B support | Voice mode inherently depends on host audio hardware; isolation mode is out of scope. |
| Generation-time detection | Resolve socket path when skill runs | Simpler than runtime detection; consistent with user confirmation flow. |
| PulseAudio compat socket | Always use PulseAudio socket even on PipeWire | SoX speaks PulseAudio; PipeWire provides compat socket via pipewire-pulse. |
| Mount targets in /tmp | /tmp/pulse.socket, /tmp/pulse.cookie | Consistent with existing pattern (SSH agent at /tmp/ssh-agent.sock); env vars point to the actual path. |
| Full package set | sox, pulseaudio-utils, libportaudio2, libasound2-plugins, ffmpeg | Guarantees compatibility if Claude Code internals change; feature is opt-in so overhead is accepted. |
| No firewall changes | Voice traffic uses api.anthropic.com | Already in allowlist; PulseAudio socket is local. |

## Design

### Phase 1: Detection & User Prompt

During project analysis, after existing checks (Docker, superpowers plugin, DinD runners):

1. Ask: "Do you want voice mode support (audio passthrough for `/voice`)?"
2. If yes, detect audio socket in order:
   - Check `$XDG_RUNTIME_DIR/pulse/native` (PulseAudio, also created by PipeWire's pipewire-pulse).
   - Check `$XDG_RUNTIME_DIR/pipewire-0` as a signal that PipeWire is running, but still use the PulseAudio compat socket.
3. If found: confirm with user: "Found PulseAudio socket at `<path>`, using that."
4. If not found: warn and prompt with common locations using actual host UID:
   - `/run/user/$(id -u)/pulse/native`
   - `/run/user/$(id -u)/pipewire-0`
   - `/tmp/pulse-server`
   - Custom path
5. Validate the user-provided path exists before proceeding.

Regardless of whether PipeWire or PulseAudio is the host's native server, we always mount the PulseAudio-compatible socket since SoX speaks PulseAudio.

### Phase 2: Dockerfile Layer

A conditional audio package layer, following the same pattern as the Docker CLI layer:

```dockerfile
# Voice mode audio support (optional)
RUN apt-get update && apt-get install -y --no-install-recommends \
    sox \
    pulseaudio-utils \
    libportaudio2 \
    libasound2-plugins \
    ffmpeg \
    && rm -rf /var/lib/apt/lists/*
```

Plus PulseAudio client config to disable shared memory (required for socket passthrough):

```dockerfile
RUN mkdir -p /etc/pulse && \
    printf 'enable-shm = false\n' > /etc/pulse/client.conf
```

Key decisions:
- No Renovate annotations — distro packages pinned by base image.
- `--no-install-recommends` to keep it lean.
- Placed after system packages, before Claude Code install.
- No build-time deps (libasound2-dev, python3-dev) — not needed at runtime.
- `enable-shm = false` is required for PulseAudio over Unix socket in containers.

### Phase 3: devcontainer.json (Path A Only)

Add to mounts array (where the source path is the detected/confirmed path from Phase 1):

```json
"source=<detected_socket_path>,target=/tmp/pulse.socket,type=bind,readonly",
"source=${localEnv:HOME}/.config/pulse/cookie,target=/tmp/pulse.cookie,type=bind,readonly"
```

Where `<detected_socket_path>` is replaced with whatever Phase 1 detected/confirmed.

The cookie mount uses `${localEnv:HOME}/.config/pulse/cookie` which is the standard XDG location. On older systems the cookie may be at `~/.pulse-cookie` — Phase 1 detection should check both locations and use whichever exists. If no cookie file is found, omit the cookie mount and `PULSE_COOKIE` env var (PulseAudio may use anonymous auth).

No `runArgs` or capabilities are needed — PulseAudio socket passthrough works without elevated privileges.

Add to remoteEnv:

```json
"PULSE_SERVER": "unix:/tmp/pulse.socket",
"PULSE_COOKIE": "/tmp/pulse.cookie"
```

No `forwardPorts` needed — this is a Unix socket mount, not a TCP port.

### Phase 6: Task Runner Recipe

Follow existing conditional mount pattern (same as Docker socket):

```bash
# Voice mode audio (conditional)
if [ -S "<detected_socket_path>" ]; then
    run_args+=(-v "<detected_socket_path>:/tmp/pulse.socket:ro")
    run_args+=(-e "PULSE_SERVER=unix:/tmp/pulse.socket")
    if [ -f "${HOME}/.config/pulse/cookie" ]; then
        run_args+=(-v "${HOME}/.config/pulse/cookie:/tmp/pulse.cookie:ro")
        run_args+=(-e "PULSE_COOKIE=/tmp/pulse.cookie")
    elif [ -f "${HOME}/.pulse-cookie" ]; then
        run_args+=(-v "${HOME}/.pulse-cookie:/tmp/pulse.cookie:ro")
        run_args+=(-e "PULSE_COOKIE=/tmp/pulse.cookie")
    fi
fi
```

The detected path from Phase 1 is embedded in the recipe.

### Phase 7: Verification

Add voice mode verification to container test suite:

- `sox --version` — confirms SoX is installed.
- `pactl info` — confirms PulseAudio client can reach the host server through the socket.

`pactl info` is the real test — if it returns server info, the socket passthrough is working.

### SKILL.md Updates

The following SKILL.md sections need conditional additions:

- **Phase 1** (project analysis): Add voice mode opt-in prompt after Docker/Compose detection. Detect PulseAudio socket path.
- **Phase 2** (Dockerfile): Add conditional audio package layer when voice mode is enabled.
- **Phase 3** (devcontainer.json): Add note for Path A — when voice mode enabled, add socket/cookie mounts and `PULSE_SERVER`/`PULSE_COOKIE` env vars.
- **Phase 6** (task runner): Add note — when voice mode enabled, add conditional socket mount and env vars.
- **Phase 7** (verification): Add voice mode verification checklist items.

### Reference File Updates

**New file — `references/voice-mode.md`:**
- Detection logic (PulseAudio socket, PipeWire compat).
- Dockerfile layer (packages, client.conf).
- devcontainer.json additions (mounts, remoteEnv).
- Task runner mounts and env vars.
- Verification commands.

**`references/devcontainer-json.md`:**
- Add voice mode mounts/env vars section under Path A documentation.

**`references/task-runner.md`:**
- Add voice mode conditional mount pattern.

**`references/common-mistakes.md`:**
- Add: "Forgetting `enable-shm = false` in `/etc/pulse/client.conf` — PulseAudio over Unix socket in containers requires shared memory to be disabled."
- Add: "Mounting the PipeWire native socket (`pipewire-0`) instead of the PulseAudio compatibility socket (`pulse/native`) — SoX speaks PulseAudio, not PipeWire natively."

## Technical Context

The voice mode pipeline:
- SoX (`rec`) captures audio via PulseAudio.
- Audio is pre-processed locally (noise reduction, compression).
- Compressed tokens are sent through the existing `api.anthropic.com` endpoint.
- STT-only — no TTS, no speaker output needed.
- PulseAudio socket is a local Unix socket — no network traffic involved.

PipeWire compatibility:
- PipeWire hosts run `pipewire-pulse` which creates a PulseAudio-compatible socket at the same path (`$XDG_RUNTIME_DIR/pulse/native`).
- We always mount this PulseAudio compat socket regardless of whether the host runs native PulseAudio or PipeWire.

## No Changes Required

- **`references/firewall.md`** — voice traffic uses `api.anthropic.com` (already in allowlist). PulseAudio socket is a local Unix socket with no network traffic.
- **`references/docker-support.md`** — unrelated to Docker socket forwarding.
