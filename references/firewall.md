# Phase 5: Network Firewall (Optional)

**Ask the user:** will this container be used for autonomous/sandbox mode (`--dangerously-skip-permissions`)? If not, skip this phase entirely — the firewall blocks all outbound traffic except to explicitly allowed domains, which breaks normal development (browsing docs, installing new packages, accessing internal services).

If yes, generate three files and modify the existing Dockerfile and entrypoint.

## 5.1 Allowlist file

Create `.devcontainer/firewall-allowlist.txt` with domains auto-detected from Phase 1:

```
# Allowed outbound domains — one per line, comments start with #.
# The firewall resolves these to IPs at container start and blocks everything else.

# Claude API (Claude Code only — omit when only opencode is selected)
api.anthropic.com
statsig.anthropic.com
sentry.io

# Claude Code distribution (Claude Code only — omit when only opencode is selected and forge is not GitHub)
github.com
api.github.com

# Package registries (auto-detected from Phase 1)
registry.npmjs.org

# Project forge (auto-detected from Phase 1)
gitlab.com
```

Populate package registries from the package managers detected in Phase 1. Common mappings:

| Package manager | Registry domain(s) |
|---|---|
| npm / yarn / pnpm | `registry.npmjs.org` |
| cargo | `crates.io`, `static.crates.io`, `index.crates.io` |
| pip / uv | `pypi.org`, `files.pythonhosted.org` |
| go | `proxy.golang.org`, `sum.golang.org` |
| composer | `repo.packagist.org`, `packagist.org` |
| maven / gradle | `repo1.maven.org` |
| rubygems | `rubygems.org` |
| docker (Docker Hub) | `registry-1.docker.io`, `auth.docker.io`, `production.cloudflare.docker.com` |

### opencode LLM provider domains (conditional on opencode selected)

When opencode is selected and the firewall is enabled, ask the user which LLM provider(s) they will use, then add the corresponding API domains to the allowlist:

| Provider | Domain(s) |
|----------|-----------|
| Anthropic | `api.anthropic.com` |
| OpenAI | `api.openai.com` |
| Google Gemini | `generativelanguage.googleapis.com` |
| Google Vertex AI | `*-aiplatform.googleapis.com` |
| AWS Bedrock | `bedrock-runtime.*.amazonaws.com` |
| Azure OpenAI | `*.openai.azure.com` |
| Groq | `api.groq.com` |
| OpenRouter | `openrouter.ai` |
| GitHub Copilot | `api.github.com`, `api.githubcopilot.com` |
| OpenCode Zen/Go | `opencode.ai` |

If both tools are selected and the user picks Anthropic for opencode, `api.anthropic.com` is already in the allowlist from Claude Code — no duplication needed.

Wildcard domains (e.g., `*-aiplatform.googleapis.com`) must be resolved to the specific subdomain the user's project uses (e.g., `us-central1-aiplatform.googleapis.com`) because the firewall resolves domains to IPs at startup — wildcards are not supported by `dig`.

When Kubernetes tooling is detected, add the Kubernetes API server domain(s) from the kubeconfig. Parse `~/.kube/config` for `server:` entries and extract the hostnames. Common patterns:
- GKE: `*.gke.goog` or direct IP addresses
- EKS: `*.eks.amazonaws.com`
- AKS: `*.azmk8s.io`
- Self-hosted: project-specific hostnames

Also add Helm chart repository domains if the project uses custom Helm repos (check `repositories:` in `helmfile.yaml` or output of `helm repo list`). Do **not** hardcode cloud-specific domains — always extract from the actual kubeconfig and project configuration.

When Docker support is enabled, also scan `FROM` directives in project Dockerfiles and `image:` fields in compose files to detect additional registries (GHCR, GitLab, GCR, GAR, ECR). See [docker-support.md](docker-support.md) for the full registry detection table.

Include `registry.npmjs.org` when Claude Code is selected (it runs `npm install` for MCP servers at runtime) or when the project itself uses npm. When only opencode is selected and the project doesn't use npm, this entry can be omitted — opencode uses bun for plugin management.

Include `github.com` and `api.github.com` when Claude Code is selected (it connects to GitHub for distribution and updates) or when the project forge is GitHub. When only opencode is selected and the forge is not GitHub, these entries can be omitted — opencode installs from `opencode.ai`.

## 5.2 Firewall script

Create `.devcontainer/firewall.sh`:

