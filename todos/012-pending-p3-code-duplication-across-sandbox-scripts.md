---
status: pending
priority: p3
issue_id: "012"
tags: [code-review, quality]
dependencies: []
---

# Code Duplication Across Sandbox Scripts

## Problem Statement

Several functions and constants are duplicated verbatim across the three sandbox scripts. This creates an implicit contract where changes in one file must be replicated in all three.

## Findings

- `detect_platform()` — identical function in `dyad-sandbox-setup.sh:98-104`, `dyad-sandbox-run.sh:105-111`, `dyad-sandbox-teardown.sh:68-74`
- `run_sudo()` — identical function in `dyad-sandbox-setup.sh:117-122`, `dyad-sandbox-teardown.sh:76-82`
- Hardcoded constants duplicated in all three: `SANDBOX_USER="dyad-sandbox"`, `WORKSPACE="/opt/dyad-workspace"`, `DYAD_INSTALL="/opt/dyad"`, `SANDBOX_BIN="${WORKSPACE}/.bin"`
- `ROOT_GROUP` computation (macOS: wheel, Linux: root) appears in setup (line 170) and run (line 153)

## Proposed Solutions

### Option 1: Extract to shared dyad-lib.sh

**Approach:** Create a `dyad-lib.sh` sourced by all three sandbox scripts containing shared functions and constants.

**Pros:**
- Single source of truth
- ~45 lines removed across three files
- Easier to maintain

**Cons:**
- Scripts no longer fully standalone
- Extra file to ship

**Effort:** 1-2 hours

**Risk:** Low

---

### Option 2: Accept duplication (shell script convention)

**Approach:** Keep as-is. Add a comment in each file noting the duplication.

**Pros:**
- Each script is self-contained and independently runnable
- No sourcing dependencies

**Cons:**
- Risk of divergence over time

**Effort:** 0

**Risk:** Low (for current scale)

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-sandbox-setup.sh`
- `dyad-sandbox-run.sh`
- `dyad-sandbox-teardown.sh`
- New: `dyad-lib.sh` (if Option 1)

## Acceptance Criteria

- [ ] No functional duplication across sandbox scripts (or documented acceptance of duplication)
- [ ] All sandbox tests pass
- [ ] Dry-run mode works for all three scripts

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Code Simplicity Reviewer + Architecture Strategist)

## Resources

- **Repo:** https://github.com/ndp32/dyad
