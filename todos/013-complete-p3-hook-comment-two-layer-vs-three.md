---
status: complete
priority: p3
issue_id: "013"
tags: [code-review, quality]
dependencies: []
---

# Hook Script Comment Says "Two-Layer" But Implements Three Layers

## Problem Statement

The file header in `dyad-hook.sh` lines 5-7 says "Applies a two-layer permission strategy" but the code implements three layers: Layer 0 (fast-path), Layer 1 (rules), Layer 2 (supervisor). The README correctly describes it as three layers.

Additionally, `dyad-hook.sh` deliberately does not use `set -euo pipefail` (unlike all other scripts), but this design choice is not documented.

## Findings

- `dyad-hook.sh:5-7` — comment says "two-layer" but code has three
- `dyad-hook.sh:1` — no `set -euo pipefail` (intentional for error handling but undocumented)

## Proposed Solutions

### Option 1: Update comments

**Approach:** Change "two-layer" to "three-layer" and add a comment explaining the deliberate omission of `set -euo pipefail`.

**Effort:** 10 minutes

**Risk:** None

## Recommended Action

## Technical Details

**Affected files:**
- `dyad-hook.sh:5-7` — header comment
- `dyad-hook.sh:1` — add comment about pipefail omission

## Acceptance Criteria

- [ ] Header comment accurately describes three layers
- [ ] Deliberate omission of `set -euo pipefail` is commented

## Work Log

### 2026-03-13 - Initial Discovery

**By:** Code Review (Architecture Strategist + Code Simplicity Reviewer)

## Resources

- **Repo:** https://github.com/ndp32/dyad
