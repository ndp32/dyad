#!/bin/bash
set -euo pipefail

# dyad-sandbox-run.sh — run Dyad as a sandboxed unprivileged user
#
# Ephemeral by default: fresh project copy each run, destroyed after.
# Use --no-cleanup to skip destruction and reuse the workspace on next run.
#
# Usage:
#   dyad-sandbox-run.sh [OPTIONS] "task description"
#
# Options:
#   --no-cleanup        Skip workspace destruction after run
#   --rules <file>      Path to custom rules JSON file
#   --approve-all       Auto-approve all tool calls
#   --dry-run           Print what would be executed without running
#   --help              Show this help message

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Shared library ---
# shellcheck source=dyad-lib.sh
source "${SCRIPT_DIR}/dyad-lib.sh"

PROJECT_DEST="${WORKSPACE}/project"

# --- Argument parsing ---
NO_CLEANUP=false
DRY_RUN=false
RULES_FILE=""
APPROVE_ALL=false
TASK=""

usage() {
  cat <<'EOF'
Usage: dyad-sandbox-run.sh [OPTIONS] "task description"

Run Dyad as a sandboxed unprivileged user.

Options:
  --no-cleanup        Skip workspace destruction after run (reuse on next run)
  --rules <file>      Path to custom rules JSON file
  --approve-all       Auto-approve all tool calls
  --dry-run           Print what would be executed without running
  --help              Show this help message

Examples:
  dyad-sandbox-run.sh "implement the login page"
  dyad-sandbox-run.sh --no-cleanup "refactor the auth module"
  dyad-sandbox-run.sh --rules custom-rules.json "fix the tests"
  dyad-sandbox-run.sh --approve-all "update dependencies"
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-cleanup)
      NO_CLEANUP=true
      shift
      ;;
    --rules)
      [[ $# -lt 2 ]] && { echo "Error: --rules requires a file path argument." >&2; exit 1; }
      RULES_FILE="$2"
      shift 2
      ;;
    --approve-all)
      APPROVE_ALL=true
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Run 'dyad-sandbox-run.sh --help' for usage." >&2
      exit 1
      ;;
    *)
      if [[ -z "$TASK" ]]; then
        TASK="$1"
      else
        TASK="$TASK $1"
      fi
      shift
      ;;
  esac
done

if [[ -z "$TASK" ]]; then
  echo "Error: No task provided." >&2
  echo "Run 'dyad-sandbox-run.sh --help' for usage." >&2
  exit 1
fi

[[ "$DRY_RUN" == "true" ]] && echo "dyad-sandbox-run: *** DRY RUN — no changes will be made ***"

PLATFORM=$(detect_platform)

# --- Pre-flight checks ---

if ! id $SANDBOX_USER &>/dev/null; then
  echo "Error: Sandbox user '$SANDBOX_USER' does not exist. Run dyad-sandbox-setup.sh first." >&2
  exit 1
fi

if [[ ! -d "$WORKSPACE" ]]; then
  echo "Error: Workspace '$WORKSPACE' does not exist. Run dyad-sandbox-setup.sh first." >&2
  exit 1
fi

if [[ ! -f "$DYAD_INSTALL/dyad.sh" ]]; then
  echo "Error: Dyad scripts not found at $DYAD_INSTALL. Run dyad-sandbox-setup.sh first." >&2
  exit 1
fi

# --- Acquire session lock (prevents concurrent sandbox runs) ---
if [[ "$DRY_RUN" != "true" ]]; then
  acquire_session_lock || exit 1
fi

# --- Handle custom rules file ---
RULES_FLAG=""
if [[ -n "$RULES_FILE" ]]; then
  if [[ ! -f "$RULES_FILE" ]]; then
    echo "Error: Rules file not found: $RULES_FILE" >&2
    exit 1
  fi
  SANDBOX_RULES="${WORKSPACE}/.dyad-rules-custom.json"
  if [[ "$DRY_RUN" != "true" ]]; then
    sudo cp "$RULES_FILE" "$SANDBOX_RULES"
    ROOT_GROUP=$(resolve_root_group "$PLATFORM")
    sudo chown root:${ROOT_GROUP} "$SANDBOX_RULES"
    sudo chmod 644 "$SANDBOX_RULES"
  fi
  RULES_FLAG="--rules $SANDBOX_RULES"
  echo "dyad-sandbox-run: Custom rules copied to sandbox: $SANDBOX_RULES"
fi

# --- Build dyad.sh flags ---
DYAD_FLAGS="$RULES_FLAG"
if [[ "$APPROVE_ALL" == "true" ]]; then
  DYAD_FLAGS="$DYAD_FLAGS --approve-all"
fi

# --- Cleanup function ---
KEY_FILE=""

cleanup() {
  local exit_code=$?

  # Remove API key file
  if [[ -n "$KEY_FILE" ]]; then
    sudo rm -f "$KEY_FILE" 2>/dev/null || true
  fi

  # Kill any lingering sandbox processes BEFORE removing files
  sudo pkill -u $SANDBOX_USER 2>/dev/null || true
  sleep 1

  if [[ "$NO_CLEANUP" != "true" ]]; then
    # Verify target is not a symlink before rm -rf
    if [[ -d "$PROJECT_DEST" ]] && [[ ! -L "$PROJECT_DEST" ]]; then
      sudo rm -rf "$PROJECT_DEST"
    fi
    # Clean isolated TMPDIR
    if [[ -d "${WORKSPACE}/.tmp" ]] && [[ ! -L "${WORKSPACE}/.tmp" ]]; then
      sudo rm -rf "${WORKSPACE}/.tmp"
    fi
    # Recreate directories for next run
    sudo -u $SANDBOX_USER mkdir -p "$PROJECT_DEST" "${WORKSPACE}/.tmp"
    echo "dyad-sandbox-run: Workspace cleaned (ephemeral mode)"
  else
    echo "dyad-sandbox-run: Workspace preserved (--no-cleanup)"
  fi

  # Clean custom rules file
  if [[ -n "${SANDBOX_RULES:-}" ]] && [[ -f "${SANDBOX_RULES:-}" ]]; then
    sudo rm -f "$SANDBOX_RULES"
  fi

  # Release session lock
  release_session_lock

  return $exit_code
}

