---
title: "feat: Claude Code Permission Proxy (dyad)"
type: feat
status: completed
date: 2026-03-12
origin: docs/brainstorms/2026-03-12-dyad-permission-proxy-brainstorm.md
---

# feat: Claude Code Permission Proxy (dyad)

## Overview

Build a shell-based wrapper tool ("dyad") that provides intelligent, autonomous permission management for Claude Code sessions. Dyad launches Claude Code with a hook-based permission interceptor that applies a two-layer approval strategy: rule-based filtering for known patterns, and AI-judged approval via a supervisor Claude instance for unknown patterns.

**Key architectural pivot from brainstorm:** Research revealed that Claude Code has a native **hooks system** with `PreToolUse` events that provide structured JSON communication. This replaces the brainstorm's `expect`-based terminal scraping approach entirely, yielding a more reliable, maintainable, and well-supported architecture (see brainstorm: `docs/brainstorms/2026-03-12-dyad-permission-proxy-brainstorm.md`).

## Problem Statement / Motivation

The current options for uninterrupted Claude Code sessions are unsatisfying (see brainstorm):

- **Manually accepting prompts** interrupts flow and requires babysitting
- **`--dangerously-skip-permissions`** removes all safety guardrails
- **Allowlist settings** require knowing every command pattern in advance

Dyad provides a middle ground: autonomous operation with intelligent oversight. The "dyad" (pair) model keeps a human-compatible safety layer while removing the human bottleneck.

## Proposed Solution

### Architecture (Revised from Brainstorm)

```
User runs: dyad "implement feature X"
                |
                v
    +-----------------------------+
    |   dyad.sh (wrapper)         |
    |                             |
    |  1. Write task to temp file |
    |  2. Write hook config JSON  |
    |  3. Write hook script       |
    |  4. Launch claude with      |
    |     --settings hook.json    |
    +-----------------------------+
                |
                v
        Claude Code (worker)
                |
                | tool call triggers PreToolUse hook
                v
    +-----------------------------+
    |   dyad-hook.sh              |
    |   (receives JSON on stdin)  |
    |                             |
    |  Layer 1: Rule check        |
    |    match allow? -> allow    |
    |    match deny?  -> deny     |
    |    no match?    -> Layer 2  |
    |                             |
    |  Layer 2: Supervisor        |
    |    claude -p --model haiku  |
    |    --output-format json     |
    |    --json-schema <schema>   |
    |    -> allow/deny            |
    |                             |
    |  Output: JSON decision      |
    |  Audit: log to file         |
    |  Deny: systemMessage warn   |
    +-----------------------------+
```

### Key Design Decisions

1. **Use `PreToolUse` hook, not `PermissionRequest`** — `PreToolUse` fires on every tool call regardless of existing permission allowlists, giving dyad complete oversight. `PermissionRequest` only fires when a permission dialog would normally appear, meaning pre-allowed tools silently bypass dyad. (Discovered during research — see brainstorm for original `expect`-based approach.)

2. **Fast-path for read-only tools** — The hook script immediately exits with no output (passthrough) for read-only tools (`Read`, `Glob`, `Grep`, `Explore`) to avoid latency on safe operations.

3. **Structured supervisor output** — Use `claude -p --output-format json --json-schema <schema>` to force the supervisor to return parseable `{"decision": "allow"|"deny", "reason": "..."}` instead of free text.

4. **Temp file configuration injection** — Use `claude --settings /tmp/dyad-hooks-$$.json` to inject hook config without modifying the user's permanent Claude Code settings. Cleanup via `trap` on exit.

5. **Task context via temp file** — Write the original user task to `/tmp/dyad-task-$$.txt` so the hook script can read it and pass it to the supervisor for informed decision-making.

6. **Default deny on supervisor failure** — If the supervisor call fails (timeout, auth error, rate limit), deny the operation and warn the user. Never silently approve.

7. **JSON-only configuration** — Use JSON for the rule config file to avoid a YAML parser dependency in shell. `jq` is the only external dependency beyond `claude` CLI.

