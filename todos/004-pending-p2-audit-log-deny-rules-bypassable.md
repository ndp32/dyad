---
status: pending
priority: p2
issue_id: "004"
tags: [code-review, security]
dependencies: []
---

# Edit/Write Tools Bypass Audit Log and .dyad Deny Rules

## Problem Statement

The deny rules protecting `~/.dyad/audit.log` and the `.dyad` directory only target the `Bash` tool. The `Edit` and `Write` tools have wildcard allow rules that could be used to modify the audit log if the project root is set broadly (e.g., `$HOME`). Even for the Bash rules, obfuscation (e.g., `cat ~/.dy'a'd/audit.log`) can bypass the literal glob match.

## Findings

- `dyad-rules.json:2-14` — deny rules only cover `tool: "Bash"`
- `dyad-rules.json:23-31` — Edit/Write allow rules match `file_path: "*"` (resolved to project root)
- `dyad.sh:100-102` — warns about `$HOME` as project root but doesn't prevent it
- Deny rules don't have metacharacter checking (only allow rules do), so obfuscated commands fall through to supervisor
- The supervisor may or may not catch obfuscated audit log access

## Proposed Solutions

### Option 1: Add Edit/Write deny rules for audit infrastructure

**Approach:** Add deny rules for Edit and Write tools targeting `*audit.log*` and `*.dyad*` patterns, placed before the wildcard allows.

**Pros:**
- Defense-in-depth
- Minimal change to rules structure

**Cons:**
- Does not address obfuscation of Bash deny rules

**Effort:** 30 minutes

**Risk:** Low

---

### Option 2: Canonicalize paths before rule matching

**Approach:** Resolve file paths to canonical form using `realpath` before rule evaluation. Also normalize Bash commands by expanding simple quoting.

**Pros:**
- Addresses both Edit/Write and Bash obfuscation vectors
- More robust long-term

**Cons:**
- realpath requires the file to exist (or use `readlink -m` for non-existing paths)
- More complex implementation

**Effort:** 2-3 hours

**Risk:** Medium

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-rules.json` — add Edit/Write deny rules
- `dyad-hook.sh` — optionally add path canonicalization

## Acceptance Criteria

- [ ] `Edit` targeting `~/.dyad/audit.log` is denied
- [ ] `Write` targeting `~/.dyad/audit.log` is denied
- [ ] Tests cover Edit/Write deny rules for audit infrastructure
- [ ] Existing Edit/Write allow rules for project files still work

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Security Sentinel + Architecture Strategist)

## Resources

- **Repo:** https://github.com/ndp32/dyad