if [[ "$DRY_RUN" != "true" ]]; then
  trap cleanup EXIT INT TERM
fi

# --- Pass API key securely ---
echo "dyad-sandbox-run: Preparing API key..."

ANTHROPIC_API_KEY="${ANTHROPIC_API_KEY:-}"
if [[ -z "$ANTHROPIC_API_KEY" && "$APPROVE_ALL" != "true" ]]; then
  echo "Warning: ANTHROPIC_API_KEY is empty — supervisor calls will fail (Layer 2 defaults to deny)" >&2
fi

if [[ "$DRY_RUN" != "true" ]]; then
  # Create file as sandbox user from the start (no ownership transfer race)
  KEY_FILE=$(sudo -u $SANDBOX_USER mktemp "${WORKSPACE}/.dyad-key-XXXXXXXX")
  sudo -u $SANDBOX_USER chmod 600 "$KEY_FILE"
  printf '%s' "$ANTHROPIC_API_KEY" | sudo -u $SANDBOX_USER tee "$KEY_FILE" > /dev/null
else
  KEY_FILE="${WORKSPACE}/.dyad-key-XXXXXXXX"
  echo "[dry-run] Create API key temp file: $KEY_FILE"
fi

# --- Construct sandbox PATH ---
SANDBOX_PATH="${SANDBOX_BIN}:/usr/bin:/bin"

# --- Run Dyad as sandbox user ---
echo ""
echo "dyad-sandbox-run: Starting sandboxed Dyad session"
echo "  Task: $TASK"
echo "  User: $SANDBOX_USER"
echo "  PATH: $SANDBOX_PATH"
[[ -n "$RULES_FLAG" ]] && echo "  Rules: $RULES_FLAG"
[[ "$APPROVE_ALL" == "true" ]] && echo "  *** APPROVE-ALL MODE ***"
[[ "$NO_CLEANUP" == "true" ]] && echo "  Mode: persistent (--no-cleanup)"
echo "---"

DYAD_EXIT_CODE=0
if [[ "$DRY_RUN" != "true" ]]; then
  # IMPORTANT: Do NOT use exec — post-run extraction must execute
  # Use explicit env to survive sudo env_reset; ulimit runs inside sandbox shell
  sudo -u $SANDBOX_USER env \
    DYAD_API_KEY_FILE="$KEY_FILE" \
    DYAD_PROJECT_ROOT="${PROJECT_DEST}" \
    HOME="$WORKSPACE" \
    PATH="$SANDBOX_PATH" \
    TMPDIR="${WORKSPACE}/.tmp" \
    bash -c '
      umask 077
      ulimit -u 256        # max processes
      ulimit -f 1048576    # max file size (~1GB)
      cd "$DYAD_PROJECT_ROOT"
      exec '"$DYAD_INSTALL"'/dyad.sh '"$DYAD_FLAGS"' "$@"
    ' -- "$TASK" || DYAD_EXIT_CODE=$?
else
  echo "[dry-run] sudo -u $SANDBOX_USER env ... bash -c 'umask 077; ulimit ...; cd $PROJECT_DEST; exec $DYAD_INSTALL/dyad.sh $DYAD_FLAGS \"$TASK\"'"
fi

echo ""
echo "dyad-sandbox-run: Dyad exited with code $DYAD_EXIT_CODE"

# --- Extract results ---
echo ""
echo "# --- Extract results ---"

if [[ "$DRY_RUN" != "true" ]]; then
  RESULTS_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dyad-results-XXXXXXXX")
  chmod 700 "$RESULTS_DIR"

  # Extract diff against initial commit (captures all changes)
  ROOT_COMMIT=$(sudo -u $SANDBOX_USER env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$PROJECT_DEST" rev-list --max-parents=0 HEAD 2>/dev/null) || true
  if [[ -n "$ROOT_COMMIT" ]]; then
    sudo -u $SANDBOX_USER env GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_SYSTEM=/dev/null git -C "$PROJECT_DEST" diff "${ROOT_COMMIT}" > "$RESULTS_DIR/changes.diff" 2>/dev/null || true
  fi

  # Copy audit log into same results directory
  if [[ -f "${WORKSPACE}/.dyad/audit.log" ]]; then
    sudo cat "${WORKSPACE}/.dyad/audit.log" > "$RESULTS_DIR/audit.log"
  fi

  if [[ -s "$RESULTS_DIR/changes.diff" ]]; then
    echo "  Results extracted to: $RESULTS_DIR"
    echo "    changes.diff  — apply with: git apply $RESULTS_DIR/changes.diff"
    echo "    audit.log     — sandbox session audit trail"
  else
    echo "  No changes made in sandbox."
    echo "  Results directory: $RESULTS_DIR"
  fi
else
  echo "[dry-run] Extract git diff and audit log to temp results directory"
fi

echo ""
echo "dyad-sandbox-run: Done (exit code: $DYAD_EXIT_CODE)"
exit $DYAD_EXIT_CODE
