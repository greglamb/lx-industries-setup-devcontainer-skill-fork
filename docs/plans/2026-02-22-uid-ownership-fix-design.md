# Fix UID/Ownership Mismatch Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Ensure all devcontainer entry points (Zed, VS Code, `just dev-shell`, `just dev-shell --firewall`) converge to the same host UID, preventing file ownership conflicts on shared bind mounts.

**Architecture:** Create a non-root `dev` user (UID 1000) in the Dockerfile for the devcontainer spec's `updateRemoteUserUID` mechanism. Extend the entrypoint to detect when running as root without an explicit UID and infer the target from the workspace directory owner. Add `containerUser`, `remoteUser`, and `DEVCONTAINER_WORKSPACE` to devcontainer.json. Update all skill reference templates.

**Tech Stack:** Dockerfile, bash (entrypoint.sh), devcontainer.json, justfile

---

### Task 1: Add non-root user to Dockerfile

**Files:**
- Modify: `.devcontainer/Dockerfile:55-56` (before the permissions section)

**Step 1: Add user creation before permissions block**

In `.devcontainer/Dockerfile`, insert the user creation immediately before the `# -- Permissions` comment (line 55). The `useradd --create-home` is redundant since `/tmp/home` already exists, but `--home-dir` still sets the passwd entry correctly:

```dockerfile
# -- Non-root user (for remoteUser + updateRemoteUserUID) --------------------
# IDEs that support the devcontainer spec remap this UID to match the host.
# IDEs that don't (Zed) rely on the entrypoint to detect and drop to the
# workspace owner UID via gosu.
RUN groupadd --gid 1000 dev \
 && useradd --uid 1000 --gid 1000 --no-create-home --home-dir /tmp/home --shell /bin/bash dev
```

The full Dockerfile permissions section stays as-is (`chmod -R 1777 /tmp/home` and `chmod 0666 /etc/passwd`).

**Step 2: Build image to verify**

Run:
```bash
docker build -t setup-devcontainer-skill-devcontainer .devcontainer/
```
Expected: Build succeeds.

**Step 3: Verify user exists in image**

Run:
```bash
docker run --rm setup-devcontainer-skill-devcontainer grep dev /etc/passwd
```
Expected: `dev:x:1000:1000:dev:/tmp/home:/bin/bash`

**Step 4: Commit**

```bash
git add .devcontainer/Dockerfile
git commit -m "feat(devcontainer): add non-root dev user for updateRemoteUserUID"
```

---

### Task 2: Rewrite entrypoint for 4 execution paths

**Files:**
- Modify: `.devcontainer/entrypoint.sh` (full rewrite)

**Step 1: Write the new entrypoint**

Replace `.devcontainer/entrypoint.sh` with:

```bash
#!/bin/bash

# -- Resolve target UID/GID ---------------------------------------------------
# Priority:
#   1. DEVCONTAINER_UID/GID env vars (firewalled mode — explicit)
#   2. Workspace directory owner (IDE started as root without explicit UID)
#   3. Current UID (normal mode — --user already set the UID)

target_uid="${DEVCONTAINER_UID:-$(id -u)}"
target_gid="${DEVCONTAINER_GID:-$(id -g)}"

# If running as root without explicit UID, infer from workspace owner.
# Handles IDEs like Zed that ignore remoteUser and start as root.
if [[ "$(id -u)" = "0" ]] && [[ -z "${DEVCONTAINER_UID:-}" ]]; then
    workspace="${DEVCONTAINER_WORKSPACE:-$(pwd)}"
    if [[ -d "$workspace" ]]; then
        target_uid="$(stat -c '%u' "$workspace")"
        target_gid="$(stat -c '%g' "$workspace")"
    fi
fi

# -- Inject passwd entry for the target UID ------------------------------------
if ! getent passwd "$target_uid" >/dev/null 2>&1; then
    echo "dev:x:${target_uid}:${target_gid}:dev:${HOME}:/bin/bash" >> /etc/passwd
fi

# -- Firewall (firewalled mode only) -------------------------------------------
# Requires: root, NET_ADMIN capability, DEVCONTAINER_FIREWALL=1
if [[ "${DEVCONTAINER_FIREWALL:-}" = "1" ]] && [[ "$(id -u)" = "0" ]]; then
    /usr/local/bin/firewall.sh
    # Snapshot allowed IPs before privilege drop (ipset needs NET_ADMIN)
    ipset list allowed-domains | grep -E '^[0-9]' > /tmp/firewall-allowed-ips.txt 2>/dev/null || true
fi

# -- Drop privileges if running as root with a non-root target ----------------
if [[ "$(id -u)" = "0" ]] && [[ "${target_uid}" != "0" ]]; then
    exec gosu "${target_uid}:${target_gid}" "$@"
fi

exec "$@"
```

