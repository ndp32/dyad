---
title: "feat: Cross-Platform Portability (macOS to Linux)"
type: feat
status: completed
date: 2026-03-12
origin: docs/brainstorms/2026-03-12-cross-platform-portability-brainstorm.md
---

# feat: Cross-Platform Portability (macOS to Linux)

## Overview

Make Dyad portable across macOS and Linux without code forks or per-environment branches. Every environment difference is handled by a config variable or relative path, not by editing scripts. The immediate target is moving from a personal MacBook to a shared Linux network where the API key lives in `ANTHROPIC_AUTH_TOKEN` and projects live under standard Linux paths.

(see brainstorm: docs/brainstorms/2026-03-12-cross-platform-portability-brainstorm.md)

## Problem Statement

Dyad currently has macOS-specific assumptions baked into multiple files:

- **Hardcoded absolute paths** in `dyad-rules.json` (`*/Documents/dyad/*`) assume a macOS directory layout
- **Hardcoded API key variable name** (`ANTHROPIC_API_KEY`) — the target Linux env uses `ANTHROPIC_AUTH_TOKEN`
- **Deny tracker in world-readable `/tmp`** — a security concern on shared Linux systems
- **macOS-only install messages** — `brew install jq` with no `apt` alternative
- **Machine-specific `.claude/settings.local.json`** tracked in git with absolute paths
- **Hardcoded test paths** (`/Users/someone/Documents/dyad/...`) that fail on Linux

## Proposed Solution

Six coordinated changes, each addressing one portability concern. The guiding principle is **configure, don't fork** (see brainstorm).

---

## Technical Approach

### Phase 1: Core Infrastructure (env vars and path resolution)

These changes establish the foundation that other phases depend on.

#### 1A. Project root detection and `DYAD_PROJECT_ROOT`

**Files:** `dyad.sh`

**Design decision:** `dyad.sh` auto-detects the project root at launch and passes it to the hook via env var. This keeps the detection logic in one place.

Add after the rules file validation block (`dyad.sh:84`):

```bash
# --- Project root resolution ---
if [[ -n "${DYAD_PROJECT_ROOT:-}" ]]; then
  PROJECT_ROOT="$DYAD_PROJECT_ROOT"
elif git rev-parse --show-toplevel >/dev/null 2>&1; then
  PROJECT_ROOT="$(git rev-parse --show-toplevel)"
else
  PROJECT_ROOT="$(pwd)"
fi

# Validate project root
if [[ ! -d "$PROJECT_ROOT" ]]; then
  echo "Error: DYAD_PROJECT_ROOT is not a directory: $PROJECT_ROOT" >&2
  exit 1
fi
if [[ "$PROJECT_ROOT" == "/" || "$PROJECT_ROOT" == "$HOME" ]]; then
  echo "Warning: DYAD_PROJECT_ROOT is very broad ($PROJECT_ROOT) — rules will match many files" >&2
fi
```

Add `PROJECT_ROOT` to the startup banner:

```bash
echo "dyad: Project root: ${PROJECT_ROOT}"
```

#### 1B. Configurable API key variable name

**Files:** `dyad.sh`, `dyad-hook.sh`

**Design decision (resolves brainstorm open question):** Resolve the API key at launch in `dyad.sh`, not at hook time. This is simpler and avoids passing both the variable name and the variable's value through the hook. The hook receives the resolved value as `ANTHROPIC_API_KEY` — exactly what `claude` CLI expects.

Add to `dyad.sh` after project root resolution:

```bash
# --- Resolve API key ---
_API_KEY_VAR="${DYAD_API_KEY_VAR:-ANTHROPIC_API_KEY}"
RESOLVED_API_KEY="${!_API_KEY_VAR:-}"
if [[ -z "$RESOLVED_API_KEY" && "$APPROVE_ALL" != "true" ]]; then
  echo "Warning: API key variable '${_API_KEY_VAR}' is empty — supervisor calls will fail (Layer 2 defaults to deny)" >&2
fi
```

Update `dyad-hook.sh` `env -i` block (line 202-207) to use `DYAD_RESOLVED_API_KEY` from the hook env instead of inheriting `ANTHROPIC_API_KEY`:

```bash
if SUPERVISOR_RESULT=$(_timeout_cmd env -i \
    PATH="$PATH" \
    HOME="$HOME" \
    USER="${USER:-}" \
    ANTHROPIC_API_KEY="${DYAD_RESOLVED_API_KEY:-}" \
    claude -p --model haiku --output-format json --json-schema "$SUPERVISOR_SCHEMA" "$SUPERVISOR_PROMPT" 2>/dev/null); then
```

