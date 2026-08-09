FROM mcr.microsoft.com/devcontainers/base:ubuntu

# For fully reproducible builds, pin by digest instead of tag:
#   FROM mcr.microsoft.com/devcontainers/base:ubuntu@sha256:...

# Tooling the egress allowlist is built from. These happen to be present in
# the current base image; installing them explicitly means a future base
# image change cannot silently leave init-firewall.sh unable to run — which,
# because it fails closed, would be a container that refuses to start.
RUN apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
        iptables ipset dnsutils aggregate jq ca-certificates curl gnupg \
    && rm -rf /var/lib/apt/lists/*

# Node, which the Claude Code CLI runs on. Installed here rather than via
# ghcr.io/devcontainers/features/node because that feature also contributes
# the ESLint VS Code extension, and there is no way to decline a feature's
# extensions — the only way to not get it is to not use the feature. The
# claude-code feature checks for node/npm on PATH and skips its own Node
# install when both are present, so this satisfies it.
#
# From NodeSource rather than Ubuntu's split nodejs/npm packages, which lag
# and package npm awkwardly for global installs. Bump node_22.x to move
# major versions. Build-time only, so the egress allowlist does not apply.
RUN install -m 0755 -d /etc/apt/keyrings \
    && curl -fsSL https://deb.nodesource.com/gpgkey/nodesource-repo.gpg.key \
        | gpg --dearmor -o /etc/apt/keyrings/nodesource.gpg \
    && chmod a+r /etc/apt/keyrings/nodesource.gpg \
    && echo "deb [signed-by=/etc/apt/keyrings/nodesource.gpg] https://deb.nodesource.com/node_22.x nodistro main" \
        > /etc/apt/sources.list.d/nodesource.list \
    && apt-get update \
    && DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends nodejs \
    && rm -rf /var/lib/apt/lists/* \
    && node --version && npm --version

# The two privileged scripts are baked into the image, root-owned and not
# writable by anyone else. This is load-bearing: they are the only commands
# the vscode user may run as root, so a copy that user could edit would be a
# one-line path to root. They specifically must not live in the bind-mounted
# workspace, which both you and the agent can write to.
#
# The firewall script is installed as init-firewall-local.sh, NOT
# init-firewall.sh: the claude-code dev container feature unconditionally
# installs its own (upstream, weaker) script at
# /usr/local/bin/init-firewall.sh during the feature build stage, which runs
# after this layer and would silently overwrite ours.
COPY init-firewall.sh /usr/local/bin/init-firewall-local.sh
COPY fix-claude-perms.sh /usr/local/bin/
RUN chown root:root /usr/local/bin/init-firewall-local.sh /usr/local/bin/fix-claude-perms.sh \
    && chmod 0755 /usr/local/bin/init-firewall-local.sh /usr/local/bin/fix-claude-perms.sh

# Replace the base image's blanket passwordless sudo (vscode ALL=(root)
# NOPASSWD:ALL) with permission to run exactly those two scripts. Without
# this the firewall is decorative — anything running as vscode, agent
# included, could simply `sudo iptables -F`.
#
# The trade-off is real: you can no longer apt-get install things at runtime.
# Add them here and rebuild, which is the more reproducible habit anyway.
RUN rm -f /etc/sudoers.d/vscode \
    && printf '%s\n' 'vscode ALL=(root) NOPASSWD: /usr/local/bin/init-firewall-local.sh, /usr/local/bin/fix-claude-perms.sh' \
        > /etc/sudoers.d/vscode-sandbox \
    && chmod 0440 /etc/sudoers.d/vscode-sandbox \
    && visudo -c