Key changes from the current entrypoint:
- **New block** (lines 12-18): workspace owner inference when root + no explicit UID
- **Changed gosu condition** (last if-block): was `[[ -n "${DEVCONTAINER_UID:-}" ]]`, now `[[ "${target_uid}" != "0" ]]` — triggers for both explicit UID (firewall) and inferred UID (Zed)

**Step 2: Verify normal mode (host UID via --user)**

Run:
```bash
docker run --rm --user "$(id -u):$(id -g)" \
  -v "$(pwd):$(pwd)" -w "$(pwd)" \
  setup-devcontainer-skill-devcontainer id
```
Expected: `uid=<your-uid>(dev) gid=<your-gid> groups=<your-gid>`

**Step 3: Verify root-without-UID mode (Zed simulation)**

Run:
```bash
docker run --rm \
  -v "$(pwd):$(pwd)" -w "$(pwd)" \
  setup-devcontainer-skill-devcontainer id
```
Expected: `uid=<your-uid>(dev) gid=<your-gid>` (NOT root) — entrypoint detected workspace owner and dropped via gosu.

**Step 4: Verify firewalled mode still works**

Run:
```bash
docker run --rm \
  --cap-add=NET_ADMIN --cap-add=NET_RAW \
  -e DEVCONTAINER_FIREWALL=1 \
  -e DEVCONTAINER_UID="$(id -u)" \
  -e DEVCONTAINER_GID="$(id -g)" \
  -v "$(pwd):$(pwd)" -w "$(pwd)" \
  setup-devcontainer-skill-devcontainer id
```
Expected: `uid=<your-uid>(dev) gid=<your-gid>` + firewall output before it.

**Step 5: Commit**

```bash
git add .devcontainer/entrypoint.sh
git commit -m "feat(entrypoint): infer target UID from workspace owner when root"
```

---

### Task 3: Add user fields to devcontainer.json

**Files:**
- Modify: `.devcontainer/devcontainer.json`

**Step 1: Add containerUser, remoteUser, updateRemoteUserUID, and containerEnv**

The current file is:
```json
{
  "name": "setup-devcontainer-skill",
  "build": { "dockerfile": "Dockerfile" },
  "init": true,
  "workspaceFolder": "${localWorkspaceFolder}",
  "workspaceMount": "source=${localWorkspaceFolder},target=${localWorkspaceFolder},type=bind",
  "mounts": [ ... ],
  "remoteEnv": { ... }
}
```

Add these fields after `"init": true`:

```json
  "containerUser": "dev",
  "remoteUser": "dev",
  "updateRemoteUserUID": true,
```

Add `containerEnv` after `remoteEnv`:

```json
  "containerEnv": {
    "DEVCONTAINER_WORKSPACE": "${localWorkspaceFolder}"
  }
```

**Step 2: Validate JSON syntax**

Run:
```bash
python3 -c "import json; json.load(open('.devcontainer/devcontainer.json'))"
```
Expected: No output (valid JSON).

**Step 3: Commit**

```bash
git add .devcontainer/devcontainer.json
git commit -m "feat(devcontainer): add remoteUser + updateRemoteUserUID + DEVCONTAINER_WORKSPACE"
```

---

### Task 4: Add DEVCONTAINER_WORKSPACE to justfile

**Files:**
- Modify: `justfile:9-15` (run_args array)

**Step 1: Add DEVCONTAINER_WORKSPACE env var**

In the `run_args` array, add `-e DEVCONTAINER_WORKSPACE="$(pwd)"` alongside the other `-e` flags. Insert it after the `COLORTERM` line:

```bash
    run_args=(
        --rm $tty_flag --init
        -v "$(pwd):$(pwd)" -w "$(pwd)"
        -v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock"
        -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
        -e COLORTERM="${COLORTERM:-}"
        -e DEVCONTAINER_WORKSPACE="$(pwd)"
    )
```

**Step 2: Verify dev-shell still works**

Run:
```bash
just dev-shell id
```
Expected: `uid=<your-uid>(dev) gid=<your-gid>` — same as before, DEVCONTAINER_WORKSPACE is informational in normal mode.

**Step 3: Commit**

