# Voice Mode Audio Passthrough — Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers:subagent-driven-development (if subagents available) or superpowers:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add opt-in PulseAudio socket passthrough so Claude Code's `/voice` command works inside generated devcontainers.

**Architecture:** Cross-cutting feature layered into existing phases, following the same pattern as Docker socket support. Opt-in prompt and socket detection in Phase 1, Dockerfile audio packages in Phase 2, devcontainer.json mounts in Phase 3 (Path A only), task runner conditional mounts in Phase 6, verification in Phase 7. New reference file for voice mode patterns; updates to existing references for integration points and anti-patterns.

**Design:** [wiki:plans/2026-03-11-voice-mode-audio-passthrough](../wikis/plans/2026-03-11-voice-mode-audio-passthrough)

---

### Task 1: Create `references/voice-mode.md`

**Files:**
- Create: `references/voice-mode.md`

- [ ] **Step 1: Write the reference file**

```markdown
# Voice Mode Audio Passthrough (Optional)

Enable Claude Code's `/voice` command (STT via SoX) inside a devcontainer by mounting the host's PulseAudio socket. Voice mode is input-only (speech-to-text) — no speaker output needed. Transcription traffic goes through the existing `api.anthropic.com` endpoint.

**Scope:** Path A (host settings) only. Path B (isolated) is out of scope — voice mode depends on host audio hardware.

## Phase 1: Detection

Ask: "Do you want voice mode support (audio passthrough for `/voice`)?"

If yes, detect the host's PulseAudio socket:

1. Check `$XDG_RUNTIME_DIR/pulse/native` — works for both PulseAudio and PipeWire (via `pipewire-pulse` compat)
2. If found: confirm with user: "Found PulseAudio socket at `<path>`, using that."
3. If not found: warn and prompt with common locations:
   - `/run/user/$(id -u)/pulse/native`
   - `/run/user/$(id -u)/pipewire-0`
   - `/tmp/pulse-server`
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
```

- [ ] **Step 2: Verify**

Run: `wc -l references/voice-mode.md`
Expected: ~95 lines

- [ ] **Step 3: Commit**

```bash
git add references/voice-mode.md
git commit -m "docs(references): add voice mode audio passthrough reference"
```

---

### Task 2: Update `SKILL.md` — Phase 1 voice mode prompt

**Files:**
- Modify: `SKILL.md:60-74`

- [ ] **Step 1: Add voice mode detection step**

After step 5 ("Detect DinD runners", ending at line 72) and before the "Present findings" step (line 74), insert a new step. If the superpowers detection step from the visual companion plan is already present, add after it. Otherwise add after step 5 and renumber accordingly:

```markdown
**N. Check for voice mode support (Path A only):**

Ask: "Do you want voice mode support (audio passthrough for `/voice`)?"

If yes, detect the host's PulseAudio socket (`$XDG_RUNTIME_DIR/pulse/native`) and cookie (`$HOME/.config/pulse/cookie` or `$HOME/.pulse-cookie`). If not found, prompt with common paths. Validate the socket exists. See [references/voice-mode.md](references/voice-mode.md) for full detection logic.
```

- [ ] **Step 2: Verify**

Run: `grep -c "voice mode" SKILL.md`
Expected: at least 1

- [ ] **Step 3: Commit**

```bash
git add SKILL.md
git commit -m "feat(skill): add voice mode opt-in prompt to Phase 1"
```

---

### Task 3: Update `SKILL.md` — Phase 2 voice mode Dockerfile layer

**Files:**
- Modify: `SKILL.md:76-89`

- [ ] **Step 1: Add voice mode note to Phase 2**

After line 89 (the Docker support note ending with "See [references/docker-support.md]..."), add:

```markdown
If voice mode was enabled in Phase 1, add the audio packages layer (sox, pulseaudio-utils, libportaudio2, libasound2-plugins, ffmpeg) and PulseAudio client config (`enable-shm = false`). See [references/voice-mode.md](references/voice-mode.md) for the Dockerfile layer.
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "feat(skill): add voice mode Dockerfile layer to Phase 2"
```

---

### Task 4: Update `SKILL.md` — Phase 3 voice mode mounts

**Files:**
- Modify: `SKILL.md:91-102`

- [ ] **Step 1: Add voice mode note to Phase 3**

After the Docker socket note (line 102) or after the visual companion note if already present, add:

```markdown
If voice mode was enabled in Phase 1 (Path A only), add the PulseAudio socket and cookie bind mounts (readonly) and `PULSE_SERVER`/`PULSE_COOKIE` env vars to `remoteEnv`. See [references/voice-mode.md](references/voice-mode.md) for the mount and env var configuration.
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "feat(skill): add voice mode mounts to Phase 3"
```

---

### Task 5: Update `SKILL.md` — Phase 6 voice mode task runner

**Files:**
- Modify: `SKILL.md:163-177`

- [ ] **Step 1: Add voice mode note to Phase 6**

After the Docker socket note (line 177) or after the visual companion note if already present, add:

```markdown
If voice mode was enabled in Phase 1, add a conditional PulseAudio socket mount with cookie detection to the task runner recipe. See [references/voice-mode.md](references/voice-mode.md) for the recipe additions.
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "feat(skill): add voice mode to Phase 6 task runner"
```

---

### Task 6: Update `SKILL.md` — Phase 7 voice mode verification

