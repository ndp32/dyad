---
status: complete
priority: p2
issue_id: "008"
tags: [code-review, architecture]
dependencies: []
---

# Audit Log Has No Rotation or Size Limit

## Problem Statement

The audit log at `~/.dyad/audit.log` grows unboundedly with no rotation mechanism. A busy session with hundreds of tool calls can generate significant log volume. The README acknowledges this ("No log rotation is built in") but offers no solution.

Additionally, the audit log has no integrity protection — in non-sandbox mode, it is owned by the running user, so Claude Code (same user) could truncate or modify it. There is no hash chaining or append-only filesystem attribute.

## Findings

- `dyad-hook.sh:64` — append-only by convention: `>> ~/.dyad/audit.log`
- Each entry is ~200-500 bytes (tool input truncated to 500 chars)
- 1,000 tool calls = ~500KB; 100,000 calls = ~50MB
- Multiple concurrent sessions write to the same file
- No integrity protection (no `chattr +a`, no hash chaining)

## Proposed Solutions

### Option 1: Size-based rotation (simple)

**Approach:** Check file size before appending. If over threshold (e.g., 10MB), rename to `.audit.log.1` and start fresh.

**Pros:**
- Prevents unbounded growth
- Simple implementation

**Cons:**
- Only keeps 1 backup by default
- Adds a stat + comparison per audit write

**Effort:** 1 hour

**Risk:** Low

---

### Option 2: Session-based rotation

**Approach:** Create a new log file per session (e.g., `audit-${SESSION_ID}.log`) with a symlink `audit.log -> audit-${SESSION_ID}.log`.

**Pros:**
- Clean separation per session
- Easy to correlate with session artifacts

**Cons:**
- Many small files if sessions are frequent
- Need cleanup for old session logs

**Effort:** 1-2 hours

**Risk:** Low

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-hook.sh:50-65` — audit_log function
- `dyad.sh:124` — audit log directory creation

## Acceptance Criteria

- [ ] Audit log does not grow beyond configured size limit
- [ ] Old log data is preserved (rotated, not deleted)
- [ ] Rotation does not corrupt in-flight writes

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Architecture Strategist + Security Sentinel)

## Resources

- **Repo:** https://github.com/ndp32/dyad