8. **Supervisor model: Haiku** — Use `--model haiku` for supervisor calls. Permission judgments are focused yes/no decisions that don't require a frontier model, and Haiku is fast and cheap.

9. **Don't interrupt on deny** — Return `deny` without `interrupt: true` so Claude can try alternative approaches. Track consecutive denials and interrupt after 5 of the same tool type to prevent loops.

10. **Launch Claude in interactive mode** — The user should see Claude Code's normal interactive UI. Dyad is transparent — the hook runs behind the scenes.

## Technical Considerations

### Dependencies

| Dependency | Status | Notes |
|:---|:---|:---|
| `jq` | **Not pre-installed on macOS** | Required for JSON parsing in hook script. Must validate at startup. Install: `brew install jq` |
| `claude` CLI | Required | Must be on PATH for both worker and supervisor |
| `bash` | Pre-installed | Hook script interpreter |

### File Layout

```
dyad/
├── dyad.sh                    # Main wrapper script (entry point)
├── dyad-hook.sh               # PreToolUse hook script
├── dyad-rules.json            # Default rule configuration
├── docs/
│   ├── brainstorms/
│   │   └── 2026-03-12-dyad-permission-proxy-brainstorm.md
│   └── plans/
│       └── (this file)
└── .gitignore
```

### Rule Configuration Schema

`dyad-rules.json`:

```json
{
  "default_action": "supervisor",
  "fast_path_tools": ["Read", "Glob", "Grep", "Explore", "Task*"],
  "rules": [
    {
      "tool": "Edit",
      "action": "allow",
      "match": { "file_path": "/Users/*/Documents/dyad/**" },
      "reason": "Project file edits are safe"
    },
    {
      "tool": "Write",
      "action": "allow",
      "match": { "file_path": "/Users/*/Documents/dyad/**" },
      "reason": "Project file writes are safe"
    },
    {
      "tool": "Bash",
      "action": "allow",
      "match": { "command": "npm *" },
      "reason": "npm commands are safe"
    },
    {
      "tool": "Bash",
      "action": "allow",
      "match": { "command": "git *" },
      "reason": "git commands are safe"
    },
    {
      "tool": "Bash",
      "action": "deny",
      "match": { "command": "rm -rf *" },
      "reason": "Destructive recursive deletion blocked"
    },
    {
      "tool": "WebFetch",
      "action": "deny",
      "match": {},
      "reason": "Network access requires supervisor approval"
    }
  ]
}
```

**Rule evaluation:** First-match-wins, evaluated in array order. Deny rules should be placed before broader allow rules for the same tool type.

### Supervisor Prompt Template

```
You are a security supervisor for an AI coding assistant. The assistant is working on the following task:

TASK: {original_task}

The assistant wants to perform the following operation:
TOOL: {tool_name}
INPUT: {tool_input_json}

Should this operation be approved? Consider:
1. Is this operation relevant to the stated task?
2. Could this operation cause harm (data loss, security exposure, unintended side effects)?
3. Is this a reasonable action for a coding assistant to take?

Respond with your decision.
```

Supervisor JSON schema:
```json
{
  "type": "object",
  "properties": {
    "decision": { "type": "string", "enum": ["allow", "deny"] },
    "reason": { "type": "string" }
  },
  "required": ["decision", "reason"]
}
```

### Hook Output Format

