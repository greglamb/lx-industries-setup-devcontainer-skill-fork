# setup-devcontainer

An [Agent Skill](https://agentskills.io) that generates hardened `.devcontainer/` setups for [Claude Code](https://claude.ai/code) autonomous mode and IDE use (VS Code, JetBrains, DevPod, devcontainer CLI).

## Mirror Fork Note

You can install from this repository via:

```bash
npx skills add https://github.com/greglamb/lx-industries-setup-devcontainer-skill-fork -a claude-code -s setup-devcontainer -y
```

## What it does

When triggered, the skill analyzes your project and generates a complete [Dev Container](https://containers.dev/) configuration tailored to your toolchain. It handles the hard parts that generic devcontainer templates miss:

- **CI image reuse** — detects existing CI container images and uses them as base images via multi-stage build, keeping your dev environment in sync with CI
- **Dependency pinning** — every image uses `tag@sha256:digest`, every versioned tool gets a [Renovate](https://github.com/renovatebot/renovate) annotation for automated updates
- **Arbitrary UID support** — works with `--user $(id -u):$(id -g)` out of the box (passwd injection, sticky-bit permissions)
- **Git worktree compatibility** — mounts the project at its host-native path, no `WORKDIR`
- **SSH agent forwarding** — bind-mounts the host SSH agent socket, no raw key files
- **Claude Code integration** — native binary install, dual `~/.claude` mount workaround for plugin paths, `~/.claude.json` for preferences
- **NPM supply-chain hardening** — blocks postinstall scripts and enforces 24h package age
- **Docker CLI + Compose** — optional host socket mount with automatic GID handling for both IDE and CLI paths
- **Voice mode audio** — optional PulseAudio socket passthrough so Claude Code's `/voice` command works inside the container
- **Optional network firewall** — iptables egress filter with domain allowlist for sandboxed autonomous mode
- **Task runner integration** — wraps the `docker run` invocation in a `just`/`make`/`task` recipe with `--firewall` flag
- **CI validation** — schema validation and build verification jobs triggered on `.devcontainer/` changes

## Installation

Add the skill to your Claude Code configuration. You can install it at user level (available in all projects) or project level.

**User-level** (recommended):

```bash
claude skill add --global https://gitlab.com/lx-industries/setup-devcontainer-skill
```

**Project-level** (shared with team via `.claude/skills/`):

```bash
claude skill add https://gitlab.com/lx-industries/setup-devcontainer-skill
```

Or manually clone/copy the `SKILL.md` and `references/` directory into `.claude/skills/setup-devcontainer/`.

## Usage

Ask Claude Code to set up a dev container. Any of these will trigger the skill:

- "set up a devcontainer"
- "containerize development for this project"
- "run Claude in a container"

The skill walks through 7 phases interactively, asking for your input at key decision points:

1. **Project Analysis** — identifies language, package managers, CI images, task runner
2. **Dockerfile** — generates a hardened Dockerfile with entrypoint
3. **devcontainer.json** — asks whether to share host Claude settings or start isolated
4. **CI Validation** — adds schema validation and build verification jobs
5. **Network Firewall** *(optional)* — asks if you need sandboxed mode, generates iptables egress filter
6. **Task Runner** — detects your task runner and offers to add a launch recipe
7. **Testing** — runs verification checklist inside the built container

## Firewall mode

The optional network firewall restricts all outbound traffic to an explicit domain allowlist. Domains are resolved to IPs at container start using `ipset`. The firewall self-tests by verifying that unlisted domains are blocked.

```bash
# Normal mode — full internet access
just dev-shell

# Firewalled mode — egress restricted to allowlisted domains
just dev-shell --firewall claude
```

The allowlist is auto-populated from your project's package registries and forge, plus Claude API endpoints, GitHub (Claude Code distribution), and npm (MCP server installs).

## Requirements

- Docker
- Bash

## File structure

```
SKILL.md                         # Main skill definition
references/
  dockerfile.md                  # Dockerfile patterns and entrypoint
  devcontainer-json.md           # devcontainer.json for host and isolated modes
  firewall.md                    # Network firewall implementation
  task-runner.md                 # Task runner recipe with --firewall flag
  docker-support.md              # Docker CLI + Compose socket mount
  voice-mode.md                  # Voice mode PulseAudio passthrough
  common-mistakes.md             # Common mistakes and red flags
```

## License

[MIT](https://opensource.org/licenses/MIT)
