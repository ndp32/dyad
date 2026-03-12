---
title: "feat: Add README for open-source users"
type: feat
status: completed
date: 2026-03-12
---

# feat: Add README for open-source users

## Overview

Dyad has no README. Without one, open-source users landing on the GitHub repo have no way to understand what the project does, how to set it up, or how to use it. This plan covers creating a concise, well-structured README.md targeted at developers discovering Dyad for the first time.

## Problem Statement

- No README.md exists in the repository
- No LICENSE file exists (legally blocks open-source adoption)
- The only user-facing docs are `dyad.sh --help` and internal plan documents
- Key setup gotchas (API key requirement, hardcoded paths in default rules) are undocumented

## Proposed Solution

Create a concise README.md with the sections below. Tone: direct, technical, no fluff. Style reference: Ankane-style gem READMEs — imperative voice, code-first, minimal prose.

## README Sections

### 1. Title + One-Liner

```
# Dyad

An intelligent permission proxy for Claude Code. Autonomous operation with intelligent oversight.
```

### 2. The Problem

Brief paragraph: Claude Code's permission model is all-or-nothing — manual approval for every tool call, or `--dangerously-skip-permissions`. Dyad provides the middle ground: a three-layer permission strategy (fast-path → rules → AI supervisor) with audit logging and default-deny.

### 3. How It Works

ASCII diagram showing the three-layer flow:

```
Tool Call → Fast-path (read-only)? → ✅ Allow
                    ↓ no
            Rule match? → ✅ Allow / ❌ Deny
                    ↓ no match
            AI Supervisor → ✅ Allow / ❌ Deny
                    ↓ failure/timeout
                  ❌ Deny (default)
```

Brief explanation of each layer:
- **Fast-path**: Read-only tools (`Read`, `Glob`, `Grep`, `Explore`, etc.) pass instantly
- **Rules**: JSON-configurable glob patterns, first-match-wins
- **Supervisor**: Haiku-class Claude model evaluates safety and relevance

### 4. Prerequisites

- `claude` CLI (Claude Code) — installed and authenticated
- `ANTHROPIC_API_KEY` environment variable set (required for the AI supervisor — browser-based CLI auth does not propagate to the supervisor due to environment isolation)
- `jq` — `brew install jq` on macOS, `apt install jq` on Linux
- Bash 3.2+
- macOS or Linux (WSL untested)

### 5. Installation

```bash
git clone https://github.com/ndp32/dyad.git
cd dyad
chmod +x dyad.sh
```

Optional: add to PATH or symlink.

### 6. Quick Start

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

### 7. Customizing Rules

⚠️ **Important:** The default `dyad-rules.json` contains hardcoded paths matching `*/Documents/dyad/*`. You must edit these to match your project directory, or every file edit will fall through to the (slower, paid) AI supervisor.

Document:
- Rule format: `{ "tool": "ToolName", "action": "allow|deny", "match": { "field": "glob_pattern" }, "reason": "...", "_note": "..." }`
- The `match` object maps tool input field names (e.g. `command`, `file_path`) to glob patterns
- An empty `match` object (`{}`) matches all invocations of that tool
- Evaluation order: first match wins — place deny rules before allow rules
- Shell metacharacter protection: allow rules for Bash `command` field automatically reject values containing `;|&$()` and backticks
- Path traversal protection: allow rules on `file_path` fields reject paths containing `..`

Include a minimal custom rules example.

### 8. Security Model

- **Default-deny**: if anything fails (supervisor timeout, parse error), the operation is denied
- **Fast-path bypass list**: `Read`, `Glob`, `Grep`, `Explore`, `TaskList`, `TaskGet`, `TaskOutput`, `TaskStop` — these bypass all evaluation (hardcoded, not configurable)
- **Supervisor prompt injection hardening**: untrusted data wrapped in XML tags
- **Environment isolation**: supervisor runs via `env -i` to prevent hook recursion and state leakage
- **Consecutive denial circuit breaker**: if the same tool is denied 5 times in a row, the deny reason is escalated with a "5x consecutive" prefix to signal the agent to change approach. An allow decision or a different tool resets the counter.
- **`--approve-all`**: disables all security checks, still logs — use only in trusted environments

Note: Dyad is in active development. See the `todos/` directory for known issues being addressed.

### 9. Audit Logging

All decisions logged to `~/.dyad/audit.log` in JSON Lines format.

Document the schema fields: `ts`, `session`, `tool`, `input` (truncated to 500 chars), `decision`, `source`, `reason`

Include 2-3 example `jq` queries:
```bash
# What was denied today?
jq 'select(.decision == "deny")' ~/.dyad/audit.log

# How many supervisor calls?
jq 'select(.source == "supervisor")' ~/.dyad/audit.log | jq -s length

# Decisions for current session
jq --arg sid "$SESSION_ID" 'select(.session == $sid)' ~/.dyad/audit.log
```

Note: no log rotation — manage file size manually.

### 10. Testing

```bash
# Fast tests (no API calls, no cost)
./test-dyad.sh

# All tests including live supervisor (requires API key, makes API calls)
./test-dyad.sh --all

# Supervisor tests only
./test-dyad.sh --supervisor
```

### 11. Troubleshooting

Brief FAQ:
- **"All my tool calls are being denied"** → Check `ANTHROPIC_API_KEY` is set; check rules file paths match your project directory
- **"Dyad is slow"** → Too many tool calls falling through to supervisor; add more rules for common patterns
- **"Supervisor unavailable" in deny reasons** → API key not set or Claude CLI not authenticated
- **"Permission denied"** → Run `chmod +x dyad.sh`

### 12. License

**Decision needed:** Choose a license. MIT is recommended for developer tools of this nature.

Create a `LICENSE` file alongside the README.

### 13. Contributing (optional, brief)

One paragraph: how to report issues, run tests before submitting PRs.

## Acceptance Criteria

- [x] `README.md` exists at repo root with all sections above
- N/A `LICENSE` file — user opted out
- [x] README renders correctly on GitHub (check headings, code blocks, ASCII diagram)
- [x] All code examples in the README are tested / verified to work
- [x] Hardcoded path warning in rules section is prominent
- [x] `ANTHROPIC_API_KEY` requirement is clearly stated in prerequisites

## Technical Considerations

- **No build/generation step**: README is hand-authored markdown
- **Keep it maintainable**: avoid duplicating information that lives in `dyad.sh --help`; link to the help output or keep them in sync
- **ASCII diagram over Mermaid**: GitHub renders Mermaid, but ASCII is more universally readable and works in terminals

## Sources & References

- Repo structure and feature analysis from local research
- SpecFlow gap analysis identified 20 gaps; key ones addressed: hardcoded paths (Gap 4), API key requirement (Gap 2), fast-path bypass list (Gap 6), troubleshooting (Gap 13), license (Gap 17)
- Architecture details from: `dyad.sh`, `dyad-hook.sh`, `dyad-rules.json`
- Prior art: `docs/brainstorms/2026-03-12-dyad-permission-proxy-brainstorm.md`