On allow:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "decision": { "behavior": "allow" }
  }
}
```

On deny:
```json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "decision": {
      "behavior": "deny",
      "message": "Denied by dyad: {reason}"
    },
    "systemMessage": "⚠️ DYAD DENIED: {tool_name} — {reason}"
  }
}
```

### Audit Log Format

JSON Lines at `~/.dyad/audit.log`:

```json
{"ts":"2026-03-12T14:30:00Z","session":"abc123","tool":"Bash","input":"npm test","decision":"allow","source":"rule","reason":"npm commands are safe"}
{"ts":"2026-03-12T14:30:05Z","session":"abc123","tool":"WebFetch","input":"https://api.example.com","decision":"deny","source":"supervisor","reason":"Network access not relevant to task"}
```

Fields: `ts` (ISO 8601), `session` (from hook JSON `session_id`), `tool`, `input` (truncated to 500 chars), `decision`, `source` ("rule"/"supervisor"/"approve-all"/"fast-path"), `reason`.

## System-Wide Impact

- **Interaction graph**: dyad.sh spawns Claude Code → Claude Code makes tool calls → PreToolUse hook fires → hook script evaluates rules → optionally calls supervisor Claude → returns decision → Claude Code continues or adjusts
- **Error propagation**: Hook script errors (non-zero exit, non-2) are "non-blocking" per Claude Code docs — execution continues and the normal permission dialog appears. This is a safe fallback but means dyad silently loses oversight. The hook script must handle all errors internally and always exit 0 with a valid JSON decision.
- **State lifecycle risks**: Temp files (`/tmp/dyad-hooks-*.json`, `/tmp/dyad-task-*.txt`) could accumulate on abnormal exit. Mitigated by `trap` cleanup and `/tmp` auto-cleanup.
- **Integration test scenarios**: (1) Rule-matched allow passes through without supervisor call. (2) Rule-matched deny blocks and logs. (3) Unmatched request invokes supervisor and respects its decision. (4) Supervisor failure defaults to deny. (5) Fast-path tools skip all evaluation.

## Acceptance Criteria

### Phase 1: Validate Assumptions & Minimal Prototype
- [x] **Validate `--settings` flag**: Confirm `claude --settings <file>` merges hook config with existing user settings (not overrides). If it doesn't work, fall back to writing `.claude/settings.local.json` with `trap` cleanup.
- [x] **Validate structured supervisor output**: Confirm `claude -p --output-format json --json-schema <schema>` reliably returns parseable JSON. If unavailable, fall back to keyword parsing with "if ambiguous, deny" policy.
- [x] `dyad.sh` accepts a task string argument and launches Claude Code with a PreToolUse hook
- [x] Hook script (`dyad-hook.sh`) receives JSON on stdin, logs it, and returns an allow decision
- [x] Verify hook fires on Bash tool calls by checking the log
- [x] Temp files are cleaned up on normal exit via `trap`
- [x] `jq` availability is validated at startup with a helpful error message

### Phase 2: Rule Engine
- [x] Hook script reads `dyad-rules.json` and evaluates rules against incoming tool calls
- [x] Fast-path tools (`Read`, `Glob`, `Grep`) exit immediately without evaluation
- [x] First-match-wins evaluation using `jq` to extract tool input fields, then bash `case` statements with glob patterns for matching
- [x] Rule-based allow and deny decisions are returned as proper JSON
- [x] All decisions (including fast-path) are audit-logged to `~/.dyad/audit.log`

### Phase 3: Supervisor Integration
- [x] Unmatched tool calls invoke `claude -p --model haiku --output-format json --json-schema <schema>` with the supervisor prompt
- [x] Original task context is passed to the supervisor via temp file
- [x] Supervisor JSON response is parsed into allow/deny decision
- [x] Supervisor failures (timeout, error) default to deny with warning
- [x] Supervisor timeout is set to 30 seconds

### Phase 4: Polish
- [x] `--approve-all` flag bypasses all evaluation and auto-approves (still logs)
- [x] Denied operations show `permissionDecisionReason` in Claude Code UI
- [x] Help text via `dyad --help`

## Success Metrics

- Dyad can run a full Claude Code task autonomously with zero manual permission approvals
- Rule-matched decisions resolve in <50ms (no supervisor latency)
- Supervisor decisions resolve in <5s (Haiku is fast)
- Audit log captures every permission decision for post-session review
- No permission requests silently bypass dyad (verified by PreToolUse coverage)

## Dependencies & Risks

| Risk | Impact | Mitigation |
|:---|:---|:---|
| `jq` not installed | Hook script cannot parse JSON | Validate at startup, print install instructions (`brew install jq`) |
| `--settings` flag doesn't merge hooks correctly | Dyad hooks not registered | Test in Phase 1 prototype; fallback to writing `.claude/settings.local.json` with cleanup |
| Supervisor adds too much latency | Sluggish developer experience | Invest in comprehensive rules to minimize supervisor calls; use Haiku for speed |
| Concurrent hook invocations race on audit log | Corrupted log entries | Use `flock` or append atomically (JSON Lines format, one write per line) |
| Claude Code hooks API changes | Breaking changes to hook JSON schema | Pin to known-working Claude Code version; monitor changelog |
| Supervisor hallucinates approval of dangerous ops | Security gap | Default rules should deny the most dangerous patterns (rm -rf, network access) before reaching supervisor |

## Implementation Notes

### `dyad.sh` outline

```bash
#!/bin/bash
set -euo pipefail

