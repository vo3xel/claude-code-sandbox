#!/bin/bash
# Egress allowlist for the dev container.
#
# Runs as root on every container start (postStartCommand), and exits non-zero
# if it cannot lock the network down. That failure is deliberate: a sandbox
# that quietly degrades to "wide open" is worse than no sandbox at all,
# because you stop checking.
#
# Adapted from the reference script in anthropics/claude-code. The places it
# diverges are flagged inline: no blanket outbound SSH, DNS narrowed to the
# container's own resolvers, IPv6 denied outright, an unresolvable domain
# warns instead of aborting, and failure anywhere leaves egress closed rather
# than merely reporting an error.

set -euo pipefail
IFS=$'\n\t'

# ---------------------------------------------------------------------------
# The allowlist. This is the one place to edit when a tool needs to reach out.
# GitHub is handled separately below, from its published IP ranges.
# ---------------------------------------------------------------------------
ALLOWED_DOMAINS=(
    # Claude Code: API, login, telemetry.
    "api.anthropic.com"
    "console.anthropic.com"
    "claude.ai"
    "statsig.com"
    "sentry.io"

    # Package registry.
    "registry.npmjs.org"

    # VS Code server and extension downloads.
    "marketplace.visualstudio.com"
    "vscode.blob.core.windows.net"
    "update.code.visualstudio.com"

    # Add what your stack needs, e.g.:
    # "pypi.org"
    # "files.pythonhosted.org"
    # "proxy.golang.org"
    # "sum.golang.org"
)

# ---------------------------------------------------------------------------
# Fail closed, for real.
#
# Everything below runs after the existing rules are flushed, so an error in
# the middle would otherwise leave the container wide open *and* report
# failure — the worst of both. On any non-zero exit, drop to no egress at all
# and keep the non-zero status so the container start is still marked failed.
# ---------------------------------------------------------------------------
fail_closed() {
    local rc=$?
    [ "$rc" -eq 0 ] && exit 0
    echo "ERROR: firewall setup failed (exit $rc) - locking down all egress."
    iptables -F || true
    iptables -P INPUT DROP || true
    iptables -P FORWARD DROP || true
    iptables -P OUTPUT DROP || true
    iptables -A INPUT -i lo -j ACCEPT || true
    iptables -A OUTPUT -o lo -j ACCEPT || true
    exit "$rc"
}
trap fail_closed EXIT

# ---------------------------------------------------------------------------
# Preflight: confirm the sudo lockdown from the Dockerfile is still in place.
#
# Dev container features are layered on top of that image and run their own
# install scripts as root, so this asserts on every start rather than trusting
# build order. Blanket sudo makes everything below trivially reversible by
# whatever is running as vscode, so treat it as a broken sandbox and stop.
#
# Ask sudo what the user may actually do rather than pattern-matching the
# sudoers files: that also catches a grant arriving via group membership,
# which a grep for a "vscode ALL=..." line would sail straight past.
# ---------------------------------------------------------------------------
if sudo -l -U vscode 2>/dev/null | grep -qE '\((ALL|root)[^)]*\)[[:space:]]*(NOPASSWD:[[:space:]]*)?ALL[[:space:]]*$'; then
    echo "ERROR: the vscode user has blanket sudo - it could simply undo this."
    echo "       Refusing to bring the container up as a sandbox it is not."
    echo "       Look for a feature or local change granting sudo, and rebuild."
    exit 1
fi

# ---------------------------------------------------------------------------
# Reset. Pull Docker's embedded-DNS NAT rules out first so we can put them
# back — flushing them breaks name resolution inside the container.
# ---------------------------------------------------------------------------
DOCKER_DNS_RULES=$(iptables-save -t nat | grep "127\.0\.0\.11" || true)

iptables -F
iptables -X
iptables -t nat -F
iptables -t nat -X
iptables -t mangle -F
iptables -t mangle -X
ipset destroy allowed-domains 2>/dev/null || true

# Flushing clears rules but leaves chain *policy* untouched, so a rerun
# inside an already-firewalled container would hit DROP and fail at the first
# outbound call it needs to build the new allowlist. Reset to ACCEPT. The
# open window this creates lasts until the DROP below, and the trap above
# closes it if anything in between goes wrong.
iptables -P INPUT ACCEPT
iptables -P FORWARD ACCEPT
iptables -P OUTPUT ACCEPT

if [ -n "$DOCKER_DNS_RULES" ]; then
    echo "Restoring Docker DNS rules..."
    iptables -t nat -N DOCKER_OUTPUT 2>/dev/null || true
    iptables -t nat -N DOCKER_POSTROUTING 2>/dev/null || true
    echo "$DOCKER_DNS_RULES" | xargs -L 1 iptables -t nat
else
    echo "No Docker DNS rules to restore"
fi

# ---------------------------------------------------------------------------
# Loopback and DNS, before anything starts dropping.
#
# Deviation from the reference: it allows UDP/53 to *anywhere*, which is a
# usable exfiltration channel. We allow it only to the resolvers this
# container actually uses. Note that this narrows the hole rather than
# closing it — see the DNS caveat in the README.
# ---------------------------------------------------------------------------
iptables -A INPUT -i lo -j ACCEPT
iptables -A OUTPUT -o lo -j ACCEPT

