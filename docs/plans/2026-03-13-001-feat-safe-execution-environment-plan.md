---
title: "feat: Safe Execution Environment (Sandbox User)"
type: feat
status: active
date: 2026-03-13
origin: docs/brainstorms/2026-03-13-safe-execution-environment-brainstorm.md
---

# feat: Safe Execution Environment (Sandbox User)

## Enhancement Summary

**Deepened on:** 2026-03-13
**Sections enhanced:** All major sections
**Research agents used:** Security Sentinel, Architecture Strategist, Code Simplicity Reviewer, Pattern Recognition Specialist, Best Practices Researcher, Claude Code CLI Auth Researcher, Performance Oracle

### Key Improvements

1. **Critical security fixes**: File-based API key passing (not command-line visible via `ps`), root-owned `.bin/` and script directories, symlink-safe cleanup with process termination before teardown
2. **Simplified to ephemeral-only**: Dropped persistent mode (YAGNI) — use `--no-cleanup` flag instead. Dropped `git format-patch` — single `git diff` is sufficient
3. **Confirmed ANTHROPIC_API_KEY is sufficient**: Official docs, GitHub Actions, and Docker sandbox all use API key only — no OAuth tokens needed
4. **nftables recommended over iptables**: Modern Linux default, atomic rule updates, cleaner syntax
5. **Narrow PATH via root-owned symlink directory**: Symlinks to `claude`, `jq`, `git` plus project-detected build tools (npm/node, python3, make). Root-owned to prevent tampering
6. **Symlink-safe cleanup**: All `rm -rf` operations verify target is not a symlink; sandbox processes killed before teardown
7. **Two modifications to `dyad.sh`**: (a) `DYAD_API_KEY_FILE` support for file-based key reading, (b) guard `chmod +x` on hook script for root-owned contexts

### New Considerations Discovered

- API key visible in process table via `ps aux` when passed as env var to sudo (Critical — use temp file instead)
- `git archive HEAD` exports committed state only, NOT the working tree — uncommitted changes are lost (run script warns if tree is dirty)
- `git archive` does NOT respect `.gitignore` — it excludes *untracked* files, but all *tracked* files are included regardless of `.gitignore`
- The run script must NOT use `exec` (unlike `dyad.sh`) because post-run extraction/cleanup must execute
- `umask 077` and `TMPDIR` isolation needed to prevent temp file leakage
- Narrow PATH must include project build tools (npm, node, etc.) — not just claude/jq/git — or Claude Code's Bash tool is useless
- `dyad.sh` line 123 (`chmod +x`) fails on root-owned hook scripts — must be guarded
- `.bin/` directory must be root-owned to prevent sandbox from replacing claude symlink with malicious script

---

## Overview

Add OS-level isolation to Dyad by running it as a dedicated unprivileged user (`dyad-sandbox`). This provides defense-in-depth: even if Dyad's permission layers (rule engine, AI supervisor) are bypassed via prompt injection or hook bugs, the OS kernel prevents reading sensitive files, writing to system directories, or accessing credentials outside the sandbox.

Ship three Bash scripts — setup, run, and teardown — plus documentation. Cross-platform (macOS + Linux).

## Problem Statement

Dyad provides application-level defense-in-depth via its rule engine and AI supervisor, but several residual risks remain (see brainstorm: `docs/brainstorms/2026-03-13-safe-execution-environment-brainstorm.md`):

- **Fast-path bypass**: `Read`/`Glob`/`Grep` operate on any file, including `~/.ssh`, `~/.aws`
- **Supervisor manipulation**: The Haiku supervisor could be manipulated via prompt injection
- **Hook bugs**: A bug in `dyad-hook.sh` could bypass all enforcement
- **No network isolation**: Beyond the `WebFetch` deny rule, no network restrictions exist

A second line of defense at the OS level makes Dyad safe even when its own enforcement fails.

## Proposed Solution

