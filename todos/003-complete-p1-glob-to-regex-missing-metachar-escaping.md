---
status: complete
priority: p1
issue_id: "003"
tags: [code-review, security]
dependencies: []
---

# Glob-to-Regex Conversion Does Not Escape Regex Metacharacters

## Problem Statement

The `glob_to_regex` function in `dyad-hook.sh` line 113 only converts `*` to `.*` but does not escape other regex metacharacters (`.`, `+`, `?`, `[`, `]`, `(`, `)`, `{`, `}`, `^`, `$`, `|`, `\`). This means rule patterns containing these characters will be interpreted as regex operators rather than literals.

Any rule with dots in patterns (extremely common in file paths like `*.ts`, `src/*.js`) will have subtly wrong matching. A pattern containing `|` becomes a regex alternation, potentially matching unintended inputs.

## Findings

- `dyad-hook.sh:113` — `def glob_to_regex: "^" + gsub("\\*"; ".*") + "$";`
- The default rule `rm -rf *` becomes regex `^rm -rf .*$` — the `.` before `-rf` matches any character, so `rm Xrf anything` also matches (benign for a deny rule, but incorrect)
- A user rule `file_path: "src/*.ts"` becomes `^src/.*\.ts$` where `.` before `ts` matches any character
- A rule pattern `foo|bar` would match either `foo` or `bar` (regex alternation) instead of the literal string `foo|bar`
- Pattern `npm run build+test` — the `+` is a regex quantifier, matching `buildtest`, `buildttest`, etc.

## Proposed Solutions

### Option 1: Escape regex metacharacters before * conversion

**Approach:** Apply regex escaping to all non-`*` characters before converting `*` to `.*`.

```jq
def glob_to_regex: "^" + (gsub("([.+?^${}()|\\[\\]\\\\])"; "\\\(.)") | gsub("\\*"; ".*")) + "$";
```

**Pros:**
- Fixes the core issue
- Backward compatible (existing patterns continue to work correctly, but now with proper semantics)

**Cons:**
- jq regex escaping is tricky to get right
- Need thorough testing of the escaping function itself

**Effort:** 1-2 hours

**Risk:** Medium (regex escaping in jq is fiddly)

---

### Option 2: Implement actual glob matching instead of regex conversion

**Approach:** Use jq's `test()` with a properly implemented glob matcher, or switch to a different matching strategy.

**Pros:**
- Semantically correct — users expect glob behavior, not regex
- Eliminates the entire class of regex injection bugs

**Cons:**
- jq does not have native glob support, would need a more complex implementation
- Larger code change

**Effort:** 3-4 hours

**Risk:** Medium

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-hook.sh:113` — `glob_to_regex` jq function
- `dyad-hook.sh:145` — usage of `glob_to_regex` in rule evaluation
- `test-dyad.sh` — needs tests for patterns with dots, pipes, etc.

## Acceptance Criteria

- [ ] Rule pattern `*.ts` only matches files ending in `.ts` (not `.Xts`)
- [ ] Rule pattern `rm -rf *` matches exactly `rm -rf ` followed by anything
- [ ] Pattern containing `|` is treated as literal, not regex alternation
- [ ] Pattern containing `+` is treated as literal, not regex quantifier
- [ ] All existing tests pass
- [ ] New tests cover patterns with regex metacharacters

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Security Sentinel + Architecture Strategist)

**Actions:**
- Identified missing regex metacharacter escaping in glob_to_regex
- Analyzed impact on default rules and user-written rules
- Confirmed that existing default rules are mostly unaffected (over-matching on deny rules is fail-safe)

## Resources

- **Repo:** https://github.com/ndp32/dyad
- **jq regex docs:** https://jqlang.github.io/jq/manual/#test