```bash
#!/bin/bash
set -euo pipefail

# Network egress firewall — blocks all outbound traffic except to domains
# listed in firewall-allowlist.txt. Run as root with NET_ADMIN capability.
#
# Domain IPs are resolved once at container start. If CDN IPs rotate during
# a long-running session, restart the container to re-resolve.

ALLOWLIST_FILE="${ALLOWLIST_FILE:-/usr/local/share/firewall-allowlist.txt}"

# -- Preserve Docker internal DNS before flushing ----------------------------
docker_dns_rules=$(iptables-save | grep -E '127\.0\.0\.11' || true)

# -- Flush all rules ----------------------------------------------------------
iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X

# -- Restore Docker DNS -------------------------------------------------------
if [[ -n "$docker_dns_rules" ]]; then
    echo "$docker_dns_rules" | iptables-restore --noflush
fi

# -- Build ipset from allowlist -----------------------------------------------
ipset create allowed-domains hash:net -exist
ipset flush allowed-domains

while IFS= read -r line; do
    # Strip comments and whitespace
    domain="${line%%#*}"
    domain="${domain// /}"
    [[ -z "$domain" ]] && continue

    # Resolve domain to IPs
    ips=$(dig +short A "$domain" 2>/dev/null | grep -E '^[0-9]+\.' || true)
    for ip in $ips; do
        ipset add allowed-domains "$ip/32" -exist
    done
done < "$ALLOWLIST_FILE"

# -- Default policy: DROP everything ------------------------------------------
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

# -- Allow loopback ------------------------------------------------------------
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

# -- Allow established connections ---------------------------------------------
iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT

# -- Allow DNS (required for resolution) ---------------------------------------
iptables -A OUTPUT -p udp --dport 53 -j ACCEPT
iptables -A OUTPUT -p tcp --dport 53 -j ACCEPT

# -- Allow SSH (for git operations) --------------------------------------------
iptables -A OUTPUT -p tcp --dport 22 -m set --match-set allowed-domains dst -j ACCEPT

# -- Allow HTTPS to allowed domains --------------------------------------------
iptables -A OUTPUT -p tcp --dport 443 -m set --match-set allowed-domains dst -j ACCEPT

# -- Allow HTTP to allowed domains (some registries redirect) ------------------
iptables -A OUTPUT -p tcp --dport 80 -m set --match-set allowed-domains dst -j ACCEPT

# -- Reject everything else with a clear error ---------------------------------
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# -- Self-test -----------------------------------------------------------------
if curl -sf --max-time 3 https://example.com >/dev/null 2>&1; then
    echo "FIREWALL ERROR: example.com should be blocked but is reachable" >&2
    exit 1
fi

echo "Firewall active — $(ipset list allowed-domains | grep -cE '^[0-9]') IPs allowed"
```

Key design points:
- Reads domains from an external file, not hardcoded — users edit the text file, not the script
- Preserves Docker's internal DNS rules (127.0.0.11) before flushing — without this, container DNS breaks
- Self-tests by verifying `example.com` is blocked
- Only allows ports 22 (SSH), 80 (HTTP), 443 (HTTPS), and 53 (DNS) — no arbitrary outbound
- IPs are resolved once at startup — if CDN IPs rotate during a long session, restart the container

## 5.3 Dockerfile additions

Add firewall system packages and `gosu` (for privilege dropping) to the Dockerfile. These should be in the system packages layer:

```dockerfile
# -- Firewall packages (optional, for firewalled mode) -------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        iptables ipset iproute2 dnsutils curl \
    && rm -rf /var/lib/apt/lists/*

# renovate: datasource=github-releases depName=tianon/gosu
ARG GOSU_VERSION="1.17"
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${arch}" -o /usr/local/bin/gosu \
    && chmod +x /usr/local/bin/gosu \
    && gosu --version
```

Copy the firewall script, allowlist, and helper into the image:

```dockerfile
COPY firewall.sh /usr/local/bin/firewall.sh
RUN chmod +x /usr/local/bin/firewall.sh

COPY firewall-allowlist.txt /usr/local/share/firewall-allowlist.txt

# firewall-list — inspect allowed IPs (reads snapshot taken before privilege drop)
RUN printf '#!/bin/bash\ncat /tmp/firewall-allowed-ips.txt 2>/dev/null || echo "Firewall not active"\n' \
        > /usr/local/bin/firewall-list \
    && chmod +x /usr/local/bin/firewall-list
```

`gosu` is needed because the firewalled mode starts the container as root (to run iptables), then drops to the target UID. It must have a Renovate annotation — unlike Claude Code, it does not auto-update.

## 5.4 Entrypoint modifications

Update `.devcontainer/entrypoint.sh` to handle both normal and firewalled modes:

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

How it works in each mode:
- **Normal mode** (`--user $(id -u):$(id -g)`): Runs as host UID. Firewall skipped. Not root, so gosu skipped. Falls through to `exec "$@"`.
- **IDE without remoteUser** (Zed): Runs as root. `DEVCONTAINER_UID` unset, so infers target from workspace owner via `stat`. Firewall skipped (`DEVCONTAINER_FIREWALL` unset). Drops to workspace owner UID via `gosu`.
- **Firewalled mode** (root + `DEVCONTAINER_UID`): Runs as root. Uses explicit `DEVCONTAINER_UID`. Runs firewall. Drops to target UID via `gosu`.
- **IDE with remoteUser** (VS Code): `updateRemoteUserUID` remaps the `dev` user to host UID before container start. Runs as host UID. Entrypoint is a no-op (not root, no firewall).

## 5.5 devcontainer.json additions (firewalled mode only)

If the user wants to use the firewalled mode from an IDE (VS Code, JetBrains) rather than the task runner, add to `devcontainer.json`:

```json
{
  "runArgs": ["--cap-add=NET_ADMIN", "--cap-add=NET_RAW"],
  "containerEnv": {
    "DEVCONTAINER_FIREWALL": "1",
    "DEVCONTAINER_UID": "${localEnv:UID}",
    "DEVCONTAINER_GID": "${localEnv:GID}"
  }
}
```

Note: `${localEnv:UID}` and `${localEnv:GID}` may not be available on all hosts (they depend on shell exports). The task runner recipe is more reliable because it uses `$(id -u)` directly.