Create a dedicated OS user (`dyad-sandbox`) with minimal privileges. Run Dyad as that user via `sudo`. The OS kernel enforces filesystem and credential isolation. (see brainstorm: Key Decisions #1 — dedicated user over sandbox-exec/bubblewrap for simplicity and cross-platform parity)

### Threat Model

| Threat | Protection |
|--------|-----------|
| Reading `~/.ssh/id_rsa`, `~/.aws/credentials` | Sandbox user has no access to real home directory |
| Writing to `/etc/hosts` or system files | Sandbox user has no write access to system files |
| `rm -rf ~/*` | Sandbox user's `$HOME` is disposable; real home untouched |
| Arbitrary Bash commands | Commands run as unprivileged user with no sudo |
| Credential theft | No credentials in sandbox environment; API key passed via temp file (not env var on command line) |
| API key sniffing via `ps aux` | Key written to file readable only by sandbox user, not visible on process table |
| Privilege re-escalation via sudo | Disabled password (`Password "*"`), shell `/usr/bin/false`, no sudo group membership |
| Symlink escape during cleanup | All `rm -rf` operations verify target is not a symlink before proceeding |

### Out of Scope (Acknowledged)

- **Network exfiltration** — optional firewall hardening documented but not default (see brainstorm: Key Decision #3)
- **CPU/memory abuse** — basic `ulimit` protection included; full cgroups isolation out of scope
- **World-readable files** — inherent Unix limitation (`/etc/passwd`, `/etc/hosts`, parts of `/proc`)
- **Shared kernel exploits** — user-based sandboxing is defense-in-depth, not a full security boundary
- **IPC leakage** — Unix domain sockets, `/dev/shm` are shared; mitigated by `TMPDIR` isolation

## Technical Approach

### Architecture

```
User's machine
├── Real user (you)
│   ├── ~/.ssh, ~/.aws, etc. (PROTECTED — sandbox cannot read)
│   └── /path/to/your/project (original, untouched)
│
├── dyad-sandbox user (no sudo, no login shell, disposable home)
│   ├── HOME=/opt/dyad-workspace
│   │   ├── project/          (copy of your project — sandbox's working directory)
│   │   ├── .bin/              (symlinks to claude, jq, git only)
│   │   ├── .tmp/              (isolated TMPDIR — not shared /tmp)
│   │   ├── .claude/           (minimal Claude Code config)
│   │   ├── .dyad/             (audit log)
│   │   ├── .gitconfig         (minimal git identity)
│   │   └── .dyad-workspace-marker  (canary file for safe teardown)
│   └── Environment: ANTHROPIC_API_KEY (via file), HOME, PATH, TMPDIR
│
├── /opt/dyad/                 (Dyad scripts — root-owned, read-only)
│   ├── dyad.sh
│   ├── dyad-hook.sh
│   └── dyad-rules.json
│
└── OS kernel enforces: sandbox user CANNOT access real user's files
```

### Research Insights: Architecture

**Dyad script accessibility (from Architecture Strategist):** The Dyad scripts (`dyad.sh`, `dyad-hook.sh`, `dyad-rules.json`) must be accessible to the sandbox user but MUST NOT be copied into the workspace (where the sandbox user could tamper with them). Place them in a root-owned, world-readable directory like `/opt/dyad/`. This ensures script integrity — a compromised sandbox process cannot modify its own permission checks.

**Non-exec invocation requirement (from Architecture Strategist):** Unlike `dyad.sh` (which uses `exec claude` at line 148), the run script MUST invoke `dyad.sh` as a subprocess (no `exec`) so that post-run extraction and cleanup logic executes. This is a critical design constraint that must be documented in code comments.

### Deliverables

1. **`dyad-sandbox-setup.sh`** — creates sandbox user, workspace, copies project, installs Dyad scripts to `/opt/dyad/`, configures Claude Code and git
2. **`dyad-sandbox-run.sh`** — wraps `sudo -u dyad-sandbox` with proper env, ephemeral by default with `--no-cleanup` opt-in, extracts results
3. **`dyad-sandbox-teardown.sh`** — removes sandbox user, workspace, and optional firewall rules
4. **Documentation** — README section on sandbox usage
5. **Tests** — sandbox-specific tests in `test-dyad.sh`

### Implementation Phases

#### Phase 1: `dyad-sandbox-setup.sh`

The setup script must be **idempotent** (safe to re-run). (see brainstorm: Resolved Question #1 — ship automation AND document manual steps)

All scripts must include `set -euo pipefail` and `trap cleanup EXIT INT TERM`, matching the existing `dyad.sh` convention. Use `[[ ]]` (not `[ ]`) for all conditionals, matching the codebase's exclusive use of Bash double-bracket conditionals. Organize code with `# --- Section name ---` comment headers.

**Platform detection:**
```bash
detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unsupported" ;;
  esac
}
```

**Dependency checks (run before sudo):**
- `claude` — use `command -v claude` to find actual path. Critical: on Apple Silicon macOS, Homebrew installs to `/opt/homebrew/bin`, which is NOT in the default PATH passed to the sandbox. The script must discover the actual paths of `claude`, `jq`, and `git`.
- `jq` — same discovery logic
- `git` — same discovery logic
- `sudo` — test with `sudo -n true 2>/dev/null` or prompt user
- Error messages must include platform-specific install instructions (matching `dyad.sh` pattern): `"Error: jq not found. Install with: brew install jq (macOS) or sudo apt install jq (Linux)"`

**User creation (with safe UID allocation):**

macOS:
```bash
# --- Create sandbox user (macOS) ---
if dscl . -read /Users/dyad-sandbox &>/dev/null; then
  echo "dyad-sandbox user already exists, skipping creation"
else
  # Find an available UID in the 400-499 service account range (hidden from login window)
  NEXT_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | awk '$1 >= 400 && $1 < 500 {last=$1} END {print (last ? last+1 : 400)}')
  if [[ "$NEXT_UID" -ge 500 ]]; then
    echo "Error: no available UID in range 400-499" >&2; exit 1
  fi

  sudo dscl . -create /Users/dyad-sandbox
  sudo dscl . -create /Users/dyad-sandbox UserShell /usr/bin/false
  sudo dscl . -create /Users/dyad-sandbox UniqueID "$NEXT_UID"
  sudo dscl . -create /Users/dyad-sandbox PrimaryGroupID 20  # staff group — chmod 700 makes group moot
  sudo dscl . -create /Users/dyad-sandbox NFSHomeDirectory /opt/dyad-workspace
  sudo dscl . -create /Users/dyad-sandbox RealName "Dyad Sandbox"
  sudo dscl . -create /Users/dyad-sandbox Password "*"  # Disable password login
fi
```

Note: PrimaryGroupID 20 (`staff`) is acceptable because the workspace uses `chmod 700` (owner-only). Group bits are zero, so group membership has no effect on access control.

Linux:
```bash
# --- Create sandbox user (Linux) ---
if id dyad-sandbox &>/dev/null; then
  echo "dyad-sandbox user already exists, skipping creation"
else
  sudo useradd --system --shell /usr/sbin/nologin --home-dir /opt/dyad-workspace --no-create-home dyad-sandbox
fi
```

#### Research Insights: User Creation

**UID allocation (from Security Sentinel, Simplicity Reviewer):** UIDs 400-499 are hidden from the macOS login window by default. The allocator finds the next available UID in this range with a simple awk one-liner. For a single-user developer tool, a full range-scanning loop is over-engineered.

**macOS staff group is fine with chmod 700 (from Simplicity Reviewer):** The workspace uses `chmod 700` (owner-only), meaning group bits are zero. Group membership is irrelevant — creating a dedicated group adds ~15 lines of complexity for zero security benefit.

**Sudoers — no entry needed (from Security Sentinel):** The sandbox user has a disabled password (`Password "*"`), shell `/usr/bin/false`, and no group memberships that grant sudo. This is sufficient to prevent sudo usage. The `!ALL` negation in sudoers is [unreliable per the sudo manual](https://www.sudo.ws/docs/man/sudoers.man/) — do not rely on it. No `/etc/sudoers.d/dyad-sandbox` file is created.

**Workspace creation:**
```bash
# --- Create workspace ---
sudo mkdir -p /opt/dyad-workspace
sudo chmod 700 /opt/dyad-workspace
sudo chown dyad-sandbox: /opt/dyad-workspace  # Trailing colon = user's default group

# Workspace marker for safe teardown
echo "dyad-sandbox-workspace" | sudo tee /opt/dyad-workspace/.dyad-workspace-marker > /dev/null

# Isolated TMPDIR (not shared /tmp)
sudo -u dyad-sandbox mkdir -p /opt/dyad-workspace/.tmp
```

**Narrow PATH via root-owned symlink directory (from Security Sentinel, Agent-Native Reviewer):**

Instead of adding entire directories (like `/opt/homebrew/bin`) to PATH — which exposes `aws`, `kubectl`, `ssh`, etc. — create a narrow bin directory with symlinks to required binaries. The directory must be **root-owned** to prevent the sandbox user from replacing symlinks with malicious scripts.

Required binaries: `claude`, `jq`, `git` (always), plus project-detected build tools.

```bash
# --- Create narrow PATH directory (root-owned) ---
SANDBOX_BIN="/opt/dyad-workspace/.bin"
sudo mkdir -p "$SANDBOX_BIN"
sudo chown root:root "$SANDBOX_BIN"    # macOS: root:wheel
sudo chmod 755 "$SANDBOX_BIN"

# Always-needed binaries
for cmd in claude jq git; do
  REAL_PATH="$(command -v "$cmd")"
  sudo ln -sf "$REAL_PATH" "$SANDBOX_BIN/$cmd"
done

# Auto-detect project build tools
if [[ -f "$PROJECT_SRC/package.json" ]]; then
  for cmd in npm node npx; do
    REAL_PATH="$(command -v "$cmd" 2>/dev/null)" && sudo ln -sf "$REAL_PATH" "$SANDBOX_BIN/$cmd"
  done
fi
if [[ -f "$PROJECT_SRC/Makefile" ]] || [[ -f "$PROJECT_SRC/makefile" ]]; then
  REAL_PATH="$(command -v make 2>/dev/null)" && sudo ln -sf "$REAL_PATH" "$SANDBOX_BIN/make"
fi
if [[ -f "$PROJECT_SRC/requirements.txt" ]] || [[ -f "$PROJECT_SRC/pyproject.toml" ]]; then
  for cmd in python3 pip pip3; do
    REAL_PATH="$(command -v "$cmd" 2>/dev/null)" && sudo ln -sf "$REAL_PATH" "$SANDBOX_BIN/$cmd"
  done
fi
if [[ -f "$PROJECT_SRC/Cargo.toml" ]]; then
  REAL_PATH="$(command -v cargo 2>/dev/null)" && sudo ln -sf "$REAL_PATH" "$SANDBOX_BIN/cargo"
fi

# User can add extra tools: dyad-sandbox-setup.sh --tools "ruby,rake,bundle"
if [[ -n "${EXTRA_TOOLS:-}" ]]; then
  IFS=',' read -ra TOOLS <<< "$EXTRA_TOOLS"
  for cmd in "${TOOLS[@]}"; do
    REAL_PATH="$(command -v "$cmd" 2>/dev/null)" && sudo ln -sf "$REAL_PATH" "$SANDBOX_BIN/$cmd"
  done
fi
```

**Project copy strategy:**

Use `git archive` for git repos (see brainstorm: Key Decision #2 — copy into workspace).

**Important correction:** `git archive HEAD` exports the **committed state at HEAD**, not the working tree. Uncommitted changes will not be present in the sandbox. Additionally, `git archive` does NOT "respect .gitignore" in the way one might expect — it excludes *untracked* files by nature (since it operates on the git tree), but all *tracked* files are included. If someone has committed `.env` or large binaries, they will be copied. Use `.gitattributes` with `export-ignore` to exclude files from archives.

```bash
# --- Copy project into workspace ---
PROJECT_SRC="$1"  # User provides project path
PROJECT_DEST="/opt/dyad-workspace/project"

# Clean any stale workspace first (symlink-safe)
if [[ -d "$PROJECT_DEST" ]] && [[ ! -L "$PROJECT_DEST" ]]; then
  sudo -u dyad-sandbox find "$PROJECT_DEST" -mindepth 1 -delete 2>/dev/null || true
fi
sudo -u dyad-sandbox mkdir -p "$PROJECT_DEST"

if [[ -d "$PROJECT_SRC/.git" ]]; then
  # Git repo: export committed state (excludes .git dir, untracked files, export-ignore)
  git -C "$PROJECT_SRC" archive HEAD | sudo -u dyad-sandbox tar -x -C "$PROJECT_DEST"
  # Initialize fresh git repo for the diff-based sync workflow
  sudo -u dyad-sandbox bash -c "
    cd '$PROJECT_DEST' &&
    git -c core.compression=0 init &&
    git -c core.compression=0 add -A &&
    git -c core.compression=0 commit -m 'Initial sandbox copy'
  "
else
  # Non-git directory: use rsync with exclusions (not cp -R)
  sudo rsync -a \
    --exclude='.git' --exclude='.env' --exclude='.env.*' \
    --exclude='node_modules' --exclude='.npmrc' \
    --exclude='.ssh' --exclude='.aws' --exclude='.docker' \
    --exclude='*.pem' --exclude='*.key' --exclude='credentials.json' \
    "$PROJECT_SRC/" "$PROJECT_DEST/"
  sudo chown -R dyad-sandbox: "$PROJECT_DEST"
  # Strip any setuid/setgid bits from copied files
  sudo find "$PROJECT_DEST" -perm /6000 -exec chmod ug-s {} + 2>/dev/null || true
  sudo -u dyad-sandbox bash -c "
    cd '$PROJECT_DEST' &&
    git -c core.compression=0 init &&
    git -c core.compression=0 add -A &&
    git -c core.compression=0 commit -m 'Initial sandbox copy'
  "
fi
```

#### Research Insights: Project Copy

**`core.compression=0` (from Performance Oracle):** Disabling zlib compression on the ephemeral git repo eliminates CPU-bound compression during `git add`. Since the repo is disposable, larger loose objects on disk are irrelevant. Expected speedup: 30-50% on `git add -A` for large projects.

**Batched sudo calls (from Performance Oracle, Pattern Recognition):** Grouping `git init` + `git add -A` + `git commit` into a single `sudo -u dyad-sandbox bash -c '...'` call reduces fork+exec overhead from 3 sudo invocations to 1.

**rsync for non-git fallback (from Security Sentinel, High):** `cp -R` copies everything including `.env`, `.npmrc`, credentials. The enhanced plan uses `rsync -a` with an exclusion list. `rsync` is available on both macOS and all major Linux distributions.

**Setuid bit stripping (from Best Practices Researcher):** After copying, strip setuid/setgid bits to prevent privilege escalation via copied binaries.

**File count warning (from Performance Oracle):** Add before the archive step:
```bash
if [[ -d "$PROJECT_SRC/.git" ]]; then
  FILE_COUNT=$(git -C "$PROJECT_SRC" ls-files | wc -l)
  if [[ "$FILE_COUNT" -gt 50000 ]]; then
    echo "Warning: project has $FILE_COUNT tracked files. Sandbox copy may take over 60 seconds."
    echo "Consider using --no-cleanup to avoid re-copying on subsequent runs."
  fi
fi
```

**Install Dyad scripts to root-owned location:**
```bash
# --- Install Dyad scripts (root-owned, read-only) ---
DYAD_SRC="$(cd "$(dirname "$0")" && pwd)"
sudo mkdir -p /opt/dyad
sudo cp "$DYAD_SRC/dyad.sh" "$DYAD_SRC/dyad-hook.sh" "$DYAD_SRC/dyad-rules.json" /opt/dyad/
sudo chmod 755 /opt/dyad/dyad.sh /opt/dyad/dyad-hook.sh
sudo chmod 644 /opt/dyad/dyad-rules.json
sudo chown -R root:root /opt/dyad  # Linux
# macOS: sudo chown -R root:wheel /opt/dyad
```

**Minimal `~/.claude/` setup:**

Claude Code needs a writable `~/.claude/` directory. Confirmed via research: `ANTHROPIC_API_KEY` alone is sufficient for non-interactive operation — no OAuth tokens, browser login, or stored sessions needed. This is validated by the official GitHub Actions integration and Docker sandbox, both of which use only the API key.

```bash
# --- Configure Claude Code ---
sudo -u dyad-sandbox mkdir -p /opt/dyad-workspace/.claude
# Empty settings (dyad.sh passes --settings with hook config at runtime)
echo '{}' | sudo -u dyad-sandbox tee /opt/dyad-workspace/.claude/settings.json > /dev/null
```

**Git identity for sandbox user:**
```bash
# --- Configure git identity ---
sudo -u dyad-sandbox git config --global user.name "dyad-sandbox"
sudo -u dyad-sandbox git config --global user.email "sandbox@dyad.local"
```

**Success criteria:**
- [x] Detects macOS vs Linux and uses correct commands
- [x] Idempotent — safe to run multiple times
- [x] Creates sandbox user with safe UID allocation (400-499 range on macOS)
- [x] Creates workspace with `chmod 700` (owner-only)
- [x] Creates narrow `PATH` directory with symlinks to required binaries (claude, jq, git + project-detected tools)
- [x] Creates isolated `TMPDIR` at `/opt/dyad-workspace/.tmp`
- [x] Installs Dyad scripts to root-owned `/opt/dyad/`
- [x] Copies project via `git archive` (git repos) or `rsync` with exclusions (non-git)
- [x] Strips setuid/setgid bits from copied files
- [x] Initializes git repo in workspace with `core.compression=0`
- [x] Creates minimal `~/.claude/` and `.gitconfig`
- [x] Writes workspace marker file for safe teardown
- [x] Supports `--tools` flag for extra binaries (e.g., `--tools "ruby,rake,bundle"`)
- [x] Supports `--dry-run` flag to print what would be executed without running
- [x] Prints discovered dependency paths for user verification

#### Phase 2: `dyad-sandbox-run.sh`

The run script wraps the `sudo -u dyad-sandbox` invocation. Ephemeral by default — fresh copy each run, destroyed after. Use `--no-cleanup` to skip destruction and reuse on next run. (see brainstorm: Key Decision #5 — workspace lifecycle is user's choice)

#### Research Insights: Simplification

**Ephemeral-only with `--no-cleanup` (from Code Simplicity Reviewer):** The original plan had two full code paths (ephemeral and persistent). This doubles control flow for marginal benefit — the plan itself recommended ephemeral for most cases. The simplified approach: always ephemeral by default. `--no-cleanup` flag simply skips the final destruction step. Users who want "persistent" behavior pass `--no-cleanup` and re-run. This eliminates ~30 lines of branching logic.

**Single `git diff` instead of `format-patch` (from Code Simplicity Reviewer):** `git format-patch` preserves per-commit granularity from a disposable sandbox. Nobody will review individual sandbox commit messages. A single `git diff` against the initial commit is sufficient. One output file, one apply command (`git apply`).

**Interface:**
```bash
dyad-sandbox-run.sh [--no-cleanup] [--rules FILE] [--approve-all] "task description"
```

**Run flow:**
1. If workspace has stale content (from a previous `--no-cleanup` or interrupted run), offer to refresh
2. Fresh copy of project into workspace (unless skipped by prior `--no-cleanup`)
3. If `--rules` specifies a custom rules file, copy it into the sandbox and rewrite the path
4. Warn if the source project has uncommitted changes (dirty tree)
5. Write API key to temp file (not command line)
6. Run dyad.sh as sandbox user (as subprocess — NOT `exec`)
7. Extract results (`git diff`) to user-accessible directory, plus audit log
8. Kill any remaining sandbox processes, then unless `--no-cleanup`, destroy workspace project directory

**Custom `--rules` file handling:**

If the user passes `--rules /path/to/custom-rules.json`, the file must be copied into the sandbox (the sandbox user cannot read arbitrary host paths). The run script rewrites the path before passing to dyad.sh:

```bash
# --- Handle custom rules file ---
if [[ -n "${RULES_FILE:-}" ]]; then
  SANDBOX_RULES="/opt/dyad-workspace/.dyad-rules-custom.json"
  sudo cp "$RULES_FILE" "$SANDBOX_RULES"
  sudo chown root:root "$SANDBOX_RULES"   # Read-only to sandbox
  sudo chmod 644 "$SANDBOX_RULES"
  RULES_FLAG="--rules $SANDBOX_RULES"
else
  RULES_FLAG=""
fi
```

**Dirty-tree warning before `git archive`:**

`git archive HEAD` exports only committed state — uncommitted changes are silently lost. Warn the user:

```bash
# --- Warn about uncommitted changes ---
if [[ -d "$PROJECT_SRC/.git" ]]; then
  DIRTY=$(git -C "$PROJECT_SRC" status --porcelain 2>/dev/null)
  if [[ -n "$DIRTY" ]]; then
    echo "Warning: project has uncommitted changes that will NOT be included in the sandbox."
    echo "  Commit or stash changes first, or they won't be visible to the sandbox."
  fi
fi
```

**API key passing via temp file (from Security Sentinel, Critical):**

Passing `ANTHROPIC_API_KEY` as a command-line environment variable to `sudo` makes it visible to every user on the system via `ps aux` or `/proc/PID/cmdline`. Instead, write the key to a temp file readable only by the sandbox user:

```bash
# --- Pass API key securely ---
# Create file as sandbox user from the start (no ownership transfer race)
KEY_FILE=$(sudo -u dyad-sandbox mktemp /opt/dyad-workspace/.dyad-key-XXXXXXXX)
sudo -u dyad-sandbox chmod 600 "$KEY_FILE"
printf '%s' "$ANTHROPIC_API_KEY" | sudo -u dyad-sandbox tee "$KEY_FILE" > /dev/null

cleanup() {
  sudo rm -f "$KEY_FILE"
  # ... ephemeral cleanup below
}
trap cleanup EXIT INT TERM
```

**Modification to `dyad.sh` — API key file support.** Insert between lines 106-107 (after the `DYAD_API_KEY_VAR` resolution, before the empty-key check):
```bash
# Support file-based API key (used by sandbox mode)
if [[ -z "$RESOLVED_API_KEY" && -n "${DYAD_API_KEY_FILE:-}" && -f "$DYAD_API_KEY_FILE" ]]; then
  RESOLVED_API_KEY="$(cat "$DYAD_API_KEY_FILE")"
fi
```

**Modification to `dyad.sh` — guard chmod +x on hook script.** At line 123, change `chmod +x "$HOOK_SCRIPT"` to:
```bash
[[ -x "$HOOK_SCRIPT" ]] || chmod +x "$HOOK_SCRIPT"
```
This prevents failure when the hook script is root-owned (as in the sandbox).

**PATH construction:**
```bash
# --- Construct sandbox PATH ---
# Narrow bin dir created during setup (contains only claude, jq, git symlinks)
SANDBOX_PATH="/opt/dyad-workspace/.bin:/usr/bin:/bin"
```

**Invocation (as subprocess, not exec):**

Note: `sudo` with `env_reset` (default on most systems) strips environment variables. We use explicit `env` to set variables inside the sandbox context. `ulimit` must also run inside the sandbox user's shell, not outside it.

```bash
# --- Run Dyad as sandbox user ---
# IMPORTANT: Do NOT use exec — post-run extraction must execute
# Use explicit env to survive sudo env_reset; ulimit runs inside sandbox shell
sudo -u dyad-sandbox env \
  DYAD_API_KEY_FILE="$KEY_FILE" \
  DYAD_PROJECT_ROOT=/opt/dyad-workspace/project \
  HOME=/opt/dyad-workspace \
  PATH="$SANDBOX_PATH" \
  TMPDIR=/opt/dyad-workspace/.tmp \
  bash -c '
    umask 077
    ulimit -u 256        # max processes
    ulimit -f 1048576    # max file size (~1GB)
    cd "$DYAD_PROJECT_ROOT"
    exec /opt/dyad/dyad.sh '"$RULES_FLAG"' "$@"
  ' -- "$TASK"

DYAD_EXIT_CODE=$?
```

**Result extraction (after run completes):**

(see brainstorm: Resolved Question #2 — git-based workflow)

```bash
# --- Extract results ---
RESULTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dyad-results-XXXXXXXX")
chmod 700 "$RESULTS_DIR"

# Extract diff against initial commit (captures all changes)
ROOT_COMMIT=$(sudo -u dyad-sandbox env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C /opt/dyad-workspace/project rev-list --max-parents=0 HEAD)
sudo -u dyad-sandbox env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C /opt/dyad-workspace/project diff "${ROOT_COMMIT}..HEAD" > "$RESULTS_DIR/changes.diff"

# Copy audit log into same results directory
if [[ -f /opt/dyad-workspace/.dyad/audit.log ]]; then
  sudo cat /opt/dyad-workspace/.dyad/audit.log > "$RESULTS_DIR/audit.log"
fi

if [[ -s "$RESULTS_DIR/changes.diff" ]]; then
  echo "Results extracted to: $RESULTS_DIR"
  echo "  changes.diff  — apply with: git apply $RESULTS_DIR/changes.diff"
  echo "  audit.log     — sandbox session audit trail"
else
  echo "No changes made in sandbox."
fi
```

#### Research Insights: Result Extraction

**`GIT_CONFIG_GLOBAL=/dev/null` (from Security Sentinel, Low):** The sandbox user controls git config in the workspace. A malicious sandbox process could configure git filters or diff drivers that execute code when `git diff` runs. Using `GIT_CONFIG_GLOBAL=/dev/null` and `GIT_CONFIG_SYSTEM=/dev/null` prevents config injection during extraction.

**`mktemp -d` for results directory (from Pattern Recognition):** The original plan used `mkdir -p` with `date +%s`, which is a race condition (two runs in the same second collide) and inconsistent with the codebase's `mktemp` convention. Use `mktemp -d` with `chmod 700`, matching `dyad.sh`'s temp directory pattern.

**Ephemeral cleanup (symlink-safe, process-aware):**
```bash
# --- Ephemeral cleanup ---
# Kill any lingering sandbox processes BEFORE removing files (TOCTOU: a running
# process could recreate a symlink between our check and rm)
sudo pkill -u dyad-sandbox 2>/dev/null || true
sleep 1  # Brief grace period for process termination

if [[ "$NO_CLEANUP" != "true" ]]; then
  # Verify target is not a symlink before rm -rf (prevents symlink escape attack)
  if [[ -d /opt/dyad-workspace/project ]] && [[ ! -L /opt/dyad-workspace/project ]]; then
    sudo rm -rf /opt/dyad-workspace/project
  fi
  # Clean isolated TMPDIR
  if [[ -d /opt/dyad-workspace/.tmp ]] && [[ ! -L /opt/dyad-workspace/.tmp ]]; then
    sudo rm -rf /opt/dyad-workspace/.tmp
  fi
  # Recreate directories for next run
  sudo -u dyad-sandbox mkdir -p /opt/dyad-workspace/project /opt/dyad-workspace/.tmp
fi
```

#### Research Insights: Cleanup Security

**Kill before cleanup (from Security Sentinel, High — TOCTOU):** A sandbox process could be still running during cleanup and recreate a symlink between the symlink check and the `rm -rf`. Kill all sandbox user processes first with `sudo pkill -u dyad-sandbox` before touching the filesystem.

**`rm -rf` after symlink check (from Performance Oracle):** Once we've verified the path is a real directory (not a symlink) and killed all sandbox processes, `sudo rm -rf` is safe and significantly faster than `find -mindepth 1 -delete` on large trees. The symlink check guards against the attack vector; `find -delete` was belt-and-suspenders overhead.

**Symlink attack via `sudo rm -rf` (from Security Sentinel, High):** If the sandbox process creates a symlink at `/opt/dyad-workspace/project` pointing to `/etc` or `/`, `sudo rm -rf` would follow it and delete the target. The enhanced cleanup: (1) kills all sandbox processes, (2) verifies the path is not a symlink, (3) uses `sudo rm -rf` which is safe after the symlink check.

**Success criteria:**
- [x] Ephemeral by default; `--no-cleanup` skips destruction
- [x] Passes API key via temp file (not command line — not visible in `ps`)
- [x] Uses narrow PATH from symlink directory
- [x] Sets `TMPDIR` to sandbox-owned directory
- [x] Invokes `dyad.sh` as subprocess (not `exec`) so post-run logic executes
- [x] Extracts results as single `git diff` to `mktemp -d` directory with `chmod 700`
- [x] Includes audit log in same results directory
- [x] Uses `GIT_CONFIG_GLOBAL=/dev/null` during extraction to prevent config injection
- [x] Kills sandbox processes before cleanup (TOCTOU prevention)
- [x] Symlink-safe cleanup (verifies path is not a symlink before deletion)
- [x] Copies custom `--rules` file into sandbox and rewrites path
- [x] Passes through `--rules` and `--approve-all` flags to dyad.sh
- [x] Warns if source project has uncommitted changes (dirty tree)
- [x] Sets `DYAD_PROJECT_ROOT` and `cd`s into project dir for correct resolution
- [x] Sets `umask 077` and `ulimit` inside the sandbox shell (not outside)
- [x] Uses `sudo -u dyad-sandbox env ...` to survive `env_reset`
- [x] Detects stale workspaces from interrupted previous runs
- [x] Prints clear instructions for applying the diff

#### Phase 3: `dyad-sandbox-teardown.sh`

Complete removal of the sandbox environment. Uses workspace marker file to verify the directory is a legitimate dyad workspace before deletion.

```bash
# --- Kill any running sandbox processes ---
sudo pkill -u dyad-sandbox 2>/dev/null || true
sleep 1  # Brief grace period

# --- Verify workspace ---
if [[ -f /opt/dyad-workspace/.dyad-workspace-marker ]] && \
   [[ "$(cat /opt/dyad-workspace/.dyad-workspace-marker)" = "dyad-sandbox-workspace" ]] && \
   [[ ! -L /opt/dyad-workspace ]]; then
  sudo rm -rf /opt/dyad-workspace
else
  echo "Error: /opt/dyad-workspace does not appear to be a dyad workspace. Refusing to delete." >&2
  exit 1
fi

# --- Remove Dyad scripts ---
if [[ -d /opt/dyad ]] && [[ ! -L /opt/dyad ]]; then
  sudo rm -rf /opt/dyad
fi

# --- Remove user ---
if [[ "$(detect_platform)" = "macos" ]]; then
  sudo dscl . -delete /Users/dyad-sandbox 2>/dev/null || true
else
  sudo userdel dyad-sandbox 2>/dev/null || true
fi

# --- Note about firewall rules ---
echo "Sandbox removed. If you added firewall rules, remove them manually."
echo "  macOS: edit /etc/pf.conf and run: sudo pfctl -f /etc/pf.conf"
echo "  Linux: sudo nft delete table inet dyad_sandbox"
```

**Success criteria:**
- [x] Verifies workspace marker before deletion (prevents accidental rm -rf of wrong directory)
- [x] Verifies target is not a symlink
- [x] Kills sandbox processes before removing filesystem artifacts
- [x] Removes workspace, Dyad scripts, and user
- [x] Prints instructions for manual firewall rule removal
- [x] Safe to run when sandbox doesn't exist (no errors)
- [x] Supports `--dry-run` flag

#### Phase 4: Documentation

Add a "Sandbox Mode" section to README.md covering:
- Quick start (setup + run + teardown)
- What the sandbox protects against (and what it doesn't — including world-readable files, shared kernel, IPC)
- `--no-cleanup` for iterative work vs default ephemeral mode
- Result extraction workflow (`git apply`)
- `git archive` behavior: exports committed state only (uncommitted changes not included); use `.gitattributes` `export-ignore` to exclude files
- Optional firewall hardening (with corrected rules — see Technical Considerations below)
- Troubleshooting (common issues: PATH problems, Claude Code auth, permission denied on results, CLAUDE.md not loaded — set `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1`)
- Manual setup steps alongside the script (see brainstorm: Resolved Question #1)
- Recommendation to use a separate, lower-privilege API key for sandbox runs
- Project size recommendations table:

| Project size | Ephemeral overhead | Recommendation |
|-------------|-------------------|----------------|
| <1,000 files | <2 seconds | Ephemeral (default) |
| 1,000-10,000 files | 5-15 seconds | Ephemeral acceptable |
| 10,000-50,000 files | 15-60 seconds | Consider `--no-cleanup` |
| >50,000 files | >60 seconds | Use `--no-cleanup` |

#### Phase 5: Tests

Extend `test-dyad.sh` with a `--sandbox` flag (analogous to existing `--supervisor` flag). Use the existing `pass()`/`fail()`/`skip()` assertion helpers.

**Test categories:**
1. **Dry-run / unit tests (no sudo required):**
   - Platform detection logic
   - PATH discovery and symlink bin creation logic
   - `git archive` copy strategy
   - Argument parsing for all three scripts
   - Idempotency checks (user exists / doesn't exist paths)
   - Workspace marker verification logic
   - Symlink-safety checks in cleanup logic

2. **Integration tests (require sudo, opt-in via `--sandbox` flag):**
   - Full setup → run → extract → teardown lifecycle
   - Ephemeral mode: workspace destroyed after run
   - `--no-cleanup` mode: workspace survives after run
   - Audit log included in results directory
   - API key not visible in process table during run
   - Verify sandbox user cannot read real user's home directory
   - Verify sandbox user cannot write to system files
   - Verify sandbox user cannot sudo

**Success criteria:**
- [x] Dry-run tests run without sudo (included in default test suite)
- [x] Integration tests gated behind `--sandbox` flag
- [x] Tests cover both macOS and Linux paths (platform-specific assertions)

## Technical Considerations

### Corrected Firewall Rules

The brainstorm's firewall rules contain bugs that the plan fixes. Additionally, **nftables is recommended over iptables** for modern Linux (default since Debian 10+, Ubuntu 20.04+, RHEL 8+). nftables provides atomic rule updates, unified syntax, and active development.

#### Linux (nftables — recommended)

```bash
SANDBOX_UID=$(id -u dyad-sandbox)
ANTHROPIC_IP=$(dig +short api.anthropic.com | head -1)

sudo nft add table inet dyad_sandbox
sudo nft add chain inet dyad_sandbox output { type filter hook output priority 0 \; }

# Allow DNS resolution
sudo nft add rule inet dyad_sandbox output meta skuid $SANDBOX_UID udp dport 53 accept
sudo nft add rule inet dyad_sandbox output meta skuid $SANDBOX_UID tcp dport 53 accept

# Allow HTTPS to Anthropic API
sudo nft add rule inet dyad_sandbox output meta skuid $SANDBOX_UID tcp dport 443 ip daddr $ANTHROPIC_IP accept

# Block all other outbound
sudo nft add rule inet dyad_sandbox output meta skuid $SANDBOX_UID counter drop
```

Persist with: `sudo nft list ruleset > /etc/nftables.conf`

#### Linux (iptables — legacy fallback)

```bash
# DNS first, then API, then DROP (order matters — first match wins)
sudo iptables -A OUTPUT -m owner --uid-owner dyad-sandbox -p udp --dport 53 -j ACCEPT
sudo iptables -A OUTPUT -m owner --uid-owner dyad-sandbox -p tcp --dport 53 -j ACCEPT
sudo iptables -A OUTPUT -m owner --uid-owner dyad-sandbox -d api.anthropic.com -p tcp --dport 443 -j ACCEPT
sudo iptables -A OUTPUT -m owner --uid-owner dyad-sandbox -j DROP
```

Persist with: `sudo iptables-save > /etc/iptables/rules.v4` or use `netfilter-persistent`.

#### macOS (pf)

```
# --- Dyad sandbox rules (add to /etc/pf.conf) ---
# DNS resolution (required before API hostname can resolve)
pass out quick proto { tcp, udp } to any port 53 user dyad-sandbox
# Allow HTTPS to Anthropic API
pass out quick proto tcp to api.anthropic.com port 443 user dyad-sandbox
# Block all other outbound from sandbox
block out quick proto { tcp, udp } user dyad-sandbox
```

**Caveat:** `pf` resolves `api.anthropic.com` to an IP at rule load time. If the CDN rotates IPs, reload with `sudo pfctl -f /etc/pf.conf`. For production use, consider resolving the IP at setup time and inserting it explicitly.

Apply: `sudo pfctl -f /etc/pf.conf && sudo pfctl -e`

### macOS `sudo` and Shell Interaction

The sandbox user's shell is `/usr/bin/false`. Some `sudo` configurations respect the target user's login shell, which would cause `sudo -u dyad-sandbox` to fail. The run script should use explicit command invocation (`sudo -u dyad-sandbox env ...`) or pass a shell explicitly.

### `dyad.sh` Integration Points

Two modifications to existing `dyad.sh` code are required. Both are backward-compatible (no-op when not in sandbox mode):

**Modification 1 — `DYAD_API_KEY_FILE` support (insert between lines 106-107):**
- `dyad.sh` needs a small addition to read from `DYAD_API_KEY_FILE` if `ANTHROPIC_API_KEY` is not set
- See Phase 2 code block for exact insertion

**Modification 2 — Guard `chmod +x` on hook script (line 123):**
- Change `chmod +x "$HOOK_SCRIPT"` to `[[ -x "$HOOK_SCRIPT" ]] || chmod +x "$HOOK_SCRIPT"`
- Prevents failure when the hook script is root-owned (as in the sandbox at `/opt/dyad/dyad-hook.sh`)

**Existing behavior that works without changes:**
- **Line 87-93** (`DYAD_PROJECT_ROOT` resolution): The run script sets `DYAD_PROJECT_ROOT=/opt/dyad-workspace/project` and `cd`s into the project dir, so `git rev-parse --show-toplevel` resolves correctly.
- **Line 120** (`mkdir -p ~/.dyad`): Works correctly when `HOME=/opt/dyad-workspace` — creates `/opt/dyad-workspace/.dyad/`.
- **Line 148** (`exec claude --settings`): No changes needed — `dyad.sh` uses `exec` internally, which is fine because `dyad-sandbox-run.sh` invokes `dyad.sh` as a subprocess.
- **Lines 215-220** (supervisor `env -i`): Already passes `ANTHROPIC_API_KEY` explicitly — works in sandbox context because `dyad.sh` resolves the key from `DYAD_API_KEY_FILE` first.

### Claude Code Authentication — Confirmed

Research confirms that `ANTHROPIC_API_KEY` alone is sufficient for non-interactive Claude Code operation. Evidence:
- Official GitHub Actions integration uses only `ANTHROPIC_API_KEY` as a repository secret
- Official Docker sandbox uses only `ANTHROPIC_API_KEY`
- Claude Code creates `~/.claude/` on first run for session data — pre-creating the directory avoids potential issues
- CLAUDE.md memory files are NOT loaded in headless mode unless `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` is set
- `claude -p` (print mode, used by the supervisor) has identical auth requirements

### Additional Hardening

**`umask 077` and `ulimit`:** Both are set inside the `sudo -u dyad-sandbox bash -c '...'` invocation (see Phase 2 invocation block). Setting `ulimit` outside the sudo would apply to the calling user, not the sandbox. Setting `umask` inside ensures all sandbox-created files are owner-only.

**CLAUDE.md not loaded in headless mode:** By default, Claude Code does not load CLAUDE.md files when running in headless/programmatic mode. If the project relies on CLAUDE.md for conventions, the run script should set `CLAUDE_CODE_ADDITIONAL_DIRECTORIES_CLAUDE_MD=1` in the sandbox env. This is optional and documented in the README troubleshooting section.

**`GIT_CONFIG_SYSTEM=/dev/null`:** Set during result extraction (alongside `GIT_CONFIG_GLOBAL=/dev/null`) to prevent system-level git config from affecting `git diff` output.

## System-Wide Impact

### Interaction Graph

The sandbox scripts are **external wrappers** around existing `dyad.sh` — they do not modify Dyad's internal behavior. The chain is:

`dyad-sandbox-run.sh` → `sudo -u dyad-sandbox` → `/opt/dyad/dyad.sh` → `claude --settings` → `/opt/dyad/dyad-hook.sh` (on each tool call)

No callbacks, middleware, or observers are added. The existing hook/rule/supervisor pipeline is unchanged. The only modification to existing code is adding `DYAD_API_KEY_FILE` support to `dyad.sh`'s API key resolution.

### Error Propagation

- Setup failures (sudo denied, user creation fails) → script exits with non-zero code and clear message
- Run failures (Claude Code errors, task failure) → propagated through `dyad.sh`'s exit code → `dyad-sandbox-run.sh` still extracts results before cleanup
- Cleanup failures (rm fails, workspace locked) → warning printed, non-zero exit

### State Lifecycle Risks

- **Ephemeral mode partial failure:** If the run is killed (SIGKILL, OOM), cleanup trap won't fire. Orphaned workspace persists. The run script should check for stale workspaces on next invocation (detect presence of project directory without an active PID file).
- **`--no-cleanup` drift:** Workspace can diverge from real project over time. Documentation recommends re-running setup to refresh, or deleting `/opt/dyad-workspace/project` and re-running.

### API Surface Parity

One new internal API: `DYAD_API_KEY_FILE` environment variable in `dyad.sh`. All other interfaces are additive (new scripts, new documentation).

## Acceptance Criteria

### Functional Requirements

- [x] `dyad-sandbox-setup.sh` creates sandbox user, workspace, and Dyad script installation on macOS and Linux
- [x] Setup script is idempotent (safe to re-run)
- [x] Setup creates narrow PATH directory with symlinks to only required binaries
- [x] Setup creates isolated TMPDIR at `/opt/dyad-workspace/.tmp`
- [x] Setup installs Dyad scripts to root-owned `/opt/dyad/`
- [x] Setup uses `git archive` for git repos, `rsync` with exclusions for non-git directories
- [x] `dyad-sandbox-run.sh` runs a task as `dyad-sandbox` in ephemeral mode by default
- [x] `dyad-sandbox-run.sh --no-cleanup` skips workspace destruction
- [x] API key is passed via temp file, not command line
- [x] Results are extracted as single `git diff` to secure temp directory
- [x] Audit log is included in results directory
- [x] `dyad-sandbox-teardown.sh` verifies workspace marker before deletion
- [x] All scripts work on both macOS and Linux
- [x] All scripts support `--dry-run` flag
- [x] `--rules` and `--approve-all` flags pass through to `dyad.sh`

### Non-Functional Requirements

- [x] Workspace permissions are `700` (owner-only, not group-readable)
- [x] macOS sandbox user uses staff group (group bits irrelevant due to `chmod 700`)
- [x] No environment variables leak into sandbox beyond what's explicitly passed
- [x] API key is not visible in process table (`ps aux`)
- [x] Sandbox user cannot access real user's home directory
- [x] Sandbox user cannot sudo
- [x] All `rm -rf` operations are symlink-safe
- [x] Scripts follow existing codebase patterns (`set -euo pipefail`, `trap`, `[[ ]]`, `# --- Section ---` headers)

### Documentation Requirements

- [x] README section: quick start, `--no-cleanup` for iterative work, threat model, result extraction, troubleshooting
- [x] Firewall hardening documented with nftables (primary) and iptables (fallback), including DNS rules
- [x] Manual setup steps documented alongside automated script
- [x] `git archive` limitations documented (committed state only, use `export-ignore`)
- [x] Project size recommendations table

## Dependencies & Prerequisites

- `sudo` access on the machine
- `claude` CLI and `jq` installed and accessible via PATH
- `git` (for `git archive` copy strategy and result sync workflow)
- `rsync` (for non-git project fallback — pre-installed on macOS and most Linux distributions)
- No Docker or container runtime required

## Risk Analysis & Mitigation

| Risk | Likelihood | Impact | Mitigation |
|------|-----------|--------|------------|
| API key visible in process table | ~~High~~ **Eliminated** | High | File-based key passing (not command line) |
| Sandbox user re-escalates via sudo | ~~Medium~~ **Eliminated** | Critical | Disabled password, nologin shell, no sudo group |
| UID collision on macOS | ~~Medium~~ **Eliminated** | Critical | UID range scan in 400-499 (service account range) |
| `sudo` not available in user's environment | Medium | High | Detect early, print clear error with manual alternative steps |
| Apple Silicon PATH excludes `/opt/homebrew/bin` | ~~High~~ **Eliminated** | High | Narrow symlink bin directory |
| `--no-cleanup` workspace drift causes confusing results | Medium | Medium | Document trade-offs; recommend ephemeral for most use cases |
| Ephemeral cleanup fails (SIGKILL, etc.) | Low | Low | Check for stale workspaces on next run; document manual cleanup |
| Symlink escape during cleanup | ~~Medium~~ **Eliminated** | High | Symlink verification before all rm -rf operations |
| Committed secrets copied via git archive | Low | Medium | Document limitation; recommend `.gitattributes` `export-ignore` |
| Large monorepo ephemeral overhead >60s | Medium | Low | File-count warning; `--no-cleanup` recommendation |

## Alternative Approaches Considered

(see brainstorm: Key Decision #1)

- **Docker containers** — More complete isolation but adds a heavy dependency that may not be available in all environments. Rejected.
- **`sandbox-exec` (macOS) / `bubblewrap` (Linux)** — `sandbox-exec` is deprecated on macOS (since 10.15). `bubblewrap` is not installed by default. Different APIs on each platform. Rejected for complexity and portability.
- **Firejail** — Linux-only, requires installation. Does not solve the cross-platform requirement. Rejected.
- **Full PATH directories instead of symlink bin** — Exposes all binaries in `/opt/homebrew/bin` etc. to the sandbox user. Rejected for excessive privilege.
- **`git format-patch` for result extraction** — Preserves per-commit granularity but adds complexity for marginal benefit. Rejected in favor of single `git diff`.
- **Persistent mode as first-class feature** — Doubles code paths and testing matrix. Replaced with `--no-cleanup` flag (simpler, same effect).

## Sources & References

### Origin

- **Brainstorm document:** [docs/brainstorms/2026-03-13-safe-execution-environment-brainstorm.md](docs/brainstorms/2026-03-13-safe-execution-environment-brainstorm.md) — Key decisions carried forward: dedicated unprivileged user approach, git-based result sync, ephemeral+persistent workspace modes (simplified to ephemeral + `--no-cleanup`), optional firewall hardening.

### Internal References

- `dyad.sh:87-93` — project root resolution (must work correctly in sandbox context)
- `dyad.sh:120` — `~/.dyad` directory creation
- `dyad.sh:148` — `exec claude --settings` launch point
- `dyad-hook.sh:64` — audit log path (`~/.dyad/audit.log`)
- `dyad-hook.sh:92-97` — fast-path tools (Read/Glob/Grep still constrained by OS permissions in sandbox)
- `dyad-hook.sh:215-220` — supervisor `env -i` isolation (already passes API key explicitly)
- `test-dyad.sh` — existing test framework with `--supervisor` opt-in pattern to replicate for `--sandbox`

### External References

- [Claude Code headless/programmatic docs](https://code.claude.com/docs/en/headless) — confirms API key auth is sufficient
- [Claude Code GitHub Actions integration](https://code.claude.com/docs/en/github-actions) — uses only `ANTHROPIC_API_KEY`
- [Claude Code devcontainer docs](https://code.claude.com/docs/en/devcontainer) — firewall patterns for sandboxed environments
- [Docker Sandboxes for Claude Code](https://docs.docker.com/ai/sandboxes/agents/claude-code/) — Docker-based sandbox reference
- [nftables wiki: Matching Packet Metainformation](https://wiki.nftables.org/wiki-nftables/index.php/Matching_packet_metainformation) — `meta skuid` for per-user rules
- [OpenBSD pf.conf(5)](https://man.openbsd.org/pf.conf) — macOS pf `user` keyword documentation
- [sudo 1.9.16 secure_path](https://www.sudo.ws/posts/2024/09/why-sudo-1.9.16-enables-secure_path-by-default/) — env_reset and secure_path best practices

### Related Work

- Plan 005: Security hardening (`docs/plans/2026-03-12-005-fix-security-hardening-plan.md`) — env isolation, path traversal prevention
- Plan 008: Cross-platform portability (`docs/plans/2026-03-12-008-feat-cross-platform-portability-plan.md`) — macOS/Linux patterns