NAMESERVERS=$(awk '/^nameserver/ {print $2}' /etc/resolv.conf)
if [ -z "$NAMESERVERS" ]; then
    echo "ERROR: No nameserver found in /etc/resolv.conf"
    exit 1
fi
while read -r ns; do
    if [[ ! "$ns" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
        echo "Skipping non-IPv4 nameserver $ns"
        continue
    fi
    echo "Allowing DNS to $ns"
    iptables -A OUTPUT -d "$ns" -p udp --dport 53 -j ACCEPT
    iptables -A OUTPUT -d "$ns" -p tcp --dport 53 -j ACCEPT
    iptables -A INPUT -s "$ns" -p udp --sport 53 -j ACCEPT
done < <(echo "$NAMESERVERS")

# ---------------------------------------------------------------------------
# Build the destination set.
# ---------------------------------------------------------------------------
ipset create allowed-domains hash:net

echo "Fetching GitHub IP ranges..."
gh_ranges=$(curl -s --connect-timeout 10 https://api.github.com/meta)
if [ -z "$gh_ranges" ]; then
    echo "ERROR: Failed to fetch GitHub IP ranges"
    exit 1
fi
if ! echo "$gh_ranges" | jq -e '.web and .api and .git' >/dev/null; then
    echo "ERROR: GitHub API response missing required fields"
    exit 1
fi

echo "Processing GitHub IPs..."
while read -r cidr; do
    if [[ ! "$cidr" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}/[0-9]{1,2}$ ]]; then
        echo "ERROR: Invalid CIDR range from GitHub meta: $cidr"
        exit 1
    fi
    ipset -exist add allowed-domains "$cidr"
done < <(echo "$gh_ranges" | jq -r '(.web + .api + .git)[]' | aggregate -q)

for domain in "${ALLOWED_DOMAINS[@]}"; do
    ips=$(dig +noall +answer A "$domain" | awk '$4 == "A" {print $5}')
    if [ -z "$ips" ]; then
        # Warn rather than abort. The reference script exits here, but that
        # turns one unresolvable or momentarily flaky name into a container
        # that will not start. Skipping an entry can only make the allowlist
        # smaller, never larger, so the failure direction is safe — you get
        # "that tool is blocked", not "the sandbox is open".
        echo "WARNING: could not resolve $domain - it will NOT be reachable"
        continue
    fi
    echo "Resolved $domain"
    while read -r ip; do
        if [[ ! "$ip" =~ ^[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}\.[0-9]{1,3}$ ]]; then
            echo "ERROR: Invalid IP from DNS for $domain: $ip"
            exit 1
        fi
        ipset -exist add allowed-domains "$ip"
    done < <(echo "$ips")
done

# The host's subnet, so the VS Code server and forwarded ports keep working.
HOST_IP=$(ip route | grep default | cut -d" " -f3)
if [ -z "$HOST_IP" ]; then
    echo "ERROR: Failed to detect host IP"
    exit 1
fi
HOST_NETWORK=$(echo "$HOST_IP" | sed "s/\.[0-9]*$/.0\/24/")
echo "Host network detected as: $HOST_NETWORK"
iptables -A INPUT -s "$HOST_NETWORK" -j ACCEPT
iptables -A OUTPUT -d "$HOST_NETWORK" -j ACCEPT

# ---------------------------------------------------------------------------
# Default deny, then the allowlist.
#
# Deviation from the reference: no blanket "outbound TCP/22 to anywhere" rule.
# It exists there so git-over-SSH works, but it also permits an SSH session to
# any host on the internet. GitHub's ranges are in the ipset and the match is
# on address, not port, so git+ssh to GitHub still works without it.
# ---------------------------------------------------------------------------
iptables -P INPUT DROP
iptables -P FORWARD DROP
iptables -P OUTPUT DROP

iptables -A INPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m state --state ESTABLISHED,RELATED -j ACCEPT
iptables -A OUTPUT -m set --match-set allowed-domains dst -j ACCEPT

# REJECT rather than DROP, so blocked calls fail fast instead of hanging.
iptables -A OUTPUT -j REJECT --reject-with icmp-admin-prohibited

# ---------------------------------------------------------------------------
# IPv6. No allowlist is maintained for it, and an unfiltered v6 path would
# route straight around everything above, so deny it entirely.
# ---------------------------------------------------------------------------
if ip6tables -L >/dev/null 2>&1; then
    echo "Denying IPv6..."
    ip6tables -F
    ip6tables -X
    ip6tables -P INPUT DROP
    ip6tables -P FORWARD DROP
    ip6tables -P OUTPUT DROP
    ip6tables -A INPUT -i lo -j ACCEPT
    ip6tables -A OUTPUT -o lo -j ACCEPT
else
    echo "ip6tables unavailable; assuming no IPv6 stack"
fi

# ---------------------------------------------------------------------------
# Prove it works in both directions before declaring success.
# ---------------------------------------------------------------------------
echo "Verifying firewall rules..."
if curl --connect-timeout 5 -s https://example.com >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - was able to reach https://example.com"
    exit 1
fi
echo "  blocked: example.com unreachable, as expected"

if ! curl --connect-timeout 5 -s https://api.github.com/zen >/dev/null 2>&1; then
    echo "ERROR: Firewall verification failed - unable to reach https://api.github.com"
    exit 1
fi
echo "  allowed: api.github.com reachable, as expected"

echo "Firewall configuration complete"
