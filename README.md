# Dyad

An intelligent permission proxy for Claude Code. Autonomous operation with intelligent oversight.

## The Problem

Claude Code's permission model is all-or-nothing — manually approve every tool call, or pass `--dangerously-skip-permissions` and hope for the best. Dyad provides the middle ground: a three-layer permission strategy with audit logging and default-deny.

## How It Works

```
Tool Call → Fast-path (read-only)? → ✅ Allow
                    ↓ no
            Rule match? → ✅ Allow / ❌ Deny
                    ↓ no match
            AI Supervisor → ✅ Allow / ❌ Deny
                    ↓ failure/timeout
                  ❌ Deny (default)
```

- **Fast-path** — Read-only tools (`Read`, `Glob`, `Grep`, `Explore`, etc.) pass instantly with no evaluation
- **Rules** — JSON-configurable glob patterns, first-match-wins
- **Supervisor** — Haiku-class Claude model evaluates safety and relevance

## Prerequisites

- `claude` CLI (Claude Code) — installed and authenticated
- `ANTHROPIC_API_KEY` environment variable set (required for the AI supervisor — browser-based CLI auth does not propagate to the supervisor due to environment isolation). On systems where the key lives in a different variable, set `DYAD_API_KEY_VAR` (see [Environment Variables](#environment-variables))
- `jq` — `brew install jq` on macOS, `sudo apt install jq` on Linux
- Bash 3.2+
- macOS or Linux (WSL untested)

## Installation

```bash
git clone https://github.com/ndp32/dyad.git
cd dyad
chmod +x dyad.sh
```

Optionally add to PATH or create a symlink:

```bash
# macOS
ln -s "$(pwd)/dyad.sh" /usr/local/bin/dyad

# Linux (user-local)
ln -s "$(pwd)/dyad.sh" ~/.local/bin/dyad
```

## Quick Start

```bash
# Run a task with intelligent permissions
./dyad.sh "implement the login page"

# Auto-approve all (still logs decisions)
./dyad.sh --approve-all "refactor the auth module"

# Use custom rules
./dyad.sh --rules my-rules.json "fix the tests"

# Help
./dyad.sh --help
```

## Customizing Rules

Rule `file_path` patterns are **relative to the project root** by default. Dyad auto-detects the project root via `git rev-parse --show-toplevel` (or override with `DYAD_PROJECT_ROOT`). A pattern like `*` matches any file under the project root — no hardcoded paths needed.

Legacy absolute patterns (starting with `/` or `*/`) continue to work unchanged.

### Rule format

```json
{
  "tool": "Edit",
  "action": "allow",
  "match": { "file_path": "*" },
  "reason": "Project file edits are safe"
}
```

- The `match` object maps tool input field names (e.g. `command`, `file_path`) to glob patterns
- `file_path` patterns that don't start with `/` or `*/` are resolved relative to the project root
- An empty `match` object (`{}`) matches all invocations of that tool
- First match wins — place deny rules before allow rules
- Shell metacharacter protection: allow rules for the Bash `command` field automatically reject values containing `;|&$()` and backticks
- Path traversal protection: allow rules on `file_path` fields reject paths containing `..`

### Minimal custom rules example

```json
{
  "rules": [
    {
      "tool": "Bash",
      "action": "deny",
      "match": { "command": "rm -rf *" },
      "reason": "Destructive recursive deletion blocked"
    },
    {
      "tool": "Edit",
      "action": "allow",
      "match": { "file_path": "*" },
      "reason": "Project file edits are safe"
    },
    {
      "tool": "Bash",
      "action": "allow",
      "match": { "command": "git *" },
      "reason": "git commands are safe"
    }
  ]
}
```

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `DYAD_API_KEY_VAR` | `ANTHROPIC_API_KEY` | Name of the env var holding the API key. Set to `ANTHROPIC_AUTH_TOKEN` (or any other var) if your key lives elsewhere. |
| `DYAD_API_KEY_FILE` | *(unset)* | Path to a file containing the API key. Used by sandbox mode to avoid exposing the key in the process table. Takes effect only when the env var key is empty. |
| `DYAD_PROJECT_ROOT` | auto-detected via `git rev-parse --show-toplevel`, then `pwd` | Absolute path to the project root. Relative rule patterns are resolved against this. |

```bash
# Example: use a different API key variable on a shared Linux system
DYAD_API_KEY_VAR=ANTHROPIC_AUTH_TOKEN ./dyad.sh "implement the login page"

# Example: override project root
DYAD_PROJECT_ROOT=/home/user/projects/myapp ./dyad.sh "fix the tests"
```

## Security Model

- **Default-deny** — If anything fails (supervisor timeout, parse error), the operation is denied
- **Fast-path bypass list** — `Read`, `Glob`, `Grep`, `Explore`, `TaskList`, `TaskGet`, `TaskOutput`, `TaskStop` bypass all evaluation (hardcoded, not configurable)
- **Supervisor prompt injection hardening** — Untrusted data wrapped in XML tags
- **Environment isolation** — Supervisor runs via `env -i` to prevent hook recursion and state leakage
- **Consecutive denial circuit breaker** — If the same tool is denied 5 times in a row, the deny reason is escalated with a "5x consecutive" prefix to signal the agent to change approach. An allow or a different tool resets the counter.
- **`--approve-all`** — Disables all security checks but still logs; use only in trusted environments
- **OS-level sandbox** — Optional dedicated unprivileged user (`dyad-sandbox`) isolates Dyad from sensitive files, credentials, and system directories (see [Sandbox Mode](#sandbox-mode))

## Audit Logging

All decisions are logged to `~/.dyad/audit.log` in JSON Lines format.

Each entry contains: `ts`, `session`, `tool`, `input` (truncated to 500 chars), `decision`, `source`, `reason`.

```bash
# What was denied?
jq 'select(.decision == "deny")' ~/.dyad/audit.log

# How many supervisor calls?
jq 'select(.source == "supervisor")' ~/.dyad/audit.log | jq -s length

# Decisions for a specific session
jq --arg sid "$SESSION_ID" 'select(.session == $sid)' ~/.dyad/audit.log
```

No log rotation is built in — manage file size manually.

## Testing

```bash
# Fast tests (no API calls, no sudo, no cost)
./test-dyad.sh

# All tests including live supervisor (requires API key, makes API calls)
./test-dyad.sh --all

# Supervisor tests only
./test-dyad.sh --supervisor

# Sandbox integration tests (requires sudo — creates/destroys real sandbox)
./test-dyad.sh --sandbox
```

## Troubleshooting

**"All my tool calls are being denied"** — Check that your API key variable is set (`ANTHROPIC_API_KEY` by default, or the variable named in `DYAD_API_KEY_VAR`). Check that `DYAD_PROJECT_ROOT` (or auto-detected root) is correct — run dyad and look for the "Project root:" line in the startup banner.

**"Dyad is slow"** — Too many tool calls are falling through to the supervisor. Add more rules for common patterns.

**"Supervisor unavailable" in deny reasons** — API key not set or Claude CLI not authenticated. If your key is in a non-default variable, set `DYAD_API_KEY_VAR`.

**"Permission denied"** — Run `chmod +x dyad.sh`.

## Sandbox Mode

OS-level isolation for Dyad. Runs as a dedicated unprivileged user (`dyad-sandbox`) so that even if Dyad's permission layers are bypassed, the OS kernel prevents access to sensitive files, credentials, and system directories.

### What it protects against

| Threat | Protection |
|--------|-----------|
| Reading `~/.ssh/id_rsa`, `~/.aws/credentials` | Sandbox user has no access to real home directory |
| Writing to `/etc/hosts` or system files | Sandbox user has no write access to system dirs |
| `rm -rf ~/*` | Sandbox user's `$HOME` is disposable; real home untouched |
| Credential theft | No credentials in sandbox; API key passed via temp file |
| API key sniffing via `ps aux` | Key in file (not process table), readable only by sandbox user |
| Privilege re-escalation via sudo | Disabled password, nologin shell, no sudo group |
| Symlink escape during cleanup | All `rm -rf` operations verify target is not a symlink |

**Acknowledged limitations:** World-readable files (`/etc/passwd`, parts of `/proc`), shared kernel exploits, IPC leakage (Unix sockets, `/dev/shm`), and network exfiltration (see optional firewall hardening below) are not prevented by user-based sandboxing.

### Prerequisites

- `sudo` access on the machine
- `claude` CLI, `jq`, and `git` installed
- `rsync` (for non-git projects — pre-installed on macOS and most Linux)
- No Docker or container runtime required

### Quick start

```bash
# 1. Set up the sandbox (creates user, copies project, installs scripts)
./dyad-sandbox-setup.sh /path/to/your/project

# 2. Run a task in the sandbox
./dyad-sandbox-run.sh "implement the login page"

# 3. Apply the results to your real project
git apply /tmp/dyad-results-XXXXXXXX/changes.diff

# 4. When done, tear down the sandbox
./dyad-sandbox-teardown.sh
```

### Setup options

```bash
# Add extra tools to the sandbox PATH
./dyad-sandbox-setup.sh --tools "ruby,rake,bundle" /path/to/project

# Preview what would be done (no changes)
./dyad-sandbox-setup.sh --dry-run /path/to/project
```

The setup script auto-detects project build tools from `package.json` (npm/node/npx), `Makefile` (make), `requirements.txt`/`pyproject.toml` (python3/pip), and `Cargo.toml` (cargo). Only symlinks to these specific binaries are added to the sandbox PATH — not entire directories.

### Run options

```bash
# Ephemeral (default): fresh copy each run, destroyed after
./dyad-sandbox-run.sh "fix the tests"

# Persistent: keep workspace for iterative work
./dyad-sandbox-run.sh --no-cleanup "fix the tests"
# Subsequent runs reuse the workspace

# Custom rules
./dyad-sandbox-run.sh --rules strict-rules.json "deploy prep"

# Auto-approve mode
./dyad-sandbox-run.sh --approve-all "refactor the auth module"
```

### Result extraction

After each run, changes are extracted as a single `git diff`:

```bash
# Results are in a secure temp directory
ls /tmp/dyad-results-XXXXXXXX/
#   changes.diff  — all file modifications
#   audit.log     — sandbox session audit trail

# Apply changes to your real project
cd /path/to/your/project
git apply /tmp/dyad-results-XXXXXXXX/changes.diff

# Review the audit log
jq . /tmp/dyad-results-XXXXXXXX/audit.log
```

### Project copy behavior

**Git projects:** Uses `git archive HEAD` which exports only the **committed state at HEAD**. Uncommitted changes will NOT be present in the sandbox. The setup script warns if the working tree is dirty. To exclude files from the archive, use `.gitattributes` with `export-ignore`:

```gitattributes
# .gitattributes — exclude from sandbox copies
.env export-ignore
secrets/ export-ignore
```

**Non-git projects:** Uses `rsync` with exclusions (`.git`, `.env`, `.env.*`, `node_modules`, `.npmrc`, `.ssh`, `.aws`, `.docker`, `*.pem`, `*.key`, `credentials.json`).

### Project size recommendations

| Project size | Ephemeral overhead | Recommendation |
|-------------|-------------------|----------------|
| <1,000 files | <2 seconds | Ephemeral (default) |
| 1,000-10,000 files | 5-15 seconds | Ephemeral acceptable |
| 10,000-50,000 files | 15-60 seconds | Consider `--no-cleanup` |
| >50,000 files | >60 seconds | Use `--no-cleanup` |

### Optional firewall hardening

By default, the sandbox has no network restrictions beyond Dyad's `WebFetch` deny rule. For stricter isolation, add per-user firewall rules:

**Linux (nftables — recommended):**
```bash
SANDBOX_UID=$(id -u dyad-sandbox)
ANTHROPIC_IP=$(dig +short api.anthropic.com | head -1)

sudo nft add table inet dyad_sandbox
sudo nft add chain inet dyad_sandbox output { type filter hook output priority 0 \; }
sudo nft add rule inet dyad_sandbox output meta skuid $SANDBOX_UID udp dport 53 accept
sudo nft add rule inet dyad_sandbox output meta skuid $SANDBOX_UID tcp dport 53 accept
sudo nft add rule inet dyad_sandbox output meta skuid $SANDBOX_UID tcp dport 443 ip daddr $ANTHROPIC_IP accept
sudo nft add rule inet dyad_sandbox output meta skuid $SANDBOX_UID counter drop
```

**Linux (iptables — legacy):**
```bash
sudo iptables -A OUTPUT -m owner --uid-owner dyad-sandbox -p udp --dport 53 -j ACCEPT
sudo iptables -A OUTPUT -m owner --uid-owner dyad-sandbox -p tcp --dport 53 -j ACCEPT
sudo iptables -A OUTPUT -m owner --uid-owner dyad-sandbox -d api.anthropic.com -p tcp --dport 443 -j ACCEPT
sudo iptables -A OUTPUT -m owner --uid-owner dyad-sandbox -j DROP
```

**macOS (pf):**
```
# Add to /etc/pf.conf:
pass out quick proto { tcp, udp } to any port 53 user dyad-sandbox
pass out quick proto tcp to api.anthropic.com port 443 user dyad-sandbox
block out quick proto { tcp, udp } user dyad-sandbox
```

Apply with `sudo pfctl -f /etc/pf.conf && sudo pfctl -e`. Note: `pf` resolves hostnames at rule load time — reload rules if CDN IPs rotate.

Remove with: `sudo nft delete table inet dyad_sandbox` (Linux) or edit `/etc/pf.conf` and reload (macOS).

### Sandbox troubleshooting

**"Sandbox user does not exist"** — Run `dyad-sandbox-setup.sh` first.

**"PATH problems / command not found in sandbox"** — The sandbox uses a narrow PATH with only symlinked binaries. Add missing tools with `--tools "tool1,tool2"` during setup, or re-run setup.

**"Claude Code auth errors"** — Ensure `ANTHROPIC_API_KEY` is set in your shell before running. Consider using a separate, lower-privilege API key for sandbox runs.

**"Permission denied on results"** — Results are extracted to a `mktemp -d` directory owned by your user. Check that the extraction step completed (look for the "Results extracted to:" message).

**"CLAUDE.md not loaded"** — Claude Code does not load CLAUDE.md files in headless mode by default. To enable, add `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` to the sandbox environment in `dyad-sandbox-run.sh`.

**"Stale workspace"** — If a previous run was interrupted, the workspace may contain stale data. Re-run setup to refresh, or delete `/opt/dyad-workspace/project` manually and re-run.
