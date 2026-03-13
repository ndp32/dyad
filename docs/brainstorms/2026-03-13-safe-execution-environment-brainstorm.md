# Brainstorm: Safe Execution Environment for Dyad (No Docker)

**Date:** 2026-03-13
**Status:** Draft

## What We're Building

A recommended setup for running Dyad in a safe environment where the underlying Claude Code process cannot cause real damage — even if Dyad's permission layers are bypassed. The solution should work on both macOS and Linux, require minimal setup, and avoid Docker (which may not be available in all environments).

## Why This Matters

Dyad provides defense-in-depth via its rule engine and AI supervisor, but:
- The fast-path allows `Read`/`Glob`/`Grep` on **any** file (including `~/.ssh`, `~/.aws`)
- The AI supervisor (Haiku) could be manipulated via prompt injection
- A bug in `dyad-hook.sh` could bypass all enforcement
- No network isolation exists beyond the `WebFetch` deny rule

A second line of defense at the OS level makes Dyad safe even when its own enforcement fails.

**Assumptions:** Users have sudo access on their machine, and `jq` + `claude` CLI are installed system-wide (accessible via PATH to the sandbox user).

## Chosen Approach: Dedicated Unprivileged User

Create a dedicated OS user (e.g., `dyad-sandbox`) with minimal privileges. Run Dyad as that user. The OS kernel enforces isolation — no amount of prompt injection or hook bugs can escalate past OS-level permissions.

### How It Works

1. **Create user:** A dedicated user with no sudo rights, no login shell, minimal `$HOME`
2. **Project directory:** The sandbox user owns only the project working directory (or a copy of it)
3. **No credentials:** The sandbox user's `$HOME` has no `.ssh`, `.aws`, `.config`, or other sensitive dotfiles — only the `ANTHROPIC_API_KEY` is passed through
4. **Run via sudo:** `sudo -u dyad-sandbox ./dyad.sh "your task"` — the Claude Code process runs entirely as the restricted user
5. **Filesystem boundaries:** OS permissions prevent reading/writing outside the project directory

### What This Protects Against

| Threat | Protection |
|--------|-----------|
| Reading `~/.ssh/id_rsa` | Sandbox user has no access to your home directory |
| Writing to `/etc/hosts` | Sandbox user has no write access to system files |
| `rm -rf ~/*` | Sandbox user's `$HOME` is disposable; your real home is untouched |
| Arbitrary Bash commands | Commands run as unprivileged user with no sudo |
| Credential theft | No credentials exist in the sandbox user's environment |

### What This Does NOT Protect Against

- **Network exfiltration:** The sandbox user can still make outbound network requests (see Optional Hardening below)
- **CPU/memory abuse:** No resource limits without cgroups (Linux) or launchd limits (macOS)
- **Reading world-readable files:** Some system files (e.g., `/etc/passwd`) are readable by all users

### Setup — macOS

```bash
# Create the sandbox user (no login shell, no home directory created automatically)
sudo dscl . -create /Users/dyad-sandbox
sudo dscl . -create /Users/dyad-sandbox UserShell /usr/bin/false
sudo dscl . -create /Users/dyad-sandbox UniqueID 599
sudo dscl . -create /Users/dyad-sandbox PrimaryGroupID 20
sudo dscl . -create /Users/dyad-sandbox NFSHomeDirectory /var/empty

# Create a working directory for the sandbox user
sudo mkdir -p /opt/dyad-workspace
sudo chown dyad-sandbox:staff /opt/dyad-workspace

# Copy your project into the workspace
cp -R /path/to/your/project /opt/dyad-workspace/project
sudo chown -R dyad-sandbox:staff /opt/dyad-workspace/project

# Run Dyad as the sandbox user
sudo -u dyad-sandbox \
  ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  HOME=/opt/dyad-workspace \
  PATH="/usr/local/bin:/usr/bin:/bin" \
  /opt/dyad-workspace/project/dyad.sh "your task here"
```

### Setup — Linux

```bash
# Create the sandbox user (no login, no home)
sudo useradd --system --shell /usr/sbin/nologin --no-create-home dyad-sandbox

# Create a working directory
sudo mkdir -p /opt/dyad-workspace
sudo chown dyad-sandbox:dyad-sandbox /opt/dyad-workspace

# Copy your project
cp -R /path/to/your/project /opt/dyad-workspace/project
sudo chown -R dyad-sandbox:dyad-sandbox /opt/dyad-workspace/project

# Run Dyad as the sandbox user
sudo -u dyad-sandbox \
  ANTHROPIC_API_KEY="$ANTHROPIC_API_KEY" \
  HOME=/opt/dyad-workspace \
  PATH="/usr/local/bin:/usr/bin:/bin" \
  /opt/dyad-workspace/project/dyad.sh "your task here"
```

### Optional Hardening: Per-User Firewall Rules

For users who also want to block network exfiltration, per-user firewall rules can restrict outbound traffic from the sandbox user.

**macOS (pf):**
```
# Add to /etc/pf.conf (pass rule MUST come before block — both use "quick", so first match wins)
pass out quick on egress proto tcp to api.anthropic.com port 443 user dyad-sandbox
block out quick on egress proto { tcp, udp } user dyad-sandbox
```

**Linux (iptables):**
```bash
# Block all outbound from the sandbox user
sudo iptables -A OUTPUT -m owner --uid-owner dyad-sandbox -j DROP
# Optionally allow only the Anthropic API:
sudo iptables -A OUTPUT -m owner --uid-owner dyad-sandbox -d api.anthropic.com -p tcp --dport 443 -j ACCEPT
```

## Key Decisions

1. **Dedicated user over sandbox-exec/bubblewrap** — Simpler to set up, works identically on both platforms, no deprecated APIs or extra dependencies
2. **Copy project into workspace** — Rather than symlinks or bind mounts, a plain copy is simplest and prevents accidental writes back to the original
3. **Firewall rules are optional** — Dyad's `WebFetch` deny rule + the supervisor provide baseline network protection; OS-level firewall is belt-and-suspenders
4. **Pass only ANTHROPIC_API_KEY** — No other environment variables leak into the sandbox
5. **Workspace lifecycle is user's choice** — Support both ephemeral (fresh copy per run, destroyed after) and persistent (reused across runs) modes. Document trade-offs: ephemeral is cleanest isolation but slower; persistent is faster but can drift from the real project

## Resolved Questions

1. **Convenience script:** Ship a `dyad-sandbox-setup.sh` automation script AND document the manual steps so users understand what it does.
2. **Syncing results back:** Use a git-based workflow — initialize a git repo in the sandbox workspace, then the user pulls changes back via `git diff` / `git format-patch` / `git am`. This is natural for code projects and gives full review control.
3. **Claude Code cache/config:** The setup script should create a minimal `~/.claude/` directory in the sandbox home with just enough for Claude Code to function (settings JSON with the hook config, empty projects dir, etc.).

## Open Questions

None — all questions resolved.
