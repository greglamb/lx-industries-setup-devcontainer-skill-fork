# Visual Companion Port Forwarding — Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add superpowers visual companion port forwarding support to the devcontainer skill.

**Architecture:** Cross-cutting feature layered into existing phases. Detection in Phase 1, devcontainer.json additions in Phase 3, task runner additions in Phase 6, verification in Phase 7. Reference files updated for patterns and anti-patterns.

**Design:** [wiki:plans/2026-03-11-visual-companion-port-forwarding](../wikis/plans/2026-03-11-visual-companion-port-forwarding)

---

### Task 1: Update `SKILL.md` — Phase 1 superpowers detection

**Files:**
- Modify: `SKILL.md`

**Step 1: Add superpowers detection step**

After step 5 ("Detect DinD runners", line 72) and before step 6 ("Present findings", line 74), insert a new step 6 and renumber the existing step 6 to step 7:

```markdown
**6. Check for superpowers plugin (Path A only):**

If the user chose Path A (host settings) and `~/.claude/settings.json` is readable, check whether `enabledPlugins` contains `"superpowers@claude-plugins-official": true`.

If found, note it for Phase 3 — the brainstorming visual companion needs port forwarding to be reachable from the host browser.
```

**Step 2: Verify**

Run: `grep -c "superpowers" SKILL.md`
Expected: at least 1

**Step 3: Commit**

```bash
git add SKILL.md
git commit -m "feat(skill): add superpowers detection to Phase 1"
```

---

### Task 2: Update `SKILL.md` — Phase 3 visual companion additions

**Files:**
- Modify: `SKILL.md`

**Step 1: Add visual companion note to Phase 3**

After line 102 (the Docker socket note ending with "no `runArgs` needed"), add:

```markdown
If superpowers was detected in Phase 1 (Path A only), propose visual companion port forwarding:

> "Superpowers visual companion needs a forwarded port to display in your host browser. Suggested port: 19452. Use a different one?"

Add `forwardPorts`, `portsAttributes` (label: "Brainstorm Companion", onAutoForward: "silent"), and `remoteEnv` entries for `BRAINSTORM_PORT` (with `${localEnv:BRAINSTORM_PORT:19452}` fallback), `BRAINSTORM_HOST` (`0.0.0.0`), and `BRAINSTORM_URL_HOST` (`localhost`). See [references/devcontainer-json.md](references/devcontainer-json.md) for the full snippet.
```

**Step 2: Commit**

```bash
git add SKILL.md
git commit -m "feat(skill): add visual companion port forwarding to Phase 3"
```

---

### Task 3: Update `SKILL.md` — Phase 6 task runner additions

**Files:**
- Modify: `SKILL.md`

**Step 1: Add visual companion note to Phase 6**

After line 177 (the Docker socket note), add:

```markdown
If superpowers was detected in Phase 1, add `BRAINSTORM_PORT` variable with env override (default: 19452) and publish the port with `-p` and `-e` flags for `BRAINSTORM_PORT`, `BRAINSTORM_HOST`, and `BRAINSTORM_URL_HOST`. See [references/task-runner.md](references/task-runner.md) for the recipe additions.
```

**Step 2: Commit**

```bash
git add SKILL.md
git commit -m "feat(skill): add visual companion to Phase 6 task runner"
```

---

### Task 4: Update `SKILL.md` — Phase 7 verification

**Files:**
- Modify: `SKILL.md`

**Step 1: Add visual companion verification**

After the Docker verification block (line 205) and before the Firewall verification block (line 207), insert:

```markdown
**Superpowers visual companion verification (Path A with superpowers only):**
- [ ] `echo $BRAINSTORM_PORT` — env var is set (default: 19452)
- [ ] `echo $BRAINSTORM_HOST` — is `0.0.0.0`
- [ ] Port mapping exists (IDE: implicit via `forwardPorts`; CLI: confirm with `docker port`)
```

**Step 2: Commit**

```bash
git add SKILL.md
git commit -m "feat(skill): add visual companion verification to Phase 7"
```

---

### Task 5: Update `references/devcontainer-json.md` — visual companion section

**Files:**
- Modify: `references/devcontainer-json.md`

**Step 1: Add visual companion section under Path A**

After line 38 (the dual mount explanation paragraph), before the "## Path B" heading (line 40), insert:

```markdown
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
```

**Step 2: Verify**

Run: `grep -c "BRAINSTORM" references/devcontainer-json.md`
Expected: at least 4

**Step 3: Commit**

```bash
git add references/devcontainer-json.md
git commit -m "docs(references): add visual companion section to devcontainer-json.md"
```

---

### Task 6: Update `references/task-runner.md` — BRAINSTORM_PORT variable and flags

**Files:**
- Modify: `references/task-runner.md`

**Step 1: Add BRAINSTORM_PORT variable to recipe**

In the example recipe structure (line 28), after the existing variable declarations and before the `[positional-arguments]` line (line 31), add:

```just
BRAINSTORM_PORT := env("BRAINSTORM_PORT", "19452")
```

**Step 2: Add port flags to the recipe body**

After the Docker socket conditional block (line 70, ending with `fi`), add:

```bash
    # Visual companion port (superpowers brainstorming)
    run_args+=(-p "${BRAINSTORM_PORT}:${BRAINSTORM_PORT}")
    run_args+=(-e "BRAINSTORM_PORT=${BRAINSTORM_PORT}")
    run_args+=(-e "BRAINSTORM_HOST=0.0.0.0")
    run_args+=(-e "BRAINSTORM_URL_HOST=localhost")
```

**Step 3: Add key design point**

In the "Key design points" section (after line 86, the Docker socket point), add:

```markdown
- **Visual companion port** — publishes `BRAINSTORM_PORT` (default 19452, overridable via host env var) so the superpowers brainstorming companion is reachable from the host browser. Also sets `BRAINSTORM_HOST=0.0.0.0` (bind to all interfaces) and `BRAINSTORM_URL_HOST=localhost` (correct hostname in printed URL). Only added when superpowers is detected in Phase 1.
```

**Step 4: Commit**

```bash
git add references/task-runner.md
git commit -m "docs(references): add visual companion port to task-runner.md"
```

---

### Task 7: Update `references/common-mistakes.md` — visual companion anti-patterns

**Files:**
- Modify: `references/common-mistakes.md`

**Step 1: Add mistakes to the table**

After line 45 (last Docker-related mistake row), add:

```markdown
| Hardcoding `BRAINSTORM_PORT` without env override | Use `${localEnv:BRAINSTORM_PORT:19452}` in devcontainer.json and `env("BRAINSTORM_PORT", "19452")` in task runner |
| Not setting `BRAINSTORM_HOST=0.0.0.0` for visual companion | The companion binds to `127.0.0.1` by default — unreachable from outside the container |
| Setting `BRAINSTORM_HOST=0.0.0.0` without `BRAINSTORM_URL_HOST=localhost` | The printed URL shows `0.0.0.0` which confuses users — set `BRAINSTORM_URL_HOST=localhost` |
```

**Step 2: Add to red flags**

In the "Never" section (after line 58), add:

```markdown
- Hardcode `BRAINSTORM_PORT` without allowing env override — the user may need a different port
```

In the "Always" section (after line 71), add:

```markdown
- Set `BRAINSTORM_HOST=0.0.0.0` and `BRAINSTORM_URL_HOST=localhost` alongside `BRAINSTORM_PORT` when configuring the visual companion
```

**Step 3: Commit**

```bash
git add references/common-mistakes.md
git commit -m "docs(references): add visual companion anti-patterns to common-mistakes.md"
```