**Files:**
- Modify: `SKILL.md:179-215`

- [ ] **Step 1: Add voice mode verification block**

After the Docker verification block (line 205) or after the visual companion verification block if already present, and before the Firewall verification block (line 207), insert:

```markdown
**Voice mode verification (voice mode only):**
- [ ] `sox --version` — SoX is installed
- [ ] `pactl info` — PulseAudio client reaches host server through socket
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "feat(skill): add voice mode verification to Phase 7"
```

---

### Task 7: Update `references/devcontainer-json.md` — voice mode section

**Files:**
- Modify: `references/devcontainer-json.md:38-39`

- [ ] **Step 1: Add voice mode section under Path A**

After the dual mount explanation paragraph (line 38), and after the visual companion section if already present, before the "## Path B" heading (line 40), insert:

```markdown
### Voice mode audio passthrough (optional, Path A only)

When voice mode is enabled in Phase 1, mount the host's PulseAudio socket and cookie into the container so Claude Code's `/voice` command can capture audio.

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
```

- [ ] **Step 2: Verify**

Run: `grep -c "PULSE" references/devcontainer-json.md`
Expected: at least 3

- [ ] **Step 3: Commit**

```bash
git add references/devcontainer-json.md
git commit -m "docs(references): add voice mode section to devcontainer-json.md"
```

---

### Task 8: Update `references/task-runner.md` — voice mode conditional mounts

**Files:**
- Modify: `references/task-runner.md:66-86`

- [ ] **Step 1: Add voice mode block to recipe body**

After the Docker socket conditional block (line 70, ending with `fi`), or after the visual companion block if already present, add:

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

Where `<detected_socket_path>` is the path confirmed during Phase 1 (e.g., `/run/user/1000/pulse/native`).

- [ ] **Step 2: Add key design point**

In the "Key design points" section (after line 86, or after the visual companion point if already present), add:

```markdown
- **Voice mode audio** — conditional PulseAudio socket mount for Claude Code's `/voice` command. Checks socket existence at runtime (`-S`), then checks for cookie file at both XDG (`~/.config/pulse/cookie`) and legacy (`~/.pulse-cookie`) locations. All mounts are read-only. Only added when voice mode is enabled in Phase 1.
```

- [ ] **Step 3: Commit**

```bash
git add references/task-runner.md
git commit -m "docs(references): add voice mode mounts to task-runner.md"
```

---

### Task 9: Update `references/dockerfile.md` — voice mode layer

**Files:**
- Modify: `references/dockerfile.md:51-59`

- [ ] **Step 1: Add voice mode section after Docker CLI section**

After the "## Docker CLI + Compose (optional)" section (ending at line 59), add:

```markdown
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
```

- [ ] **Step 2: Commit**

```bash
git add references/dockerfile.md
git commit -m "docs(references): add voice mode Dockerfile layer to dockerfile.md"
```

---

### Task 10: Update `references/common-mistakes.md` — voice mode anti-patterns

**Files:**
- Modify: `references/common-mistakes.md:45-71`

- [ ] **Step 1: Add mistakes to the table**

After the last Docker/visual-companion-related mistake row (line 45, or after visual companion rows if already present), add:

```markdown
| Forgetting `enable-shm = false` in `/etc/pulse/client.conf` | PulseAudio shared memory does not work across container boundaries — socket passthrough requires `enable-shm = false` |
| Mounting PipeWire native socket (`pipewire-0`) instead of PulseAudio compat socket (`pulse/native`) | SoX speaks PulseAudio, not PipeWire — use the PulseAudio compat socket (created by `pipewire-pulse` on PipeWire hosts) |
| Mounting PulseAudio cookie unconditionally | Check for cookie at both `~/.config/pulse/cookie` (XDG) and `~/.pulse-cookie` (legacy) — omit mount if neither exists (anonymous auth) |
| Hardcoding `/run/user/1000/` for PulseAudio socket | Use `$XDG_RUNTIME_DIR/pulse/native` for detection; fall back to prompted path with `$(id -u)` hints |
```

- [ ] **Step 2: Add to red flags**

In the "Never" section (after line 58, or after visual companion entry if already present), add:

```markdown
- Mount `/dev/snd` for container audio — use PulseAudio socket passthrough instead (avoids exclusive device access and host conflicts)
```

In the "Always" section (after line 71, or after visual companion entry if already present), add:

```markdown
- Set `enable-shm = false` in `/etc/pulse/client.conf` when mounting PulseAudio socket into a container
- Use the PulseAudio-compatible socket (`pulse/native`) even on PipeWire hosts — SoX speaks PulseAudio
```

- [ ] **Step 3: Commit**

```bash
git add references/common-mistakes.md
git commit -m "docs(references): add voice mode anti-patterns to common-mistakes.md"
```

---

### Task 11: Update `SKILL.md` — Reference section

**Files:**
- Modify: `SKILL.md:217-227`

- [ ] **Step 1: Add voice mode reference link**

In the Reference section (line 217), after the Docker support entry (line 226), add:

```markdown
- **[references/voice-mode.md](references/voice-mode.md)** — Voice mode audio: PulseAudio socket detection, Dockerfile layer, mounts, task runner recipe, verification
```

- [ ] **Step 2: Commit**

```bash
git add SKILL.md
git commit -m "feat(skill): add voice mode reference link"
```
