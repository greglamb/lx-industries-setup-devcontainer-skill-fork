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