```bash
git add justfile
git commit -m "feat(justfile): pass DEVCONTAINER_WORKSPACE to entrypoint"
```

---

### Task 5: Integration test — all 4 execution paths

**Files:** None (verification only)

**Step 1: Rebuild image**

Run:
```bash
docker build -t setup-devcontainer-skill-devcontainer .devcontainer/
```

**Step 2: Test Path 1 — IDE with remoteUser (simulated)**

This path is handled by the devcontainer CLI remapping the UID before start. We can't fully simulate it without the CLI, but we can verify the user exists:

Run:
```bash
docker run --rm --user 1000:1000 \
  -v "$(pwd):$(pwd)" -w "$(pwd)" \
  setup-devcontainer-skill-devcontainer whoami
```
Expected: `dev`

**Step 3: Test Path 2 — IDE without remoteUser (Zed simulation)**

Run:
```bash
docker run --rm \
  -v "$(pwd):$(pwd)" -w "$(pwd)" \
  setup-devcontainer-skill-devcontainer bash -c 'echo "uid=$(id -u) whoami=$(whoami)"'
```
Expected: `uid=<your-host-uid> whoami=dev`

**Step 4: Test Path 3 — Normal dev-shell**

Run:
```bash
just dev-shell bash -c 'echo "uid=$(id -u) whoami=$(whoami)"'
```
Expected: `uid=<your-host-uid> whoami=dev`

**Step 5: Test Path 4 — Firewalled dev-shell**

Run:
```bash
just dev-shell --firewall bash -c 'echo "uid=$(id -u) whoami=$(whoami)"'
```
Expected: Firewall output lines, then `uid=<your-host-uid> whoami=dev`

**Step 6: Test ownership convergence**

Run:
```bash
# Create file as "Zed" (root → gosu drop)
docker run --rm \
  -v "$(pwd):$(pwd)" -w "$(pwd)" \
  setup-devcontainer-skill-devcontainer touch /tmp/test-zed-file

# Create file as "just dev-shell" (--user)
just dev-shell touch /tmp/test-devshell-file

# Compare ownership
docker run --rm \
  -v "$(pwd):$(pwd)" -w "$(pwd)" \
  setup-devcontainer-skill-devcontainer stat -c '%u:%g' /tmp/test-zed-file /tmp/test-devshell-file
```
Expected: Both show same UID:GID.

Note: This test uses /tmp inside the container which isn't bind-mounted, so it won't persist. For a real test, create files in the bind-mounted workspace. Adjust paths as needed — the key is that both UIDs match.

---

### Task 6: Update references/dockerfile.md

**Files:**
- Modify: `references/dockerfile.md:108-117` (between Permissions and Arbitrary UID sections)

**Step 1: Add non-root user section**

Insert a new section between `## Permissions` (line 108) and `## Arbitrary UID support` (line 118):

```markdown
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
```

**Step 2: Update the entrypoint section**

In the `## Arbitrary UID support` section, update the entrypoint example to include the workspace owner inference logic. Replace the current entrypoint code block with:

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

**Step 3: Commit**

```bash
git add references/dockerfile.md
git commit -m "docs(references): add non-root user and workspace UID inference to dockerfile.md"
```

---

### Task 7: Update references/devcontainer-json.md

**Files:**
- Modify: `references/devcontainer-json.md`

**Step 1: Add user fields to Path A template**

In the Path A JSON template, add after `"init": true`:

```json
  "containerUser": "dev",
  "remoteUser": "dev",
  "updateRemoteUserUID": true,
```

Add `containerEnv` after `remoteEnv`:

```json
  "containerEnv": {
    "DEVCONTAINER_WORKSPACE": "${localWorkspaceFolder}"
  }
```

**Step 2: Add user fields to Path B template**

Same additions to Path B.

**Step 3: Add explanation to Key decisions section**

Add a new bullet to `## Key decisions (both paths)`:

```markdown
- **`containerUser` / `remoteUser` / `updateRemoteUserUID`**: Creates the `dev` user in the Dockerfile (UID 1000). IDEs that support the devcontainer spec (VS Code, DevPod) remap UID 1000 to match the host UID automatically via `updateRemoteUserUID`. IDEs that don't support `remoteUser` (Zed — see [zed#46252](https://github.com/zed-industries/zed/issues/46252)) start as root; the entrypoint detects this and drops to the workspace owner UID via `gosu`. Both paths converge to the host UID.
- **`DEVCONTAINER_WORKSPACE`**: Tells the entrypoint which directory to `stat` for workspace owner inference. Falls back to `$(pwd)` if unset. Set explicitly for reliability — some IDEs may change the working directory before running the entrypoint.
```

