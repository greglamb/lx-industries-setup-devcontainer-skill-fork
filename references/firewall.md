# Phase 5: Network Firewall (Optional)

**Ask the user:** will this container be used for autonomous/sandbox mode (`--dangerously-skip-permissions`)? If not, skip this phase entirely — the firewall blocks all outbound traffic except to explicitly allowed domains, which breaks normal development (browsing docs, installing new packages, accessing internal services).

If yes, generate three files and modify the existing Dockerfile and entrypoint.

## 5.1 Allowlist file

Create `.devcontainer/firewall-allowlist.txt` with domains auto-detected from Phase 1:

```
# Allowed outbound domains — one per line, comments start with #.
# The firewall resolves these to IPs at container start and blocks everything else.

# Claude API
api.anthropic.com
statsig.anthropic.com
sentry.io

# Claude Code distribution (always GitHub, regardless of project forge)
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

Always include `registry.npmjs.org` even if the project doesn't use Node.js — Claude Code runs `npm install` for MCP servers at runtime.

Always include `github.com` and `api.github.com` — Claude Code connects to GitHub for distribution and updates, regardless of the project forge.

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
# In firewalled mode, the container starts as root and DEVCONTAINER_UID/GID
# specify the user to drop to. In normal mode, --user already set the UID.
target_uid="${DEVCONTAINER_UID:-$(id -u)}"
target_gid="${DEVCONTAINER_GID:-$(id -g)}"

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

# -- Drop privileges if running as root with a target UID ---------------------
if [[ "$(id -u)" = "0" ]] && [[ -n "${DEVCONTAINER_UID:-}" ]]; then
    exec gosu "${target_uid}:${target_gid}" "$@"
fi

exec "$@"
```

How it works in each mode:
- **Normal mode** (`--user $(id -u):$(id -g)`): Entrypoint runs as the host UID. `DEVCONTAINER_FIREWALL` is unset, firewall is skipped. `DEVCONTAINER_UID` is unset, `gosu` is skipped. Falls through to `exec "$@"`.
- **Firewalled mode** (no `--user`, root): Entrypoint runs as root. Injects passwd entry for the target UID. Runs the firewall script. Then `gosu` drops to the target UID before executing the command.

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
