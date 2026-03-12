#!/bin/bash
set -euo pipefail

# dyad — intelligent permission proxy for Claude Code
# Launches Claude Code with a PreToolUse hook that applies rule-based
# and AI-supervised permission decisions.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Dependency validation ---
command -v claude >/dev/null 2>&1 || { echo "Error: claude CLI not found on PATH." >&2; exit 1; }
command -v jq >/dev/null 2>&1 || { echo "Error: jq not found. Install with: brew install jq" >&2; exit 1; }

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

# --- Session setup ---
SESSION_ID="dyad-$$-$(date +%s)"
HOOK_SETTINGS="/tmp/dyad-hooks-${SESSION_ID}.json"
TASK_FILE="/tmp/dyad-task-${SESSION_ID}.txt"
HOOK_SCRIPT="${SCRIPT_DIR}/dyad-hook.sh"

# Ensure audit log directory exists
mkdir -p ~/.dyad

# Ensure hook script is executable
chmod +x "$HOOK_SCRIPT"

# --- Cleanup on exit ---
cleanup() { rm -f "$HOOK_SETTINGS" "$TASK_FILE"; }
trap cleanup EXIT INT TERM

# --- Write task context ---
printf '%s' "$TASK" > "$TASK_FILE"

# --- Write hook settings ---
cat > "$HOOK_SETTINGS" <<SETTINGS
{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "DYAD_TASK_FILE='${TASK_FILE}' DYAD_RULES_FILE='${RULES_FILE}' DYAD_APPROVE_ALL='${APPROVE_ALL}' DYAD_SESSION_ID='${SESSION_ID}' '${HOOK_SCRIPT}'",
            "timeout": 60
          }
        ]
      }
    ]
  }
}
SETTINGS

# --- Launch Claude Code ---
echo "dyad: Starting session ${SESSION_ID}"
echo "dyad: Task: ${TASK}"
echo "dyad: Rules: ${RULES_FILE}"
[[ "$APPROVE_ALL" == "true" ]] && echo "dyad: *** APPROVE-ALL MODE — all operations will be auto-approved ***"
echo "---"

exec claude --settings "$HOOK_SETTINGS" "$TASK"
