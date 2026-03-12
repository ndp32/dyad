# Brainstorm: Cross-Platform Portability (macOS to Linux)

**Date:** 2026-03-12
**Status:** Draft

## What We're Building

Make Dyad portable across macOS and Linux environments without requiring code forks or environment-specific branches. The immediate target is moving from a personal MacBook to a shared Linux network at work, where the API key lives in `ANTHROPIC_AUTH_TOKEN` and projects live under standard Linux paths.

## Why This Approach

The guiding principle is **configure, don't fork**. Every environment difference should be handled by a config variable or a relative path, not by editing the scripts themselves. The alternative — maintaining per-environment configs or separate branches — creates drift and makes the project harder to reason about as a single thing.

## Key Decisions

### 1. Configurable API key variable name

- Add `DYAD_API_KEY_VAR` environment variable (defaults to `ANTHROPIC_API_KEY`)
- The `env -i` call in `dyad-hook.sh` reads the key from `${!DYAD_API_KEY_VAR}` and passes it as `ANTHROPIC_API_KEY` to the subprocess (since `claude` CLI expects that name)
- On Linux work env: `export DYAD_API_KEY_VAR=ANTHROPIC_AUTH_TOKEN`

### 2. Relative path rules in dyad-rules.json

- Change path globs from absolute patterns (`*/Documents/dyad/*`) to paths relative to the project root
- The script resolves relative rules against `$DYAD_PROJECT_ROOT` (or auto-detected git root / `pwd`) at runtime
- This eliminates the need to edit `dyad-rules.json` per environment

### 3. Basic shared-system hardening

- Move the deny tracker file from `/tmp/dyad-deny-*.track` into the existing `chmod 700` session temp directory that `dyad.sh` already creates
- This prevents other users on a shared Linux system from reading deny patterns
- No additional hardening beyond this (audit log, XDG_RUNTIME_DIR, etc.)
- **Note:** The hook script currently doesn't know the session temp dir path. The planner will need to solve how `dyad.sh` communicates this path to `dyad-hook.sh` (e.g., via an env var passed through, or a well-known path convention).

### 4. Platform-aware install instructions

- Update `jq` error message in `dyad.sh` to mention both `apt install jq` and `brew install jq`
- Update README install steps to include `~/.local/bin` as an alternative to `/usr/local/bin`
- No changes to the actual install mechanism (clone + chmod + symlink)

### 5. Gitignore .claude/settings.local.json

- Add `.claude/settings.local.json` to `.gitignore`
- This file contains hardcoded absolute paths specific to the dev machine
- Each environment generates its own via Claude Code

### 6. Test portability

- Update `test-dyad.sh` test paths from `/Users/someone/Documents/dyad/...` to use relative paths or dynamically constructed paths that match the new relative-path rules

## Scope

**In scope:**
- `dyad-hook.sh`: configurable API key var, deny tracker relocation
- `dyad-rules.json`: relative path globs + runtime resolution
- `dyad.sh`: platform-aware error messages, path resolution logic
- `test-dyad.sh`: update test paths to match new rules format
- `README.md`: multi-platform install and config docs
- `.gitignore`: add `.claude/settings.local.json`

**Out of scope:**
- Windows/WSL support
- Full multi-user hardening (NFS locking, XDG_RUNTIME_DIR)
- Changing the `claude` CLI's expected env var name
- Automated environment detection / setup scripts

## Open Questions

None — all key decisions resolved during brainstorming.
