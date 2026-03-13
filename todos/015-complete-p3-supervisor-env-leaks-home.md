---
status: complete
priority: p3
issue_id: "015"
tags: [code-review, security]
dependencies: []
---

# Supervisor env -i Still Passes HOME and USER

## Problem Statement

The supervisor call in `dyad-hook.sh` lines 215-220 uses `env -i` to clear the environment, but still passes `HOME="$HOME"` and `USER`. This allows the supervisor `claude` process to access the user's home directory, including `~/.claude/settings.json`, `~/.bashrc`, and other dotfiles that could alter its behavior or expose sensitive data.

## Findings

- `dyad-hook.sh:215-220` — `env -i PATH="$PATH" HOME="$HOME" USER="${USER:-}" ANTHROPIC_API_KEY=...`
- `HOME` allows the claude process to read `~/.claude/settings.json`
- If Claude settings contain hooks or plugins, the supervisor could trigger unintended side effects
- The claude CLI may require HOME to function (needs testing)

## Proposed Solutions

### Option 1: Set HOME to a temp directory

**Approach:** Set `HOME` to a temporary directory (or `$TMPDIR_DYAD/supervisor-home`) for the supervisor call.

**Pros:**
- Prevents dotfile access
- Clean isolation

**Cons:**
- May require creating minimal config for the claude CLI to function

**Effort:** 1 hour

**Risk:** Medium (claude CLI may need HOME for config/auth)

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-hook.sh:215-220` — supervisor env configuration

## Acceptance Criteria

- [x] Supervisor does not access user's real HOME directory
- [x] Supervisor calls still function correctly
- [x] Claude CLI auth still works with isolated HOME

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Security Sentinel)

## Resources

- **Repo:** https://github.com/ndp32/dyad
