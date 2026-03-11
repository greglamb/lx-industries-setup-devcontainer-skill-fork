# Voice Mode Audio Passthrough (Optional)

Enable Claude Code's `/voice` command (STT via SoX) inside a devcontainer by mounting the host's PulseAudio socket. Voice mode is input-only (speech-to-text) — no speaker output needed. Transcription traffic goes through the existing `api.anthropic.com` endpoint.

**Scope:** Path A (host settings) only. Path B (isolated) is out of scope — voice mode depends on host audio hardware.

## Phase 1: Detection

Ask: "Do you want voice mode support (audio passthrough for `/voice`)?"

If yes, detect the host's PulseAudio socket:

1. Check `$XDG_RUNTIME_DIR/pulse/native` — works for both PulseAudio and PipeWire (via `pipewire-pulse` compat)
2. If found: confirm with user: "Found PulseAudio socket at `<path>`, using that."
3. If not found: warn and prompt with common locations:
   - `/run/user/$(id -u)/pulse/native` (PulseAudio, or PipeWire via `pipewire-pulse` compat)
   - `/tmp/pulse-server` (snap/flatpak setups)
   - Custom path
4. Validate the path exists before proceeding.

Also detect the PulseAudio cookie:

1. Check `$HOME/.config/pulse/cookie` (XDG standard)
2. Check `$HOME/.pulse-cookie` (legacy)
3. If neither exists, omit cookie mount — PulseAudio may use anonymous auth.

Always use the PulseAudio-compatible socket, even on PipeWire hosts. SoX speaks PulseAudio, not PipeWire natively.

## Phase 2: Dockerfile layer

Add after system packages, before Claude Code install:

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
- `--no-install-recommends` to avoid pulling in unnecessary dependencies.
- `enable-shm = false` is required — PulseAudio shared memory does not work across container boundaries.
- No build-time deps (`libasound2-dev`, `python3-dev`) — only runtime libraries needed.

## Phase 3: devcontainer.json (Path A only)

Add to the mounts array:

```json
"source=<detected_socket_path>,target=/tmp/pulse.socket,type=bind,readonly",
"source=<detected_cookie_path>,target=/tmp/pulse.cookie,type=bind,readonly"
```

Where `<detected_socket_path>` is the path confirmed in Phase 1 (e.g., `/run/user/1000/pulse/native`).
Where `<detected_cookie_path>` is the cookie found in Phase 1 (e.g., `${localEnv:HOME}/.config/pulse/cookie`). Omit the cookie mount if no cookie was found.

Add to `remoteEnv`:

```json
"PULSE_SERVER": "unix:/tmp/pulse.socket",
"PULSE_COOKIE": "/tmp/pulse.cookie"
```

Omit `PULSE_COOKIE` if no cookie was found.

No `forwardPorts`, `runArgs`, or capabilities needed — PulseAudio socket passthrough works without elevated privileges.

## Phase 6: Task runner recipe

Follow the conditional mount pattern (same as Docker socket):

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

The detected socket path from Phase 1 is embedded in the recipe.

## Phase 7: Verification

- `sox --version` — confirms SoX is installed
- `pactl info` — confirms PulseAudio client can reach the host server through the socket

`pactl info` is the real test. If it returns server info (name, version, default sink/source), the socket passthrough is working.

## Firewall

No changes needed. Voice traffic uses `api.anthropic.com` (already in allowlist). The PulseAudio socket is a local Unix socket — no network traffic involved. Loopback traffic is already allowed by the firewall rules.
