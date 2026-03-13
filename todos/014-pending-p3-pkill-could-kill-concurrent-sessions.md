---
status: pending
priority: p3
issue_id: "014"
tags: [code-review, architecture]
dependencies: []
---

# pkill -u Could Kill Concurrent Sandbox Sessions

## Problem Statement

The `pkill -u $SANDBOX_USER` in `dyad-sandbox-run.sh:179` and `dyad-sandbox-teardown.sh:107` kills ALL processes owned by the sandbox user, not just those from the current session. If two sandbox sessions run concurrently, one's cleanup would kill the other's processes.

The 1-second sleep after pkill may also be insufficient for all processes to terminate.

## Findings

- `dyad-sandbox-run.sh:179` — `sudo pkill -u $SANDBOX_USER 2>/dev/null || true`
- `dyad-sandbox-teardown.sh:107` — same pattern
- No lock file prevents concurrent sessions
- No PID tracking for session-specific process management

## Proposed Solutions

### Option 1: Track child PIDs explicitly

**Approach:** Store the PID tree in a session file and only kill those specific processes.

**Effort:** 2-3 hours

**Risk:** Medium (process tree tracking in bash is complex)

---

### Option 2: Add a session lock file

**Approach:** Create a lock file that prevents concurrent sandbox runs.

**Effort:** 1 hour

**Risk:** Low

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-sandbox-run.sh:179` — cleanup function
- `dyad-sandbox-teardown.sh:107` — process cleanup

## Acceptance Criteria

- [ ] Concurrent sandbox sessions do not interfere with each other (or are prevented)

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Security Sentinel + Architecture Strategist)

## Resources

- **Repo:** https://github.com/ndp32/dyad
