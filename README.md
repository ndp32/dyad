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

Dyad is in active development. See the `todos/` directory for known issues being addressed.

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
# Fast tests (no API calls, no cost)
./test-dyad.sh

# All tests including live supervisor (requires API key, makes API calls)
./test-dyad.sh --all

# Supervisor tests only
./test-dyad.sh --supervisor
```

## Troubleshooting

**"All my tool calls are being denied"** — Check that your API key variable is set (`ANTHROPIC_API_KEY` by default, or the variable named in `DYAD_API_KEY_VAR`). Check that `DYAD_PROJECT_ROOT` (or auto-detected root) is correct — run dyad and look for the "Project root:" line in the startup banner.

**"Dyad is slow"** — Too many tool calls are falling through to the supervisor. Add more rules for common patterns.

**"Supervisor unavailable" in deny reasons** — API key not set or Claude CLI not authenticated. If your key is in a non-default variable, set `DYAD_API_KEY_VAR`.

**"Permission denied"** — Run `chmod +x dyad.sh`.
