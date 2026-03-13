---
status: pending
priority: p2
issue_id: "006"
tags: [code-review, performance]
dependencies: []
---

# Fast-Path Spawns 4+ Processes Per Read-Only Tool Call

## Problem Statement

The fast-path (Layer 0) for read-only tools (`Read`, `Glob`, `Grep`, etc.) spawns 4 external processes per invocation: `cat` (stdin read), `jq` (tool_name extraction), `date` (audit timestamp), `jq` (audit log entry). On macOS, each process spawn costs ~2-5ms, putting the fast-path floor at ~8-20ms per read-only tool call.

Read-only tools are the most frequent operations in a Claude Code session. A session with 500 read-only calls pays 4-10 seconds of cumulative overhead.

Additionally, throughout the hook, `echo "$VAR" | jq` spawns unnecessary subshells vs `jq <<< "$VAR"`, and rule result extraction uses 4 extra jq processes (lines 155-156).

## Findings

- `dyad-hook.sh:19` — `INPUT=$(cat)` spawns a cat process (bash `$(</dev/stdin)` avoids this)
- `dyad-hook.sh:21` — `echo "$INPUT" | jq` spawns echo + jq (regex extraction avoids both)
- `dyad-hook.sh:94` — audit_log on fast-path spawns date + jq
- `dyad-hook.sh:50-65` — audit_log function always spawns date + jq
- `dyad-hook.sh:155-156` — rule action/reason extraction spawns 4 processes (echo+jq x2)
- `dyad-hook.sh:28-46` — deny tracker uses head + tail (2 process spawns, replaceable with bash `read`)
- echo piping (`echo X | jq`) used 6+ times instead of here-string (`jq <<< X`)

## Proposed Solutions

### Option 1: Optimize fast-path to zero external processes (recommended)

**Approach:**
1. Replace `INPUT=$(cat)` with `INPUT=$(</dev/stdin)` (bash built-in)
2. Extract tool_name via bash regex: `[[ "$INPUT" =~ \"tool_name\":\"([^\"]+)\" ]]`
3. Inline audit logging with printf (no date/jq forks)
4. Replace all `echo X | jq` with `jq <<< X` throughout

**Pros:**
- Fast-path drops from ~8-20ms to <1ms (10-20x improvement)
- Rule-match path drops from ~16-40ms to ~5-10ms (3-4x improvement)
- No behavioral change

**Cons:**
- printf-based date formatting requires bash 4.2+ (`printf '%(%Y-%m-%dT%H:%M:%SZ)T'`); macOS ships bash 3.2
- Regex extraction is fragile if JSON format changes

**Effort:** 2-3 hours

**Risk:** Low (with bash version fallback for date)

---

### Option 2: Partial optimization (macOS 3.2 compatible)

**Approach:** Same as Option 1 but keep `date` call for audit log (macOS bash 3.2 compatibility). Still replace cat, echo|jq, and head/tail.

**Pros:**
- Works on stock macOS bash 3.2
- Still significant improvement (2-3 process spawns saved per call)

**Cons:**
- Not as fast as full optimization

**Effort:** 1-2 hours

**Risk:** Low

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-hook.sh:19` — stdin read
- `dyad-hook.sh:21` — tool_name extraction
- `dyad-hook.sh:50-65` — audit_log function
- `dyad-hook.sh:94` — fast-path audit call
- `dyad-hook.sh:100, 155, 156, 221, 222` — echo|jq patterns
- `dyad-hook.sh:32-33` — head/tail in deny tracker

## Acceptance Criteria

- [ ] Fast-path invocation completes in <2ms (measured)
- [ ] Rule-match path completes in <10ms (measured)
- [ ] All existing tests pass
- [ ] Works on macOS bash 3.2 (or documents bash 4.2+ requirement)
- [ ] Audit log entries are still valid JSON

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Performance Oracle)

## Resources

- **Repo:** https://github.com/ndp32/dyad
