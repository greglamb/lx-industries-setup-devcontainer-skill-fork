# Phase 6: Task Runner Integration

The `docker run` invocation for the devcontainer is long (build, UID mapping, conditional mounts, TTY detection). Rather than expecting users to remember or copy-paste raw docker commands, **wrap the launch in a task runner recipe** so the entry point is a single short command (e.g., `just dev-shell`, `make dev-shell`, `task dev-shell`).

If Phase 5 (firewall) was configured, also add a `--firewall` flag that enables the firewall. Without the flag, the container runs in normal mode with full internet access.

## Detection

Check for these files at the project root:

| File | Tool |
|------|------|
| `justfile` / `.justfile` | [just](https://github.com/casey/just) |
| `Makefile` / `GNUmakefile` | make |
| `Taskfile.yml` | [Task](https://taskfile.dev/) |
| `package.json` (with `scripts`) | npm/yarn/pnpm |

If a task runner is found, **ask the user** whether they want devcontainer recipes added to it. Don't add them silently — the user owns the task runner's structure and naming conventions.

## What the recipes should do

1. **Build the image if stale** — rebuild when any file in `.devcontainer/` is newer than the image. `just` and `make` have built-in file-based staleness checks; for others, use a timestamp sentinel file or always build (docker layer caching makes this fast).
2. **Conditional mounts** — only add `-v` flags for host configs that actually exist (`~/.gitconfig`, `~/.config/glab-cli`, `~/.claude`, etc.). This avoids Docker creating empty root-owned directories for missing sources.
3. **Pass-through arguments** — let the user specify what to run inside the container (e.g., `just dev-shell claude`, `just dev-shell bash`, `just dev-shell cargo test`). Default to an interactive shell.

## Example recipe structure (adapt to the project's task runner)

```just
# Launch an interactive devcontainer shell (e.g. `just dev-shell`, `just dev-shell claude`)
# Add --firewall for network-firewalled autonomous mode.
[positional-arguments]
dev-shell *args:
    #!/usr/bin/env bash
    set -euo pipefail
    docker build -t <project>-devcontainer .devcontainer/
    tty_flag=$( [[ -t 0 ]] && echo "-it" || echo "-i" )
    run_args=(
        --rm $tty_flag --init
        -v "$(pwd):$(pwd)" -w "$(pwd)"
        -v "$SSH_AUTH_SOCK:/tmp/ssh-agent.sock"
        -e SSH_AUTH_SOCK=/tmp/ssh-agent.sock
        -e COLORTERM="${COLORTERM:-}"
        -e DEVCONTAINER_WORKSPACE="$(pwd)"
    )
    # Firewalled mode: iptables egress filter + run as root then drop privileges via gosu
    # Normal mode: run directly as host UID (no firewall, no caps)
    if [[ "${1:-}" = "--firewall" ]]; then
        shift
        run_args+=(
            --cap-add=NET_ADMIN --cap-add=NET_RAW
            -e DEVCONTAINER_FIREWALL=1
            -e DEVCONTAINER_UID="$(id -u)"
            -e DEVCONTAINER_GID="$(id -g)"
        )
    else
        run_args+=(--user "$(id -u):$(id -g)")
    fi
    # Conditional host config mounts
    [[ -f "$HOME/.gitconfig" ]] && run_args+=(-v "$HOME/.gitconfig:/tmp/home/.gitconfig:ro")
    [[ -d "$HOME/.config/<forge-cli>" ]] && run_args+=(-v "$HOME/.config/<forge-cli>:/tmp/<forge>-config")
    [[ -d "$HOME/.claude" ]] && run_args+=(
        -v "$HOME/.claude:/tmp/home/.claude"
        -v "$HOME/.claude:$HOME/.claude"
    )
    [[ -f "$HOME/.claude.json" ]] && run_args+=(-v "$HOME/.claude.json:/tmp/home/.claude.json")
    if [[ $# -eq 0 ]]; then
        exec docker run "${run_args[@]}" <project>-devcontainer bash
    else
        exec docker run "${run_args[@]}" <project>-devcontainer "$@"
    fi
```

## Key design points

- **`[positional-arguments]`** — required for `just` shebang recipes so `$@` receives the arguments (without it, `$@` is always empty and only `{{ args }}` works, but that breaks shell quoting)
- **TTY detection** — uses `-it` when stdin is a terminal, `-i` only otherwise (avoids "not a TTY" errors in CI/scripts)
- **No subcommands or flags for mount selection** — auto-detect what exists on the host
- **Single entry point** — one recipe, not separate `dev-shell-isolated` / `dev-shell-full` recipes. The conditional mounts handle both cases naturally.
- **`--firewall` flag** — opt-in firewall mode. Without it, the container runs as the host UID with full internet access (normal development). With it, the container starts as root with `NET_ADMIN`/`NET_RAW`, the entrypoint runs the firewall, then drops to the host UID via `gosu`. Usage: `just dev-shell --firewall claude` for firewalled autonomous mode.
- **`DEVCONTAINER_WORKSPACE`** — passed to the entrypoint so it knows which directory to `stat` for workspace owner inference. Redundant in normal mode (the entrypoint doesn't need it when not root), but consistent with devcontainer.json's `containerEnv` and useful if the recipe is adapted for root-based modes.
