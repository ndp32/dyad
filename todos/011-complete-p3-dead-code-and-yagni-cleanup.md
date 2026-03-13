---
status: complete
priority: p3
issue_id: "011"
tags: [code-review, quality]
dependencies: []
---

# Dead Code and YAGNI Cleanup (~73 Lines Removable)

## Problem Statement

Several scripts contain dead code, unreachable code paths, and features that aren't needed (YAGNI). These add maintenance burden and potential confusion.

## Findings

- `dyad-sandbox-run.sh:228-236` — **Dead code**: checks `DYAD_SANDBOX_PROJECT_SRC` env var, which is never set by any script in the repo. Completely unreachable.
- `dyad-sandbox-setup.sh:238-269` — **YAGNI**: 32 lines of auto-detect build tools (package.json, Makefile, requirements.txt, pyproject.toml, Cargo.toml). The `--tools` flag already exists for explicit tool specification.
- `dyad-sandbox-setup.sh:305-309` — **YAGNI**: File count warning with misleading `--no-cleanup` hint (which is a flag on `dyad-sandbox-run.sh`, not setup).
- `dyad-sandbox-run.sh:133-140` — **Low value**: Stale workspace detection is redundant with the cleanup function and ephemeral mode.
- `dyad-sandbox-teardown.sh:188-195` — **YAGNI**: Firewall removal instructions for a feature that doesn't exist in the scripts.
- `dyad-sandbox-run.sh:285-288` — **Bug**: Result extraction uses `git diff ${ROOT_COMMIT}..HEAD` which only captures committed changes. Uncommitted working tree changes are lost. Should use `git diff ${ROOT_COMMIT}` (without `..HEAD`) to include working tree state.

## Proposed Solutions

### Option 1: Remove all identified dead code and YAGNI

**Approach:** Delete the identified code blocks. For auto-detect build tools, add examples to `--help` text instead.

**Pros:**
- ~73 lines removed
- Cleaner, more maintainable codebase
- Eliminates confusion from dead code paths

**Cons:**
- Auto-detect was a convenience feature some users might miss

**Effort:** 1 hour

**Risk:** Low

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-sandbox-setup.sh:238-269, 305-309`
- `dyad-sandbox-run.sh:133-140, 228-236, 285-288`
- `dyad-sandbox-teardown.sh:188-195`

## Acceptance Criteria

- [x] Dead `DYAD_SANDBOX_PROJECT_SRC` code removed
- [x] Auto-detect build tools removed, `--help` updated with examples
- [x] File count warning removed
- [x] Firewall note removed from teardown
- [x] Result extraction captures uncommitted changes
- [x] All tests pass

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Code Simplicity Reviewer + Architecture Strategist)

## Resources

- **Repo:** https://github.com/ndp32/dyad
