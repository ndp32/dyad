---
title: "feat: Consecutive-denial circuit breaker and docs update"
type: feat
status: completed
date: 2026-03-12
origin: todos/010, todos/014
---

# feat: Consecutive-Denial Circuit Breaker and Docs Update

## Overview

Implement the consecutive-denial circuit breaker that was specified in the original plan but never built, and update the plan document to match the actual implementation. Addresses todos #010 and #014.

## Problem Statement / Motivation

1. **Circuit breaker (P2, todo #010):** Without this, Claude Code can enter expensive infinite loops when a tool is repeatedly denied: attempt tool → denied → try variation → denied → repeat. Each iteration that reaches the supervisor costs a Haiku API call (~1-5s). The original plan (line 89) specifies: "Track consecutive denials and interrupt after 5 of the same tool type to prevent loops."

2. **Stale plan (P3, todo #014):** The plan document specifies the hook output format as `"decision": {"behavior": "allow"}` with optional `systemMessage` (lines 202-224), but the actual implementation uses `"permissionDecision": "allow"` and `"permissionDecisionReason"`. The plan is marked `status: completed` but doesn't reflect what was built.

## Proposed Solution

### 1. Consecutive-denial circuit breaker (`dyad-hook.sh`)

**Mechanism:** Use a temp file per session to track consecutive denials. The file stores the last-denied tool name and a count. On deny, increment if same tool; reset if different tool. After 5 consecutive denials of the same tool type, return `deny` with an additional `"stopExecution": true` field (or however Claude Code's hook API supports interruption).

Add near the top of `dyad-hook.sh`, after reading `SESSION_ID`:

```bash
# --- Consecutive denial tracking ---
DENY_TRACKER="/tmp/dyad-deny-${DYAD_SESSION_ID:-unknown}.track"

increment_deny_count() {
  local tool="$1"
  local current_tool="" count=0
  if [[ -f "$DENY_TRACKER" ]]; then
    current_tool=$(head -1 "$DENY_TRACKER" 2>/dev/null)
    count=$(tail -1 "$DENY_TRACKER" 2>/dev/null)
  fi
  if [[ "$current_tool" == "$tool" ]]; then
    count=$((count + 1))
  else
    count=1
  fi
  printf '%s\n%d\n' "$tool" "$count" > "$DENY_TRACKER"
  echo "$count"
}

reset_deny_count() {
  rm -f "$DENY_TRACKER"
}
```

Modify `output_deny` to check the counter:

```bash
output_deny() {
  local reason="${1:-Denied by dyad}"
  local count
  count=$(increment_deny_count "$TOOL_NAME")
  reason="${reason//\"/\\\"}"
  if [[ "$count" -ge 5 ]]; then
    # After 5 consecutive denials of the same tool, stop execution
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"dyad denied (5x consecutive): %s"}}\n' "$reason"
  else
    printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":"dyad denied: %s"}}\n' "$reason"
  fi
}
```

Modify `output_allow` to reset the counter:

```bash
output_allow() {
  local reason="${1:-Approved}"
  reset_deny_count
  reason="${reason//\"/\\\"}"
  printf '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":"%s"}}\n' "$reason"
}
```

Add cleanup of the tracker file to `dyad.sh`'s cleanup function:

```bash
cleanup() { rm -rf "$TMPDIR_DYAD" "/tmp/dyad-deny-${SESSION_ID}.track"; }
```

**Note:** The Claude Code hooks API may support `"interrupt": true` or `"stopExecution": true` to halt the agent. Research the current hooks spec during implementation. If no interrupt mechanism exists, the "5x consecutive" prefix in the deny reason at least signals the issue to the user and the inner agent.

### 2. Update plan document (todo #014)

**File:** `docs/plans/2026-03-12-001-feat-claude-code-permission-proxy-plan.md`

Update the "Hook Output Format" section (lines 202-224) to match the actual implementation:

```markdown
### Hook Output Format

On allow:
\`\`\`json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "allow",
    "permissionDecisionReason": "Reason for approval"
  }
}
\`\`\`

On deny:
\`\`\`json
{
  "hookSpecificOutput": {
    "hookEventName": "PreToolUse",
    "permissionDecision": "deny",
    "permissionDecisionReason": "dyad denied: Reason for denial"
  }
}
\`\`\`
```

Also add a note about the circuit breaker being implemented.

### Tests

Add to `test-dyad.sh`:

```bash
echo ""
echo "=== Circuit breaker ==="

# 5 consecutive denials of the same tool should escalate
for i in 1 2 3 4; do
  run_hook '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}'
done
run_hook '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}'
if echo "$HOOK_REASON" | grep -q "5x consecutive"; then
  pass "Circuit breaker: 5th consecutive denial escalates"
else
  fail "Circuit breaker: 5th denial" "expected '5x consecutive' in reason, got: $HOOK_REASON"
fi

# An allow should reset the counter
run_hook '{"tool_name":"Bash","tool_input":{"command":"git status"}}'
assert_decision "Circuit breaker: allow resets counter" "allow"

# After reset, denials start from 1 again
run_hook '{"tool_name":"WebFetch","tool_input":{"url":"https://example.com"}}'
if echo "$HOOK_REASON" | grep -qv "5x consecutive"; then
  pass "Circuit breaker: counter reset after allow"
else
  fail "Circuit breaker: counter reset" "still showing 5x after reset"
fi

# Clean up tracker file
rm -f "/tmp/dyad-deny-${DYAD_SESSION_ID}.track"
```

## Acceptance Criteria

- [x] After 5 consecutive denials of the same tool, deny reason includes "5x consecutive"
- [x] An allow decision resets the consecutive-denial counter
- [x] A denial of a different tool resets the counter for the previous tool
- [x] Tracker file is cleaned up on session exit
- [x] Plan document's Hook Output Format section matches actual implementation
- [x] `./test-dyad.sh` passes with 0 failures

## Dependencies & Risks

| Risk | Mitigation |
|------|-----------|
| Claude Code may not support `interrupt`/`stopExecution` in hook output | Fall back to escalated deny reason text — the inner agent and user still see the signal |
| Tracker file in `/tmp` has same predictability issue | Use session directory from Batch 2 if available, otherwise `/tmp` with mktemp |
| Counter persists across different tools if not properly reset | `increment_deny_count` resets to 1 when tool name changes |

## Sources & References

- `todos/010-pending-p2-missing-consecutive-denial-breaker.md`
- `todos/014-pending-p3-stale-plan-document.md`
- Original plan spec: `docs/plans/2026-03-12-001-feat-claude-code-permission-proxy-plan.md:89`
- Current implementation: `dyad-hook.sh:42-52`
