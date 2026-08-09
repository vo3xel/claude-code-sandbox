# mac-dev-container-test

A dev container template for running [Claude Code](https://claude.com/claude-code)
on macOS — sandboxed by default, with your login surviving rebuilds.

It is deliberately small: a base image, three features, a default-deny egress
firewall, and the handful of settings that are annoying to work out on your
own. Use it as a starting point and grow it into whatever your project
actually needs.

## Requirements

- Docker. Built and tested against [OrbStack](https://orbstack.dev), but Docker
  Desktop works the same way.
- VS Code with the [Dev Containers](https://marketplace.visualstudio.com/items?itemName=ms-vscode-remote.remote-containers)
  extension, or the [`devcontainer` CLI](https://github.com/devcontainers/cli).

The base image is `mcr.microsoft.com/devcontainers/base:ubuntu`, which has an
arm64 variant, so this runs natively on Apple Silicon — no emulation.

## Quick start

Click **Use this template** on GitHub, then open your new repo in VS Code and
run **Dev Containers: Reopen in Container**. First build takes a few minutes
while the features install; later starts are fast.

Every start applies the firewall before attaching, which adds a few seconds
and prints its allowlist to the container log. If a start fails, that log is
the first place to look — it fails loudly on purpose.

Once inside, run `claude` and sign in. You only need to do that once — see
below.

## What's in the box

| Feature | Why |
| --- | --- |
| `ghcr.io/devcontainers/features/node` | What the Claude Code CLI runs on |
| `ghcr.io/anthropics/devcontainer-features/claude-code` | The CLI, plus the VS Code extension |
| `ghcr.io/devcontainers/features/github-cli` | `gh`, for PRs and issues |

| File | Role |
| --- | --- |
| [`devcontainer.json`](.devcontainer/devcontainer.json) | Image, features, mounts, lifecycle |
| [`Dockerfile`](.devcontainer/Dockerfile) | Firewall tooling, and the sudo lockdown |
| [`init-firewall.sh`](.devcontainer/init-firewall.sh) | The egress allowlist — edit this to permit a host. Installed into the image as `init-firewall-local.sh`; see below |
| [`fix-claude-perms.sh`](.devcontainer/fix-claude-perms.sh) | Hands the config volume to `vscode` |
| [`devcontainer-lock.json`](.devcontainer/devcontainer-lock.json) | Pins the features to exact digests |

## The non-obvious parts

Four details in [`.devcontainer`](.devcontainer) exist to work around problems
you would otherwise hit. They are worth understanding before you edit
anything.

**Your login persists across rebuilds.** A named Docker volume is mounted at
`/home/vscode/.claude`, and `CLAUDE_CONFIG_DIR` points there too. Both halves
are needed: Claude Code keeps your OAuth account and per-project trust in
`~/.claude.json`, which normally sits *outside* the `.claude` directory and so
would not be covered by the volume alone. The volume is scoped per project via
`${devcontainerId}`; drop that to share one login across all your repos.

**The `postCreateCommand` chown is not optional.** Docker creates that volume
as `root:root` and mounts it over the home directory, so the `vscode` user
cannot write credentials or transcripts into it. Without the chown, logins
appear to succeed and then silently drop. It runs as a fixed script rather
than an inline `chown` because this user's sudo is restricted to named
commands; the target path is hardcoded so that "chown one directory" cannot be
turned into "chown any directory". Append your own setup steps after it with
`&&`.

**Node is declared explicitly.** The Claude Code feature installs Node itself
when the base image lacks it, but declaring it up front avoids an intermittent
`Failed to install Node.js and npm` build failure.

**The firewall script is installed under a different name.** The
[`Dockerfile`](.devcontainer/Dockerfile) copies `init-firewall.sh` to
`/usr/local/bin/init-firewall-local.sh`, and `postStartCommand` and the sudoers
rule both name that path. This is not cosmetic: the `claude-code` feature
unconditionally installs its own upstream firewall script at
`/usr/local/bin/init-firewall.sh`, and features are layered *after* the
Dockerfile, so the obvious name would be silently overwritten during the build.
You would get a container that runs a weaker allowlist than the one in this
repo, with nothing in the log to say so. Rename it in all three places or none.

## The sandbox

The container is locked down by default, on the assumption that you will want
to run an agent in it unsupervised.

**Default-deny egress.** [`init-firewall.sh`](.devcontainer/init-firewall.sh)
sets `iptables` policy to `DROP` and permits only an explicit allowlist:
GitHub's published IP ranges, the Anthropic API and login endpoints, Claude
Code's telemetry hosts, the npm registry, and the VS Code marketplace, blob,
and update hosts. Everything else is rejected — and rejected rather than
dropped, so blocked calls fail immediately instead of hanging for a minute.

**IPv6 is denied outright, and there is no SSH hole.** No allowlist is
maintained for v6, and an unfiltered v6 path would route straight around
everything above, so all three v6 chains are set to `DROP`. The reference
script this is adapted from also allows outbound TCP/22 to anywhere so that
git-over-SSH works; that is a shell to any host on the internet, so it is gone.
GitHub is matched by address rather than port, so `git+ssh` to GitHub still
works without it.

**No route to root.** The base image ships `vscode ALL=(root) NOPASSWD:ALL`.
The [`Dockerfile`](.devcontainer/Dockerfile) removes it and grants exactly two
commands instead: the firewall script and the volume-ownership fix. Both are
baked into the image root-owned and read-only to `vscode`. Without this the
firewall would be decorative — anything running as `vscode` could `sudo
iptables -F` and walk out. This is also what makes
`--dangerously-skip-permissions` defensible here rather than reckless.

**Fails closed, literally.** The firewall runs from `postStartCommand` on
every start. If anything goes wrong while building the allowlist, a trap drops
the container to *no egress at all* and still exits non-zero, so a half-built
firewall can never be mistaken for a working one. `waitFor` is set to that
command, so nothing attaches to a container whose network is still open. A
sandbox that silently degrades is worse than none, because you stop checking.

**Verified, not assumed.** The script ends by proving both directions:
`example.com` must be unreachable and `api.github.com` must be reachable. If
either check comes out wrong, the start fails.

It also asserts on every boot that the sudo lockdown is still in place, since
dev container features are layered on top of the image and run their own
install scripts as root.

### Checking it yourself

The container checks itself on every start, but the whole argument above is
that you should not take a sandbox on faith. These five prove the interesting
parts from inside a shell:

```bash
sudo -l                                    # exactly two scripts, nothing else
curl --connect-timeout 5 https://example.com   # exit 7, immediately
curl --connect-timeout 5 https://api.github.com/zen   # 200
ssh -T git@gitlab.com                      # Network is unreachable
touch /usr/local/bin/init-firewall-local.sh    # Permission denied
```

`sudo iptables -L` deliberately will not work — reading the rules needs root,
and you do not have it. That is the point; read
[`init-firewall.sh`](.devcontainer/init-firewall.sh) instead.

Two results are easy to misread. `ssh -T git@github.com` returning
`Permission denied (publickey)` is a *success* — the connection reached
GitHub's SSH daemon and only the key was missing, which is the address-matched
allowlist working. And blocked hosts fail with curl exit 7 in well under a
second; if something hangs instead, the rules are not what you think.

### Adding to the allowlist

Edit `ALLOWED_DOMAINS` at the top of
[`init-firewall.sh`](.devcontainer/init-firewall.sh) — commented-out entries
for PyPI and the Go module proxy are already there — then rebuild. A name that
does not resolve is logged as a warning and skipped rather than aborting the
start; the effect is that the tool needing it stays blocked, never that the
sandbox opens up.

### What this does not protect against

Be clear-eyed about the boundary:

- **DNS is still an exfiltration channel.** Queries are restricted to the
  container's own resolvers rather than anywhere on the internet, but a
  determined process can still encode data into hostnames it looks up.
- **The allowlist is coarse.** GitHub's ranges mean *all* of GitHub, so a
  push to an attacker's repo is permitted traffic. Same for any npm package.
- **Your host's git credentials reach inside, and the firewall cannot see
  them.** The Dev Containers extension writes a credential helper into
  `/etc/gitconfig` that proxies to macOS over a Unix socket
  (`REMOTE_CONTAINERS_IPC`), not the network. `gh auth status` will say you are
  logged out while `git push` works anyway. Combined with the previous point,
  anything in the container can push to any repo your host account can write
  to. This is the sharpest edge in the whole setup — see below.
- **Your workspace is mounted read-write.** Anything in the container can
  modify your project files, including its own git history.
- **The local Docker subnet is wide open.** The host's `/24` is allowed in
  both directions so the VS Code server and forwarded ports keep working. That
  also means the host and every other container on that bridge are reachable —
  if you run something sensitive alongside this container, the firewall is not
  what is standing between them.
- **DNS-based allowlisting drifts.** IPs are resolved once per container
  start; a CDN that rotates addresses mid-session can start failing until
  restart.
- **Build and create run unrestricted.** The image build and
  `postCreateCommand` happen before the firewall exists, so anything you
  append there (`npm install`, and the features themselves) has open network
  on first create. Convenient, but it means the supply chain is trusted, not
  contained.
- **It is not a VM.** Container escapes are a real class of bug, and
  `NET_ADMIN` is held by root inside the container.

Your Claude Code credentials live in the Docker volume, outside the workspace,
so they cannot be committed by accident.

### Turning it off

If you want the plain, unrestricted container: drop `runArgs`,
`postStartCommand`, and `waitFor` from
[`devcontainer.json`](.devcontainer/devcontainer.json), and delete the final
`RUN` block in the [`Dockerfile`](.devcontainer/Dockerfile) to restore blanket
sudo. Rebuild.

## Working in it

The sandbox is only half of it; the other half is habits. These are the ones
that actually matter here, roughly in order of how much they buy you.

**Let the agent off the leash — that is what the container is for.** Run
`claude --dangerously-skip-permissions` and stop approving individual tool
calls. The whole point of the sudo lockdown and the default-deny egress is to
move the boundary from "did I read that prompt carefully" to "what can this
process actually reach," which is a boundary that does not get tired. Approving
edits one at a time inside a sandbox is the worst of both: still interruptible,
no more contained.

**Narrow your GitHub credentials before you do.** This is the one thing the
firewall cannot help with. Your host's git auth is reachable over a Unix
socket, and all of GitHub is allowed egress, so the default blast radius is
every repo your account can write to. Sign in with a fine-grained personal
access token scoped to the repos you are actually working on, and the coarse
allowlist stops mattering nearly as much. If you would rather cut it off
entirely, `git config --global --unset credential.helper` and use a token in
the remote URL — but note the helper is also set in `/etc/gitconfig`, so it
comes back on rebuild.

**Push often; the remote is your real undo.** The workspace is mounted
read-write and the agent can rewrite git history, so a local commit is not a
checkpoint it cannot reach. Anything already on the remote is. Work on a
branch, push early, and a bad session costs you a `git reset --hard
origin/<branch>` instead of an afternoon.

**When something is blocked, find out what it wanted before you allow it.** A
blocked call fails in well under a second — curl exit 7, or `Network is
unreachable` — so it is obvious what happened, and the temptation is to paste
the domain into `ALLOWED_DOMAINS` and move on. Every entry you add is permanent
egress for *everything* in the container, not just the tool that asked. A
package that suddenly needs an analytics endpoint is worth ten seconds of
thought.

**Re-run the firewall instead of rebuilding when things start failing
mid-session.** Addresses are resolved once at start, so a CDN that rotates can
break a working setup hours in. `sudo /usr/local/bin/init-firewall-local.sh`
re-resolves the whole allowlist, re-verifies both directions, and exits 0 — it
is idempotent and takes a couple of seconds, which beats a restart.

**Install dependencies after you attach, not in `postCreateCommand`.** Create
runs before the firewall exists. Anything you append there gets open network on
first build, which is convenient right up until it is the thing you were trying
to contain. Running `npm install` yourself once you have a shell puts it behind
the allowlist.

**Keep one container per project.** `${devcontainerId}` scopes the config
volume, so a prompt injection in one repo cannot read another repo's session
history or trust settings. Sharing a volume across repos is a real convenience
and a real hole; know which one you are picking.

**Trust the attach.** `waitFor` is set to `postStartCommand`, so if you got a
shell, the firewall applied and passed its own two-way check. You do not need
to verify by hand every morning — only after changing the firewall script,
adding a feature, or anything else that touches the build.

## Reproducible rebuilds

[`.devcontainer/devcontainer-lock.json`](.devcontainer/devcontainer-lock.json)
is committed on purpose. The feature references use floating tags (`node:1`),
so without the lock file every rebuild resolves to whatever is newest and two
machines can drift apart from identical config. The lock pins exact digests —
same role as `package-lock.json`.

Refresh it with `devcontainer upgrade`, ideally as its own commit so version
bumps show up in review.

Two things the lock does *not* cover. The base image tag is one — pin it by
digest in the [`Dockerfile`](.devcontainer/Dockerfile) if you need full
reproducibility. The Claude Code CLI is the other: `claude-code:1.0` pins the
feature's install script, not the release it fetches, so you get whatever
version is current at build time. That is usually what you want.

## Customizing

- **Different stack?** Change `FROM` in the
  [`Dockerfile`](.devcontainer/Dockerfile). If you move to a non-Debian base,
  the `apt-get` line needs adjusting too. Check the username while you are
  there — `base:ubuntu` uses `vscode`, most Node images use `node` — and keep
  `remoteUser`, the sudoers rule in the Dockerfile, the path in
  `fix-claude-perms.sh`, the mount target, and `CLAUDE_CONFIG_DIR` in sync.
  They all name the same user, and a mismatch shows up as a broken login.
- **More tools?** Add to `features`, e.g.
  `"ghcr.io/devcontainers/features/python:1": { "version": "3.12" }`.
- **More system packages?** Add them to the `apt-get` line in the Dockerfile
  and rebuild. Runtime `sudo apt-get install` no longer works — that is the
  sudo lockdown doing its job, and baking them in is more reproducible anyway.
  Whatever you add may also need a matching entry in `ALLOWED_DOMAINS`.
- **Serving something?** Uncomment `forwardPorts`. OrbStack exposes forwarded
  ports on `localhost`.
- **Local-only tweaks?** `.devcontainer/devcontainer.local.json` and
  `.devcontainer/.env` are gitignored.

## License

MIT — see [LICENSE](LICENSE).
