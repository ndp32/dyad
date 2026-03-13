---
status: complete
priority: p2
issue_id: "009"
tags: [code-review, security]
dependencies: []
---

# Deny Tracker Race Condition (TOCTOU)

## Problem Statement

The deny tracker in `dyad-hook.sh` lines 28-46 reads and writes a file without locking. If two hook invocations execute concurrently (possible if Claude Code fires multiple tool calls), a TOCTOU race could corrupt the counter or reset it incorrectly. The `printf > $DENY_TRACKER` write truncates the file before writing, creating a window where another process reads an empty file.

## Findings

- `dyad-hook.sh:28-46` — `increment_deny_count` does read-modify-write without locking
- `head -1` and `tail -1` are separate reads (not atomic)
- `printf '%s\n%d\n' ... > "$DENY_TRACKER"` truncates then writes (not atomic)
- The circuit breaker is informational (changes message text, not behavior), so impact is low
- Additionally, `head` and `tail` are 2 unnecessary process spawns (see performance todo)

## Proposed Solutions

### Option 1: Atomic rename pattern

**Approach:** Write to a temp file, then `mv` into place (atomic on POSIX).

**Pros:**
- No partial reads possible
- Simple change

**Cons:**
- Extra temp file per deny

**Effort:** 30 minutes

**Risk:** Low

---

### Option 2: Use flock for file locking

**Approach:** Wrap the read-modify-write in `flock`.

**Pros:**
- Standard Unix locking mechanism
- Handles concurrent access properly

**Cons:**
- `flock` not available on all macOS versions (needs coreutils)

**Effort:** 1 hour

**Risk:** Medium (portability)

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-hook.sh:28-46` — increment_deny_count and reset_deny_count functions

## Acceptance Criteria

- [ ] Concurrent deny tracking does not corrupt the counter
- [ ] Circuit breaker still fires after 5 consecutive denials
- [ ] No process spawn overhead added (use bash read instead of head/tail)

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Security Sentinel + Architecture Strategist)

## Resources

- **Repo:** https://github.com/ndp32/dyad