**Step 4: Commit**

```bash
git add references/devcontainer-json.md
git commit -m "docs(references): add remoteUser and DEVCONTAINER_WORKSPACE to devcontainer-json.md"
```

---

### Task 8: Update references/firewall.md entrypoint section

**Files:**
- Modify: `references/firewall.md:175-210` (section 5.4)

**Step 1: Replace the entrypoint code block in section 5.4**

Replace the entrypoint code block with the full 4-path version from Task 2. Update the "How it works in each mode" explanation to cover all 4 paths:

```markdown
How it works in each mode:
- **Normal mode** (`--user $(id -u):$(id -g)`): Runs as host UID. Firewall skipped. Not root, so gosu skipped. Falls through to `exec "$@"`.
- **IDE without remoteUser** (Zed): Runs as root. `DEVCONTAINER_UID` unset, so infers target from workspace owner via `stat`. Firewall skipped (`DEVCONTAINER_FIREWALL` unset). Drops to workspace owner UID via `gosu`.
- **Firewalled mode** (root + `DEVCONTAINER_UID`): Runs as root. Uses explicit `DEVCONTAINER_UID`. Runs firewall. Drops to target UID via `gosu`.
- **IDE with remoteUser** (VS Code): `updateRemoteUserUID` remaps the `dev` user to host UID before container start. Runs as host UID. Entrypoint is a no-op (not root, no firewall).
```

**Step 2: Commit**

```bash
git add references/firewall.md
git commit -m "docs(references): update firewall.md entrypoint section with 4-path logic"
```

---

### Task 9: Update references/common-mistakes.md

**Files:**
- Modify: `references/common-mistakes.md`

**Step 1: Add new entries to the Common Mistakes table**

Add these rows to the table:

```markdown
| No `remoteUser` in devcontainer.json | Add `"containerUser": "dev"`, `"remoteUser": "dev"`, `"updateRemoteUserUID": true` — without these, IDEs run as root and file ownership diverges from CLI usage |
| Running as root without workspace UID inference | Entrypoint must detect root-without-explicit-UID and `stat` the workspace to infer the target UID — otherwise IDEs like Zed (which ignore `remoteUser`) create files owned by root |
| gosu condition only checks `DEVCONTAINER_UID` | Check `target_uid != 0` instead — gosu must also trigger when the target was inferred from the workspace owner, not just when explicitly set via env var |
| No `DEVCONTAINER_WORKSPACE` env var | Pass `DEVCONTAINER_WORKSPACE` in devcontainer.json (`containerEnv`) and task runner (`-e` flag) — the entrypoint falls back to `$(pwd)` but explicit is more reliable |
```

**Step 2: Add to the "Always" list**

Add to the **Always** section:

```markdown
- Set `containerUser`, `remoteUser`, and `updateRemoteUserUID` in devcontainer.json
- Test the container started as root without `--user` to verify the entrypoint drops to the workspace owner UID
```

**Step 3: Commit**

```bash
git add references/common-mistakes.md
git commit -m "docs(references): add UID ownership anti-patterns to common-mistakes.md"
```

---

### Task 10: Update references/task-runner.md

**Files:**
- Modify: `references/task-runner.md`

**Step 1: Add DEVCONTAINER_WORKSPACE to run_args in the recipe template**

In the example recipe structure, add `-e DEVCONTAINER_WORKSPACE="$(pwd)"` to the `run_args` array, after the `COLORTERM` line:

```bash
    run_args=(
        --rm $tty_flag --init
        -v "$(pwd):$(pwd)" -w "$(pwd)"
        -v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock"
        -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
        -e COLORTERM="${COLORTERM:-}"
        -e DEVCONTAINER_WORKSPACE="$(pwd)"
    )
```

**Step 2: Add to Key design points**

Add a new bullet:

```markdown
- **`DEVCONTAINER_WORKSPACE`** — passed to the entrypoint so it knows which directory to `stat` for workspace owner inference. Redundant in normal mode (the entrypoint doesn't need it when not root), but consistent with devcontainer.json's `containerEnv` and useful if the recipe is adapted for root-based modes.
```

**Step 3: Commit**

```bash
git add references/task-runner.md
git commit -m "docs(references): add DEVCONTAINER_WORKSPACE to task-runner.md recipe template"
```
