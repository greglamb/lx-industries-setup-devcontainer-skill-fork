# renovate: datasource=docker depName=debian
FROM debian:bookworm-slim@sha256:98f4b71de414932439ac6ac690d7060df1f27161073c5036a7553723881bffbe

# -- Environment (set early so tool installers use the right paths) -----------
ENV HOME=/tmp/home
ENV PATH="${HOME}/.local/bin:${PATH}"

# -- NPM supply-chain hardening ------------------------------------------------
# Block postinstall scripts and require 24h package age for supply-chain safety.
ENV NPM_CONFIG_IGNORE_SCRIPTS=true
ENV NPM_CONFIG_MINIMUM_RELEASE_AGE=1440

# -- Forge CLI config directory ------------------------------------------------
ENV GLAB_CONFIG_DIR=/tmp/glab-config

# -- System packages -----------------------------------------------------------
RUN apt-get update && apt-get install -y --no-install-recommends \
        ca-certificates curl git openssh-client \
        iptables ipset iproute2 dnsutils \
    && rm -rf /var/lib/apt/lists/*

# -- gosu (privilege dropping for firewalled mode) -----------------------------
# renovate: datasource=github-releases depName=tianon/gosu
ARG GOSU_VERSION="1.19"
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://github.com/tianon/gosu/releases/download/${GOSU_VERSION}/gosu-${arch}" -o /usr/local/bin/gosu \
    && chmod +x /usr/local/bin/gosu \
    && gosu --version

# -- GitLab CLI (glab) ---------------------------------------------------------
# renovate: datasource=gitlab-releases depName=gitlab-org/cli registryUrl=https://gitlab.com
ARG GLAB_VERSION="1.86.0"
RUN arch="$(dpkg --print-architecture)" \
    && curl -fsSL "https://gitlab.com/gitlab-org/cli/-/releases/v${GLAB_VERSION}/downloads/glab_${GLAB_VERSION}_linux_${arch}.deb" -o /tmp/glab.deb \
    && dpkg -i /tmp/glab.deb \
    && rm /tmp/glab.deb \
    && glab --version \
    && rm -rf /tmp/glab-config \
    && mkdir -m 1777 /tmp/glab-config

# -- Claude Code (native binary, auto-updates) --------------------------------
# HOME is set above so the installer places the binary at $HOME/.local/bin/claude
RUN curl -fsSL https://claude.ai/install.sh | bash \
    && claude --version

# -- Git and SSH configuration -------------------------------------------------
# Wildcard — mount path unknown at build time
RUN git config --system safe.directory '*'

# Populate known hosts (no interactive prompt)
# Include github.com — Claude Code distribution uses GitHub
RUN mkdir -p /etc/ssh \
    && ssh-keyscan -t ecdsa,rsa,ed25519 gitlab.com github.com >> /etc/ssh/ssh_known_hosts 2>/dev/null

# -- Permissions ---------------------------------------------------------------
RUN chmod -R 1777 /tmp/home

# -- Firewall files ------------------------------------------------------------
COPY firewall.sh /usr/local/bin/firewall.sh
RUN chmod +x /usr/local/bin/firewall.sh

COPY firewall-allowlist.txt /usr/local/share/firewall-allowlist.txt

# firewall-list — inspect allowed IPs (reads snapshot taken before privilege drop)
RUN printf '#!/bin/bash\ncat /tmp/firewall-allowed-ips.txt 2>/dev/null || echo "Firewall not active"\n' \
        > /usr/local/bin/firewall-list \
    && chmod +x /usr/local/bin/firewall-list

# -- Arbitrary UID support -----------------------------------------------------
# Allow entrypoint to add a passwd entry for the running UID
RUN chmod 0666 /etc/passwd

COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh
ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["bash"]

# No WORKDIR — project mounted at host-native absolute path
# for git worktree compatibility (.git file contains absolute paths)
