#!/bin/bash
# Hand the mounted Claude Code config volume to the vscode user.
#
# Docker creates named volumes as root:root and this one is mounted over a
# subdirectory of the home directory, so without this the CLI cannot write
# credentials or transcripts and logins appear to succeed and then drop.
#
# This exists as its own root-owned script because the sandbox strips the
# vscode user's blanket sudo (see Dockerfile); it can run this and the
# firewall script as root, and nothing else. The path is hardcoded on purpose
# — taking it as an argument would turn "chown one directory" into "chown any
# directory", which is a root escalation.

set -euo pipefail

TARGET="/home/vscode/.claude"

if [ ! -d "$TARGET" ]; then
    echo "ERROR: $TARGET does not exist"
    exit 1
fi

# -h so symlinks are retargeted rather than followed out of the directory.
chown -Rh vscode:vscode "$TARGET"
echo "Ownership of $TARGET set to vscode:vscode"