**Hook command string (final version, constructed in `dyad.sh:108`):**

All env vars from Phases 1-3 are passed in a single command string:

```bash
HOOK_CMD="DYAD_TASK_FILE='${TASK_FILE}' DYAD_RULES_FILE='${RULES_FILE}' DYAD_APPROVE_ALL='${APPROVE_ALL}' DYAD_SESSION_ID='${SESSION_ID}' DYAD_PROJECT_ROOT='${PROJECT_ROOT}' DYAD_SESSION_TMPDIR='${TMPDIR_DYAD}' DYAD_RESOLVED_API_KEY='${RESOLVED_API_KEY}' '${HOOK_SCRIPT}'"
```

This is the single source of truth for the hook invocation — all 7 env vars are listed here.

### Phase 2: Rule engine changes (relative path resolution)

#### 2A. Relative path resolution in jq pipeline

**Files:** `dyad-hook.sh`

**Design decision (resolves SpecFlow gap #1):** Resolution happens in the jq pipeline inside `dyad-hook.sh`. Pass `DYAD_PROJECT_ROOT` as `--arg project_root` to the `jq` call. A pattern is "relative" if it does **not** start with `/` and does **not** start with `*/` (the legacy absolute-path convention). Relative patterns get `$project_root/` prepended before glob-to-regex conversion.

This means existing absolute-path rules continue to work (backward-compatible).

Update the jq call (`dyad-hook.sh:107`). Note: `resolve_pattern` is only applied to `file_path` fields — `command` patterns are left as-is:

```bash
RULE_RESULT=$(jq -c --slurpfile rules "${DYAD_RULES_FILE:-/dev/null}" \
  --arg project_root "${DYAD_PROJECT_ROOT:-}" '
  # Convert glob patterns to anchored regex: * → .*
  def glob_to_regex: "^" + gsub("\\*"; ".*") + "$";

  # Resolve a file_path pattern: prepend project root if relative.
  # "Relative" = does not start with "/" or "*/" (the legacy absolute convention).
  def resolve_pattern:
    if startswith("/") or startswith("*/") then .
    elif $project_root != "" then ($project_root + "/" + .)
    else .
    end;

  # Shell metacharacters that indicate command chaining/injection
  def has_shell_meta: test("[;|&$`()\\n]");

  . as $input |
  ($rules[0].rules // []) |
  reduce .[] as $rule (null;
    if . != null then .  # first match wins
    elif $rule.tool != $input.tool_name then null
    elif ($rule.match // {} | length) == 0 then
      {action: $rule.action, reason: ($rule.reason // "Matched rule")}
    else
      ($rule.match | to_entries | all(
        .key as $k | .value as $pat |
        ($input.tool_input[$k] // "") as $actual |
        ($actual | length) > 0 and
        (if $rule.action == "allow" and $k == "command" and ($actual | has_shell_meta)
         then false
         elif $rule.action == "allow" and $k == "file_path" and ($actual | test("\\.\\."))
         then false
         # Only resolve file_path patterns against project root; leave command patterns as-is
         else ($actual | test((if $k == "file_path" then ($pat | resolve_pattern) else $pat end) | glob_to_regex))
         end)
      )) as $matches |
      if $matches then {action: $rule.action, reason: ($rule.reason // "Matched rule")}
      else null end
    end
  )
' <<< "$INPUT" 2>/dev/null)
```

**Key behavior examples** (assuming `DYAD_PROJECT_ROOT=/home/user/projects/dyad`):

| Rule pattern | Field | Resolved regex | Notes |
|---|---|---|---|
| `"file_path": "src/*"` | file_path | `^/home/user/projects/dyad/src/.*$` | Relative, prepended |
| `"file_path": "*"` | file_path | `^/home/user/projects/dyad/.*$` | Any project file |
| `"file_path": "*/Documents/dyad/*"` | file_path | `^.*/Documents/dyad/.*$` | Legacy absolute (starts with `*/`) |
| `"file_path": "/etc/passwd"` | file_path | `^/etc/passwd$` | Absolute (starts with `/`) |
| `"command": "npm *"` | command | `^npm .*$` | Not a file_path — never resolved |

#### 2B. Update `dyad-rules.json` to use relative paths

**Files:** `dyad-rules.json`

Change the Edit and Write allow rules from absolute to relative patterns:

```json
{
  "tool": "Edit",
  "action": "allow",
  "match": { "file_path": "*" },
  "reason": "Project file edits are safe"
},
{
  "tool": "Write",
  "action": "allow",
  "match": { "file_path": "*" },
  "reason": "Project file writes are safe"
}
```

Remove the `_note` fields — they are no longer needed since paths are relative by default.

**Pattern `*` means:** any file under `$DYAD_PROJECT_ROOT`. The `resolve_pattern` function prepends the project root, so `*` becomes `^/home/user/projects/dyad/.*$`. This scopes file operations to the project directory without hardcoding any path.

### Phase 3: Deny tracker relocation

#### 3A. Move deny tracker into session temp directory

**Files:** `dyad-hook.sh`, `dyad.sh`

**Design decision (resolves brainstorm open question):** Use `DYAD_SESSION_TMPDIR` env var, passed from `dyad.sh` to `dyad-hook.sh` via the hook command string (added in Phase 1A).

Update `dyad-hook.sh` line 23:

```bash
DENY_TRACKER="${DYAD_SESSION_TMPDIR:-/tmp}/dyad-deny-${SESSION_ID}.track"
```

This falls back to `/tmp` if the env var is not set (backward-compatible with direct hook invocation during testing).

Update `dyad.sh` cleanup function (line 101) — remove the now-redundant explicit deny tracker deletion:

```bash
cleanup() { rm -rf "$TMPDIR_DYAD"; }
```

The deny tracker is now inside `$TMPDIR_DYAD`, so `rm -rf "$TMPDIR_DYAD"` cleans it up.

#### 3B. Use `$TMPDIR` instead of hardcoded `/tmp`

**Files:** `dyad.sh`

Update line 88:

```bash
TMPDIR_DYAD=$(mktemp -d "${TMPDIR:-/tmp}/dyad-${SESSION_ID}-XXXXXXXX")
```

This respects per-user temp directories on systemd Linux systems with `PrivateTmp=yes`.

### Phase 4: Platform-aware messaging and docs

#### 4A. Multi-platform `jq` error message

**Files:** `dyad.sh`

Update line 12:

```bash
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found. Install with: brew install jq (macOS) or sudo apt install jq (Linux)" >&2; exit 1; }
```

#### 4B. Gitignore `.claude/settings.local.json`

**Files:** `.gitignore`

Add to `.gitignore`:

```
.claude/settings.local.json
```

Then untrack if currently tracked:

```bash
git rm --cached .claude/settings.local.json 2>/dev/null || true
```

#### 4C. Update README

**Files:** `README.md`

Updates needed:
- Add `~/.local/bin` as alternative install location for Linux
- Document `DYAD_API_KEY_VAR` env var
- Document `DYAD_PROJECT_ROOT` env var
- Update the "Customizing Rules" section to explain relative paths
- Update troubleshooting to mention configurable API key variable

### Phase 5: Test portability

#### 5A. Update hardcoded test paths

**Files:** `test-dyad.sh`

Replace hardcoded macOS paths with dynamically constructed paths using the test's own `SCRIPT_DIR`:

```bash
# Instead of:
#   /Users/someone/Documents/dyad/src/app.js
# Use:
#   ${SCRIPT_DIR}/src/app.js
```

Update all test file_path inputs to use `${SCRIPT_DIR}/...` as the project root analog. Update `DYAD_PROJECT_ROOT` in the test environment to match:

```bash
export DYAD_PROJECT_ROOT="$SCRIPT_DIR"
```

#### 5B. Update deny tracker test paths

The circuit breaker tests (lines 342-389) reference `/tmp/dyad-deny-*.track`. After Phase 3A, the deny tracker lives inside the session temp dir. Update tests to:

1. Set `DYAD_SESSION_TMPDIR` to a test-specific temp directory
2. Assert the deny tracker file is created inside that directory

#### 5C. Add new test cases

New tests to add:

- **`DYAD_PROJECT_ROOT` resolution:** Test that relative rules match when `DYAD_PROJECT_ROOT` is set and file_path is under that root
- **`DYAD_PROJECT_ROOT` miss:** Test that relative rules do NOT match when file_path is outside the project root
- **Legacy absolute rules:** Test that `*/Documents/dyad/*` style patterns still work (backward compatibility)
- **`DYAD_RESOLVED_API_KEY` passthrough:** Test that the hook reads the resolved key (supervisor test, opt-in)
- **Deny tracker in session dir:** Test that `DYAD_SESSION_TMPDIR` is respected for deny tracker location

---

## System-Wide Impact

### Interaction Graph

- `dyad.sh` resolves `DYAD_PROJECT_ROOT` and `DYAD_API_KEY_VAR` at launch → passes resolved values to hook via command string
- `dyad-hook.sh` jq pipeline uses `$project_root` arg to resolve relative patterns before regex matching → affects all rule evaluations for `file_path` fields
- Deny tracker moves from `/tmp` to `$DYAD_SESSION_TMPDIR` → changes where `increment_deny_count` and `reset_deny_count` read/write → `dyad.sh` cleanup function covers it via `rm -rf "$TMPDIR_DYAD"`

### Error Propagation

- Missing `DYAD_PROJECT_ROOT` + not in a git repo → `pwd` used as fallback → warning if too broad
- Empty API key → warning at launch, supervisor calls fail → default deny (existing behavior, now with explicit warning)
- `DYAD_SESSION_TMPDIR` not set (direct hook invocation) → falls back to `/tmp` (backward-compatible)

### State Lifecycle Risks

- No new persistent state. The deny tracker simply moves directories.
- The `.gitignore` change is additive only.

### API Surface Parity

- The hook command string gains 3 new env vars (`DYAD_PROJECT_ROOT`, `DYAD_SESSION_TMPDIR`, `DYAD_RESOLVED_API_KEY`). All are optional with safe fallbacks.

---

## Acceptance Criteria

### Functional Requirements

- [x] `DYAD_API_KEY_VAR=ANTHROPIC_AUTH_TOKEN dyad "task"` resolves the key from `$ANTHROPIC_AUTH_TOKEN` and passes it to the supervisor
- [x] Default behavior (no `DYAD_API_KEY_VAR`) reads from `ANTHROPIC_API_KEY` as before
- [x] Relative rule patterns (e.g., `"file_path": "*"`) match files under `$DYAD_PROJECT_ROOT`
- [x] Relative rule patterns do NOT match files outside `$DYAD_PROJECT_ROOT`
- [x] Legacy absolute patterns (`*/Documents/dyad/*`) continue to work
- [x] Deny tracker file is created inside the session temp directory, not `/tmp`
- [x] `dyad.sh` uses `${TMPDIR:-/tmp}` for temp directory creation
- [x] `jq` error message mentions both `brew` and `apt`
- [x] `.claude/settings.local.json` is in `.gitignore` and untracked
- [x] All tests pass on macOS (no regressions)

### Non-Functional Requirements

- [x] No new dependencies beyond existing `jq`, `bash`, `claude`
- [x] Hook latency unchanged for fast-path tools (Layer 0 exits before any new logic)
- [x] Backward-compatible: existing macOS setups continue working without any env var changes

### Testing Requirements

- [x] Existing test suite passes with updated paths
- [x] New tests for `DYAD_PROJECT_ROOT` resolution (hit/miss)
- [x] New tests for deny tracker location in session temp dir
- [x] New test for legacy absolute-path backward compatibility

## Dependencies & Risks

| Risk | Likelihood | Mitigation |
|------|-----------|------------|
| `resolve_pattern` applied to wrong field | Low | Only apply to `file_path` key in jq pipeline |
| Project root of `/` matches everything | Low | Startup validation with warning |
| Long hook command string with 7 env vars | Medium | Still a single-line string; consider config file if it grows further |
| `${!VAR}` bash indirection not available in all shells | Low | Dyad requires bash (shebang is `#!/bin/bash`); indirection works in bash 3.2+ |

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-12-cross-platform-portability-brainstorm.md](docs/brainstorms/2026-03-12-cross-platform-portability-brainstorm.md) — Key decisions carried forward: configure-don't-fork principle, `DYAD_API_KEY_VAR` indirection, relative path rules, deny tracker relocation into session temp dir

### Internal References

- Hook command string construction: `dyad.sh:108`
- jq rule evaluation pipeline: `dyad-hook.sh:107-139`
- `env -i` supervisor call: `dyad-hook.sh:202-207`
- Deny tracker initialization: `dyad-hook.sh:23`
- Temp dir creation: `dyad.sh:88`
- Cleanup function: `dyad.sh:101`
- Hardcoded rule paths: `dyad-rules.json:24,30`
- Test paths: `test-dyad.sh:179,182,260-276,342-389`

### Design Decisions (resolved during planning)

- **Path resolution mechanism:** jq pipeline with `--arg project_root`, applied only to `file_path` fields (not `command`)
- **Session temp dir communication:** `DYAD_SESSION_TMPDIR` env var in hook command string
- **API key resolution layer:** Resolve at launch in `dyad.sh`, pass literal value as `DYAD_RESOLVED_API_KEY`
- **Hardcoded `/tmp`:** Changed to `${TMPDIR:-/tmp}` for per-user temp dir support
- **Broad project root guard:** Startup validation with warning for `/` or `$HOME`
