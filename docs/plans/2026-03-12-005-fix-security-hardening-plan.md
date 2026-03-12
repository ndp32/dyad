---
title: "fix: Security hardening pass"
type: fix
status: completed
date: 2026-03-12
origin: todos/005, todos/006, todos/008, todos/012
---

# fix: Security Hardening Pass

## Overview

Four P2 security improvements that tighten the permission boundary: supervisor environment isolation, fast-path correction, audit log protection, and path traversal prevention. Addresses todos #005, #006, #008, #012.

## Problem Statement / Motivation

After the P1 fixes in Batch 2, these P2 issues represent the next tier of security concerns. None are exploitable in isolation for a single-user tool, but they represent defense-in-depth gaps that matter as the tool matures.

## Proposed Solution

### 1. Supervisor environment isolation (todo #005)

**File:** `dyad-hook.sh:185`

Currently only `CLAUDECODE=` is cleared when calling the supervisor. Replace with `env -i` for full isolation, passing only what's needed.

Before:
```bash
if SUPERVISOR_RESULT=$(CLAUDECODE= _timeout_cmd claude -p --model haiku ...
```

After:
```bash
# Clear inherited environment to prevent recursion and state leakage.
# CLAUDECODE triggers hook inheritance in Claude Code — clearing it prevents
# the supervisor's own tool calls from triggering dyad hooks (infinite recursion).
# We use env -i to also clear any other session-specific state.
if SUPERVISOR_RESULT=$(env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    _timeout_cmd claude -p --model haiku --output-format json --json-schema "$SUPERVISOR_SCHEMA" "$SUPERVISOR_PROMPT" 2>/dev/null); then
```

Note: `_timeout_cmd` is a bash function and `env -i` starts a new environment for the command, but the function is defined in the current shell. We need to inline the timeout logic or pass through differently. The simplest approach is:

```bash
if SUPERVISOR_RESULT=$(_timeout_cmd env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}" \
    claude -p --model haiku --output-format json --json-schema "$SUPERVISOR_SCHEMA" "$SUPERVISOR_PROMPT" 2>/dev/null); then
```

This puts `env -i` inside `_timeout_cmd` so the bash function still works, but the `claude` process itself runs in a clean environment.

### 2. Remove TaskCreate/TaskUpdate from fast-path (todo #006)

**File:** `dyad-hook.sh:57`

These are not read-only tools. Remove them from the fast-path so they go through rule evaluation and potentially supervisor review.

Before:
```bash
  Read|Glob|Grep|Explore|TaskCreate|TaskUpdate|TaskList|TaskGet|TaskOutput|TaskStop)
```

After:
```bash
  Read|Glob|Grep|Explore|TaskList|TaskGet|TaskOutput|TaskStop)
```

Update the test at `test-dyad.sh:132` to match:
```bash
for tool in Read Glob Grep Explore TaskList TaskGet TaskOutput TaskStop; do
```

Add new tests to verify TaskCreate/TaskUpdate are no longer passthrough:
```bash
echo ""
echo "=== Fast-path exclusions ==="

run_hook '{"tool_name":"TaskCreate","tool_input":{"description":"test"}}'
if [[ -n "$HOOK_OUT" ]]; then
  pass "TaskCreate: not passthrough (goes through rules/supervisor)"
else
  fail "TaskCreate: not passthrough" "expected non-passthrough"
fi

run_hook '{"tool_name":"TaskUpdate","tool_input":{"id":"123","status":"done"}}'
if [[ -n "$HOOK_OUT" ]]; then
  pass "TaskUpdate: not passthrough (goes through rules/supervisor)"
else
  fail "TaskUpdate: not passthrough" "expected non-passthrough"
fi
```

### 3. Audit log protections (todo #008)

**File:** `dyad-hook.sh:39`

Two changes:

**(a)** Remove `2>/dev/null` from the audit log write so failures are visible:

Before:
```bash
    >> ~/.dyad/audit.log 2>/dev/null
```

After:
```bash
    >> ~/.dyad/audit.log
```

**(b)** Add a deny rule to `dyad-rules.json` that blocks direct manipulation of the audit log:

```json
{
  "tool": "Bash",
  "action": "deny",
  "match": { "command": "*audit.log*" },
  "reason": "Audit log manipulation blocked"
},
{
  "tool": "Bash",
  "action": "deny",
  "match": { "command": "*.dyad*" },
  "reason": "Dyad config directory manipulation blocked"
}
```

Place these deny rules at the top of the rules array, before any allow rules.

### 4. Path traversal prevention in Edit/Write rules (todo #012)

**File:** `dyad-rules.json:14, 20`

Two problems: `*` in the user path segment allows any user, and `..` traversal is not checked.

If Batch 1's jq-based rule evaluation is already in place, add a `..` check to the jq filter. In the `all(...)` matcher, add:

```jq
and (if $k == "file_path" then ($actual | test("\\.\\.") | not) else true end)
```

This rejects any file path containing `..` from matching an allow rule (it would fall through to the supervisor).

Also narrow the user path in the rules:

Before:
```json
"match": { "file_path": "/Users/*/Documents/dyad/*" }
```

After — use a broader project-root match that doesn't include a wildcard user:
```json
"match": { "file_path": "*/Documents/dyad/*" }
```

Or better yet, accept that the rule is an example and note in a comment that users should customize the path. Since JSON doesn't support comments, add a `"_note"` field:

```json
{
  "tool": "Edit",
  "action": "allow",
  "match": { "file_path": "*/Documents/dyad/*" },
  "reason": "Project file edits are safe",
  "_note": "Customize this path to match your project directory"
}
```

## Technical Considerations

- **`env -i` and API keys:** The supervisor needs `ANTHROPIC_API_KEY` (or equivalent) to authenticate. If the key is set via a different mechanism (e.g., config file), `env -i` won't break it. If it's an env var, we must explicitly pass it through. Test both scenarios.
- **TaskCreate/TaskUpdate removal from fast-path:** These will now be evaluated by rules. Since there are no rules matching these tools, they'll fall through to the supervisor, adding latency. This is acceptable — task creation is infrequent and the security benefit outweighs the cost.
- **`..` check in jq:** The regex `\\.\\.` matches the literal string `..` anywhere in the path. This is slightly aggressive (a file literally named `..something` would be blocked) but this is a very unlikely legitimate case.

## Acceptance Criteria

- [x] Supervisor runs with `env -i` (clean environment) plus only PATH, HOME, USER, ANTHROPIC_API_KEY
- [x] `TaskCreate` and `TaskUpdate` are no longer in the fast-path
- [x] Audit log write failures are not silently swallowed
- [x] Bash commands referencing `audit.log` or `.dyad` are denied by rules
- [x] File paths containing `..` do not match Edit/Write allow rules
- [x] `./test-dyad.sh` passes with 0 failures

## Sources & References

- `todos/005-pending-p2-supervisor-env-isolation.md`
- `todos/006-pending-p2-fast-path-includes-mutation-tools.md`
- `todos/008-pending-p2-audit-log-no-integrity.md`
- `todos/012-pending-p3-path-traversal-in-edit-write-rules.md`
- Current code: `dyad-hook.sh:57, 39, 185`, `dyad-rules.json`
