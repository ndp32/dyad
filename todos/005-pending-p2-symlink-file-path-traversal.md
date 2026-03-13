---
status: pending
priority: p2
issue_id: "005"
tags: [code-review, security]
dependencies: []
---

# Symlink-Based File Path Traversal Bypass in Rule Evaluation

## Problem Statement

The rule engine blocks `..` in file paths (path traversal check at `dyad-hook.sh:142`), but does not resolve symlinks. In non-sandbox mode, if Claude Code creates a symlink within the project directory pointing outside it (e.g., `ln -s /etc/passwd src/target`), then edits `src/target`, the rule engine would approve the edit because the path matches `$project_root/*` and contains no `..`. The actual filesystem write would go to `/etc/passwd`.

## Findings

- `dyad-hook.sh:142` — path traversal check: `test("\\.\\."))` only blocks literal `..`
- Edit/Write allow rules with wildcard `*` match any file under project root
- No symlink resolution before rule matching
- Sandbox mode mitigates this (sandbox user has restricted filesystem access)
- Non-sandbox mode is fully vulnerable

## Proposed Solutions

### Option 1: Resolve symlinks with realpath before rule matching

**Approach:** Pre-process `TOOL_INPUT` in bash to resolve `file_path` values using `realpath` before passing to jq.

**Pros:**
- Catches symlink-based traversal
- Works for both Edit and Write tools

**Cons:**
- `realpath` requires the file to exist; use `readlink -m` for non-existing paths
- Adds a process spawn to the non-fast-path

**Effort:** 1-2 hours

**Risk:** Low

---

### Option 2: Add symlink detection in jq (check for symlink at path)

**Approach:** Before rule evaluation, check if the file_path is a symlink and resolve it.

**Pros:**
- Integrated into existing jq pipeline

**Cons:**
- jq cannot check filesystem state — this must be done in bash

**Effort:** 1 hour

**Risk:** Low

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-hook.sh` — add realpath resolution after extracting TOOL_INPUT, before jq rule evaluation
- `test-dyad.sh` — add symlink traversal test

## Acceptance Criteria

- [ ] Edit targeting a symlink pointing outside project root is denied
- [ ] Write targeting a symlink pointing outside project root is denied
- [ ] Normal project file edits still work
- [ ] Tests cover symlink traversal scenario

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Security Sentinel)

## Resources

- **Repo:** https://github.com/ndp32/dyad
