# Security

This template exists to run a coding agent unattended, so the threat model is
the product. Please read it before reporting something.

## What it claims

Inside the container:

- Outbound network is default-deny. Only an explicit allowlist is reachable,
  and the rules are applied before anything attaches.
- The `vscode` user cannot become root. Its sudo is narrowed to two fixed,
  root-owned scripts, so it cannot flush the firewall or install packages.
- Failures close rather than open. If the allowlist cannot be built the
  container ends up with no egress at all and the start is reported as failed.

## What it does not claim

The README has the full list under
[What this does not protect against](README.md#what-this-does-not-protect-against).
The short version, so nobody reports these as news:

- It is not a VM. Container escape is out of scope.
- The allowlist is coarse. All of GitHub is reachable, so is any npm package.
- Your host's git credentials are reachable over a Unix socket the firewall
  cannot see.
- DNS is still a covert channel, narrowed to the container's resolvers.
- The image build and `postCreateCommand` run before the firewall exists.
- The host's `/24` is reachable, including sibling containers.

Those are documented trade-offs, not bugs. A report that the sandbox fails to
stop one of them will be closed with a pointer here.

## What is worth reporting

Anything that breaks a claim in the first list. Concretely:

- A way for the `vscode` user to reach root, or to modify either privileged
  script.
- Traffic to a host that is not on the allowlist and not covered by a
  documented gap.
- A path where the firewall script exits zero without the rules being in
  place, or where the container attaches before `postStartCommand` finishes.
- A dependency in the image or features that quietly restores blanket sudo.

## Reporting

Open a [private security advisory](../../security/advisories/new). For
low-severity issues or anything already public, a normal issue is fine.

This is a personal project with no SLA. Expect a first response within a week
or so. There is no bounty.

## Verifying it yourself

Do not take the claims above on trust — the README's
[Checking it yourself](README.md#checking-it-yourself) section lists the
commands that prove them from inside a shell, and CI runs the same assertions
on every push.
