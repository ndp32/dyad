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
- `ANTHROPIC_API_KEY` environment variable set (required for the AI supervisor — browser-based CLI auth does not propagate to the supervisor due to environment isolation)
- `jq` — `brew install jq` on macOS, `apt install jq` on Linux
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
ln -s "$(pwd)/dyad.sh" /usr/local/bin/dyad
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

> **Important:** The default `dyad-rules.json` contains hardcoded paths matching `*/Documents/dyad/*`. Edit these to match your project directory, or every file edit will fall through to the (slower, paid) AI supervisor.

### Rule format

```json
{
  "tool": "Edit",
  "action": "allow",
  "match": { "file_path": "*/my-project/*" },
  "reason": "Project file edits are safe",
  "_note": "Optional human-readable note"
}
```

- The `match` object maps tool input field names (e.g. `command`, `file_path`) to glob patterns
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
      "match": { "file_path": "*/my-project/*" },
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

**"All my tool calls are being denied"** — Check that `ANTHROPIC_API_KEY` is set. Check that the rule file paths match your project directory.

**"Dyad is slow"** — Too many tool calls are falling through to the supervisor. Add more rules for common patterns.

**"Supervisor unavailable" in deny reasons** — API key not set or Claude CLI not authenticated.

**"Permission denied"** — Run `chmod +x dyad.sh`.