# Validate dependencies
command -v claude >/dev/null || { echo "Error: claude CLI not found"; exit 1; }
command -v jq >/dev/null || { echo "Error: jq not found. Install with: brew install jq"; exit 1; }

# Parse arguments
APPROVE_ALL=false
RULES_FILE="$(dirname "$0")/dyad-rules.json"
TASK=""
# ... argument parsing ...

# Generate session files
SESSION_ID="dyad-$$-$(date +%s)"
HOOK_SETTINGS="/tmp/dyad-hooks-${SESSION_ID}.json"
TASK_FILE="/tmp/dyad-task-${SESSION_ID}.txt"
HOOK_SCRIPT="$(cd "$(dirname "$0")" && pwd)/dyad-hook.sh"

# Cleanup on exit
cleanup() { rm -f "$HOOK_SETTINGS" "$TASK_FILE"; }
trap cleanup EXIT INT TERM

# Write task context
echo "$TASK" > "$TASK_FILE"

# Write hook settings
cat > "$HOOK_SETTINGS" <<SETTINGS
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "DYAD_TASK_FILE=$TASK_FILE DYAD_RULES_FILE=$RULES_FILE DYAD_APPROVE_ALL=$APPROVE_ALL $HOOK_SCRIPT"
          }
        ]
      }
    ]
  }
}
SETTINGS

# Launch Claude Code
claude --settings "$HOOK_SETTINGS" "$TASK"
```

### `dyad-hook.sh` outline

```bash
#!/bin/bash
# Reads PreToolUse JSON from stdin, applies rules, optionally calls supervisor

INPUT=$(cat)
TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name')

# Fast path: read-only tools
case "$TOOL_NAME" in
  Read|Glob|Grep|Explore|Task*) exit 0 ;;
esac

# Approve-all mode
if [ "$DYAD_APPROVE_ALL" = "true" ]; then
  # Log and allow
  echo '{"hookSpecificOutput":{"hookEventName":"PreToolUse","decision":{"behavior":"allow"}}}'
  exit 0
fi

# Rule evaluation
# ... match against DYAD_RULES_FILE ...

# Supervisor fallback
# ... call claude -p with structured output ...
```

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-12-dyad-permission-proxy-brainstorm.md](docs/brainstorms/2026-03-12-dyad-permission-proxy-brainstorm.md) — Key decisions carried forward: shell script implementation, two-layer approval strategy (rules + AI supervisor), audit logging, personal tool scope. Architecture pivoted from `expect`-based terminal scraping to Claude Code hooks.

### External References

- [Claude Code Hooks Guide](https://code.claude.com/docs/en/hooks-guide) — PreToolUse event, hook JSON schema, decision format
- [Claude Code Hooks Reference](https://code.claude.com/docs/en/hooks) — Hook configuration, timeout, exit code semantics
- [Claude Code Permissions](https://code.claude.com/docs/en/permissions) — Permission modes, allowlists, `--dangerously-skip-permissions`

### Brainstorm Open Questions (Resolved)

1. **Session history access** — Not needed for v1. The hook receives structured JSON with tool context; the original task is passed via temp file.
2. **`expect` availability** — Moot. Hooks replace `expect` entirely.
