---
title: "refactor: Quick cleanup wins"
type: refactor
status: completed
date: 2026-03-12
origin: todos/004, todos/011, todos/013, todos/015, todos/016
---

# refactor: Quick Cleanup Wins

## Overview

Five small, independent changes that each take under 5 minutes. Batched together because they share a theme: removing dead code, fixing misleading text, and improving robustness. Addresses todos #004, #011, #013, #015, #016.

## Changes

### 1. Remove dead config fields from `dyad-rules.json` (todo #004)

**File:** `dyad-rules.json:2-3`

Delete `default_action` and `fast_path_tools` — they are never read by any code. The hook hardcodes the fast-path list and default-deny behavior.

Before:
```json
{
  "default_action": "supervisor",
  "fast_path_tools": ["Read", "Glob", "Grep", "Explore", "Task*"],
  "rules": [
```

After:
```json
{
  "rules": [
```

### 2. Build hook settings JSON with jq instead of heredoc (todo #011)

**File:** `dyad.sh:105-122`

The current heredoc uses `<<SETTINGS` (not `<<'SETTINGS'`), so shell variables are expanded inside single quotes in the JSON command string. If `RULES_FILE` contains a single quote, the JSON breaks and could allow command injection.

Replace with `jq` construction:

```bash
HOOK_CMD="DYAD_TASK_FILE='${TASK_FILE}' DYAD_RULES_FILE='${RULES_FILE}' DYAD_APPROVE_ALL='${APPROVE_ALL}' DYAD_SESSION_ID='${SESSION_ID}' '${HOOK_SCRIPT}'"

jq -nc \
  --arg cmd "$HOOK_CMD" \
  '{hooks:{PreToolUse:[{matcher:"",hooks:[{type:"command",command:$cmd,timeout:60}]}]}}' \
  > "$HOOK_SETTINGS"
```

This uses `jq --arg` which properly escapes all special characters in the command string, making the JSON always valid regardless of file path characters.

### 3. Simplify timeout to one strategy (todo #013)

**File:** `dyad-hook.sh:166-183`

On macOS, `timeout` and `gtimeout` are not available by default. Replace the three-way branch with the manual approach that works everywhere:

```bash
_timeout_cmd() {
  "$@" &
  local pid=$!
  ( sleep 30; kill "$pid" 2>/dev/null ) &
  local watcher=$!
  wait "$pid" 2>/dev/null
  local ret=$?
  kill "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null
  return $ret
}
```

-8 LOC.

### 4. Use cp/mv for test audit log backup (todo #015)

**File:** `test-dyad.sh:83-98`

The current `AUDIT_LOG_BACKUP=$(cat ...)` / `echo "$AUDIT_LOG_BACKUP" > ...` approach corrupts logs with special characters and loses data if interrupted.

Replace setup (lines 83-88):
```bash
  if [[ -f ~/.dyad/audit.log ]]; then
    cp ~/.dyad/audit.log ~/.dyad/audit.log.test-backup
  fi
  mkdir -p ~/.dyad
  > ~/.dyad/audit.log
```

Replace teardown (lines 91-98):
```bash
teardown() {
  rm -f "$TASK_FILE"
  if [[ -f ~/.dyad/audit.log.test-backup ]]; then
    mv ~/.dyad/audit.log.test-backup ~/.dyad/audit.log
  else
    > ~/.dyad/audit.log
  fi
}
```

Remove the `AUDIT_LOG_BACKUP=""` variable declaration at line 73.

### 5. Fix WebFetch rule comment (todo #016)

**File:** `dyad-rules.json:39`

The action is `deny` but the reason says "requires supervisor approval." Fix the comment to match the actual behavior.

Before:
```json
"reason": "Network access requires supervisor approval"
```

After:
```json
"reason": "Network access blocked by default"
```

## Acceptance Criteria

- [x] `dyad-rules.json` has no `default_action` or `fast_path_tools` fields
- [x] Hook settings JSON is valid even with special characters in file paths
- [x] `_timeout_cmd` is a single implementation (no `timeout`/`gtimeout` branches)
- [x] Test audit log backup uses `cp`/`mv`
- [x] WebFetch deny reason is accurate
- [x] `./test-dyad.sh` passes with 0 failures

## Sources & References

- `todos/004-pending-p2-dead-config-fields.md`
- `todos/011-pending-p2-shell-injection-via-rules-path.md`
- `todos/013-pending-p3-timeout-three-way-branching.md`
- `todos/015-pending-p3-test-audit-log-backup.md`
- `todos/016-pending-p3-webfetch-rule-comment-mismatch.md`
