#!/bin/bash
set -euo pipefail

# dyad — intelligent permission proxy for Claude Code
# Launches Claude Code with a PreToolUse hook that applies rule-based
# and AI-supervised permission decisions.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Dependency validation ---
command -v claude >/dev/null 2>&1 || { echo "Error: claude CLI not found on PATH." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found. Install with: brew install jq (macOS) or sudo apt install jq (Linux)" >&2; exit 1; }

# --- Argument parsing ---
APPROVE_ALL=false
RULES_FILE="${SCRIPT_DIR}/dyad-rules.json"
TASK=""

usage() {
  cat <<'EOF'
Usage: dyad [OPTIONS] <task>

Launch Claude Code with intelligent permission management.

Options:
  --approve-all       Auto-approve all tool calls (still logs decisions)
  --rules <file>      Path to rules JSON file (default: ./dyad-rules.json)
  --help              Show this help message

Examples:
  dyad "implement the login page"
  dyad --approve-all "refactor the auth module"
  dyad --rules custom-rules.json "fix the tests"
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --approve-all)
      APPROVE_ALL=true
      shift
      ;;
    --rules)
      [[ $# -lt 2 ]] && { echo "Error: --rules requires a file path argument." >&2; exit 1; }
      RULES_FILE="$2"
      shift 2
      ;;
    --help|-h)
      usage
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Run 'dyad --help' for usage." >&2
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
  echo "Run 'dyad --help' for usage." >&2
  exit 1
fi

# Validate rules file exists
if [[ ! -f "$RULES_FILE" ]]; then
  echo "Error: Rules file not found: $RULES_FILE" >&2
  exit 1
fi

# Validate rules file is valid JSON
if ! jq empty "$RULES_FILE" 2>/dev/null; then
  echo "Error: Rules file is not valid JSON: $RULES_FILE" >&2
  exit 1
fi

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

# --- Resolve API key ---
_API_KEY_VAR="${DYAD_API_KEY_VAR:-ANTHROPIC_API_KEY}"
RESOLVED_API_KEY="${!_API_KEY_VAR:-}"
# Support file-based API key (used by sandbox mode)
if [[ -z "$RESOLVED_API_KEY" && -n "${DYAD_API_KEY_FILE:-}" && -f "$DYAD_API_KEY_FILE" ]]; then
  RESOLVED_API_KEY="$(cat "$DYAD_API_KEY_FILE")"
fi
if [[ -z "$RESOLVED_API_KEY" && "$APPROVE_ALL" != "true" ]]; then
  echo "Warning: API key variable '${_API_KEY_VAR}' is empty — supervisor calls will fail (Layer 2 defaults to deny)" >&2
fi

# --- Session setup ---
SESSION_ID="dyad-$$-$(date +%s)"
TMPDIR_DYAD=$(mktemp -d "${TMPDIR:-/tmp}/dyad-${SESSION_ID}-XXXXXXXX")
chmod 700 "$TMPDIR_DYAD"
HOOK_SETTINGS="${TMPDIR_DYAD}/hooks.json"
TASK_FILE="${TMPDIR_DYAD}/task.txt"
HOOK_SCRIPT="${SCRIPT_DIR}/dyad-hook.sh"

# Ensure audit log directory exists
mkdir -p ~/.dyad

# Ensure hook script is executable
[[ -x "$HOOK_SCRIPT" ]] || chmod +x "$HOOK_SCRIPT"

# --- Cleanup on exit ---
cleanup() { rm -rf "$TMPDIR_DYAD"; }
trap cleanup EXIT INT TERM

# --- Write task context ---
printf '%s' "$TASK" > "$TASK_FILE"

# --- Write hook settings ---
HOOK_CMD="DYAD_TASK_FILE='${TASK_FILE}' DYAD_RULES_FILE='${RULES_FILE}' DYAD_APPROVE_ALL='${APPROVE_ALL}' DYAD_SESSION_ID='${SESSION_ID}' DYAD_PROJECT_ROOT='${PROJECT_ROOT}' DYAD_SESSION_TMPDIR='${TMPDIR_DYAD}' DYAD_RESOLVED_API_KEY='${RESOLVED_API_KEY}' '${HOOK_SCRIPT}'"

jq -nc \
  --arg cmd "$HOOK_CMD" \
  '{hooks:{PreToolUse:[{matcher:"",hooks:[{type:"command",command:$cmd,timeout:60}]}]}}' \
  > "$HOOK_SETTINGS"

# --- Launch Claude Code ---
echo "dyad: Starting session ${SESSION_ID}"
echo "dyad: Project root: ${PROJECT_ROOT}"
echo "dyad: Task: ${TASK}"
echo "dyad: Rules: ${RULES_FILE}"
[[ "$APPROVE_ALL" == "true" ]] && echo "dyad: *** APPROVE-ALL MODE — all operations will be auto-approved ***"
echo "---"

exec claude --settings "$HOOK_SETTINGS" "$TASK"
