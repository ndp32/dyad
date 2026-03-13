---
status: complete
priority: p1
issue_id: "001"
tags: [code-review, security]
dependencies: []
---

# API Key Exposed in Process Table via Hook Command String

## Problem Statement

The resolved API key is interpolated directly into the hook command string in `dyad.sh` line 137. This string is written to `hooks.json` on disk and passed to `claude --settings`, making the API key visible in:

1. The temporary `hooks.json` file on disk (readable by any same-user process)
2. Process listings (`ps aux`) every time the hook is invoked
3. On Linux, `/proc/[pid]/cmdline` and `/proc/[pid]/environ`

In non-sandbox mode, Claude Code itself (running as the same user) could exfiltrate the API key by running `ps aux | grep DYAD_RESOLVED_API_KEY` or reading the hooks.json file — completely bypassing the permission system.

## Findings

- `dyad.sh:137` — `HOOK_CMD` embeds `DYAD_RESOLVED_API_KEY='${RESOLVED_API_KEY}'` directly in the command string
- The sandbox mode already uses `DYAD_API_KEY_FILE` for file-based key passing (correct approach)
- The non-sandbox launcher does not use the file-based approach
- `dyad-hook.sh:219` reads `DYAD_RESOLVED_API_KEY` directly and does not support `DYAD_API_KEY_FILE`
- The hooks.json file in `$TMPDIR_DYAD` has mode 700 on the directory, but the key is still visible in the process table

## Proposed Solutions

### Option 1: File-based key passing (recommended)

**Approach:** Write the resolved key to a temp file in `$TMPDIR_DYAD` (already mode 700), pass `DYAD_API_KEY_FILE` in the hook command instead of `DYAD_RESOLVED_API_KEY`. Update `dyad-hook.sh` to read from the file.

**Pros:**
- Consistent with sandbox mode's existing approach
- Key not visible in `ps aux` or procfs
- Minimal code change

**Cons:**
- File I/O on each supervisor call (negligible overhead)

**Effort:** 1-2 hours

**Risk:** Low

---

### Option 2: Named pipe / file descriptor

**Approach:** Pass the key via a file descriptor using bash process substitution.

**Pros:**
- Key never touches disk
- Not visible in process table

**Cons:**
- More complex implementation
- Portability concerns with process substitution across platforms

**Effort:** 3-4 hours

**Risk:** Medium

## Recommended Action

## Technical Details

**Affected files:**
- `dyad.sh:105-113` — key resolution logic
- `dyad.sh:137` — HOOK_CMD construction
- `dyad-hook.sh:219` — supervisor call reads `DYAD_RESOLVED_API_KEY`

## Acceptance Criteria

- [ ] API key is not visible in `ps aux` output during hook invocation
- [ ] API key is not embedded in hooks.json command string
- [ ] `dyad-hook.sh` reads API key from file when `DYAD_API_KEY_FILE` is set
- [ ] Non-sandbox mode uses same file-based approach as sandbox mode
- [ ] Tests pass
- [ ] Supervisor calls still function correctly

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Security Sentinel + Architecture Strategist)

**Actions:**
- Identified API key exposure in process table via hook command string
- Confirmed sandbox mode already has the correct approach (file-based)
- Identified both dyad.sh and dyad-hook.sh need changes

## Resources

- **Repo:** https://github.com/ndp32/dyad
- **Security reference:** OWASP credential storage guidelines
