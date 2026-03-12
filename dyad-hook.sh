#!/bin/bash
# dyad-hook.sh — PreToolUse hook for dyad permission proxy
#
# Receives Claude Code PreToolUse JSON on stdin.
# Applies a two-layer permission strategy:
#   Layer 1: Rule-based filtering (fast-path + configurable rules)
#   Layer 2: AI supervisor via claude -p --model haiku
#
# Environment variables (set by dyad.sh):
#   DYAD_TASK_FILE     — path to file containing the original user task
#   DYAD_RULES_FILE    — path to the rules JSON config
#   DYAD_APPROVE_ALL   — "true" to auto-approve everything
#   DYAD_SESSION_ID    — session identifier for audit logging

# Read hook input from stdin
INPUT=$(cat)

TOOL_NAME=$(echo "$INPUT" | jq -r '.tool_name // empty')
TOOL_INPUT=$(echo "$INPUT" | jq -c '.tool_input // {}')
SESSION_ID="${DYAD_SESSION_ID:-unknown}"

# --- Utility functions ---

audit_log() {
  local decision="$1" source="$2" reason="$3"
  local input_summary
  input_summary=$(echo "$TOOL_INPUT" | jq -c '.' 2>/dev/null | head -c 500)
  local ts
  ts=$(date -u +"%Y-%m-%dT%H:%M:%SZ")
  jq -nc \
    --arg ts "$ts" \
    --arg session "$SESSION_ID" \
    --arg tool "$TOOL_NAME" \
    --argjson input "$input_summary" \
    --arg decision "$decision" \
    --arg source "$source" \
    --arg reason "$reason" \
    '{ts:$ts,session:$session,tool:$tool,input:$input,decision:$decision,source:$source,reason:$reason}' \
    >> ~/.dyad/audit.log 2>/dev/null
}

output_allow() {
  local reason="${1:-Approved}"
  jq -nc --arg r "$reason" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"allow","permissionDecisionReason":$r}}'
}

output_deny() {
  local reason="${1:-Denied by dyad}"
  jq -nc --arg r "dyad denied: $reason" \
    '{"hookSpecificOutput":{"hookEventName":"PreToolUse","permissionDecision":"deny","permissionDecisionReason":$r}}'
}

# --- Layer 0: Fast-path for read-only tools ---
# Exit with no output = passthrough (Claude Code proceeds normally)
case "$TOOL_NAME" in
  Read|Glob|Grep|Explore|TaskCreate|TaskUpdate|TaskList|TaskGet|TaskOutput|TaskStop)
    audit_log "allow" "fast-path" "Read-only tool"
    exit 0
    ;;
esac

# --- Approve-all mode ---
if [[ "${DYAD_APPROVE_ALL:-false}" == "true" ]]; then
  audit_log "allow" "approve-all" "Approve-all mode enabled"
  output_allow "Approve-all mode"
  exit 0
fi

# --- Layer 1: Rule evaluation ---
# Load rules file
if [[ -f "${DYAD_RULES_FILE:-}" ]]; then
  RULES=$(cat "$DYAD_RULES_FILE")
else
  RULES='{"rules":[]}'
fi

# Evaluate rules: first match wins
RULE_COUNT=$(echo "$RULES" | jq '.rules | length')

for (( i=0; i<RULE_COUNT; i++ )); do
  RULE=$(echo "$RULES" | jq -c ".rules[$i]")
  RULE_TOOL=$(echo "$RULE" | jq -r '.tool')

  # Check if tool name matches (exact match)
  if [[ "$RULE_TOOL" != "$TOOL_NAME" ]]; then
    continue
  fi

  # Check if match conditions are satisfied
  MATCH_OBJ=$(echo "$RULE" | jq -c '.match // {}')

  if [[ "$MATCH_OBJ" == "{}" ]]; then
    # Empty match = matches all calls to this tool
    RULE_ACTION=$(echo "$RULE" | jq -r '.action')
    RULE_REASON=$(echo "$RULE" | jq -r '.reason // "Matched rule"')
    audit_log "$RULE_ACTION" "rule" "$RULE_REASON"

    if [[ "$RULE_ACTION" == "allow" ]]; then
      output_allow "$RULE_REASON"
    else
      output_deny "$RULE_REASON"
    fi
    exit 0
  fi

  # Check each field in match against tool_input using glob patterns
  ALL_MATCH=true
  for KEY in $(echo "$MATCH_OBJ" | jq -r 'keys[]'); do
    PATTERN=$(echo "$MATCH_OBJ" | jq -r --arg k "$KEY" '.[$k]')
    ACTUAL=$(echo "$TOOL_INPUT" | jq -r --arg k "$KEY" '.[$k] // empty')

    if [[ -z "$ACTUAL" ]]; then
      ALL_MATCH=false
      break
    fi

    # Glob pattern matching using bash's extended pattern matching
    # shellcheck disable=SC2254
    if [[ "$ACTUAL" != $PATTERN ]]; then
      ALL_MATCH=false
      break
    fi
  done

  if [[ "$ALL_MATCH" == "true" ]]; then
    RULE_ACTION=$(echo "$RULE" | jq -r '.action')
    RULE_REASON=$(echo "$RULE" | jq -r '.reason // "Matched rule"')
    audit_log "$RULE_ACTION" "rule" "$RULE_REASON"

    if [[ "$RULE_ACTION" == "allow" ]]; then
      output_allow "$RULE_REASON"
    else
      output_deny "$RULE_REASON"
    fi
    exit 0
  fi
done

# --- Layer 2: Supervisor ---
# Read original task for context
TASK_CONTEXT=""
if [[ -f "${DYAD_TASK_FILE:-}" ]]; then
  TASK_CONTEXT=$(cat "$DYAD_TASK_FILE")
fi

SUPERVISOR_PROMPT="You are a security supervisor for an AI coding assistant. The assistant is working on the following task:

TASK: ${TASK_CONTEXT}

The assistant wants to perform the following operation:
TOOL: ${TOOL_NAME}
INPUT: ${TOOL_INPUT}

Should this operation be approved? Consider:
1. Is this operation relevant to the stated task?
2. Could this operation cause harm (data loss, security exposure, unintended side effects)?
3. Is this a reasonable action for a coding assistant to take?

Respond with your decision."

SUPERVISOR_SCHEMA='{"type":"object","properties":{"decision":{"type":"string","enum":["allow","deny"]},"reason":{"type":"string"}},"required":["decision","reason"]}'

# Call supervisor with timeout (macOS-compatible)
SUPERVISOR_RESULT=""
_timeout_cmd() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 30 "$@"
  elif command -v gtimeout >/dev/null 2>&1; then
    gtimeout 30 "$@"
  else
    # Fallback: background process with kill
    "$@" &
    local pid=$!
    ( sleep 30; kill "$pid" 2>/dev/null ) &
    local watcher=$!
    wait "$pid" 2>/dev/null
    local ret=$?
    kill "$watcher" 2>/dev/null
    wait "$watcher" 2>/dev/null
    return $ret
  fi
}

if SUPERVISOR_RESULT=$(CLAUDECODE= _timeout_cmd claude -p --model haiku --output-format json --json-schema "$SUPERVISOR_SCHEMA" "$SUPERVISOR_PROMPT" 2>/dev/null); then
  SUP_DECISION=$(echo "$SUPERVISOR_RESULT" | jq -r '.structured_output.decision // empty')
  SUP_REASON=$(echo "$SUPERVISOR_RESULT" | jq -r '.structured_output.reason // "No reason given"')

  if [[ "$SUP_DECISION" == "allow" ]]; then
    audit_log "allow" "supervisor" "$SUP_REASON"
    output_allow "$SUP_REASON"
    exit 0
  elif [[ "$SUP_DECISION" == "deny" ]]; then
    audit_log "deny" "supervisor" "$SUP_REASON"
    output_deny "$SUP_REASON"
    exit 0
  fi
fi

# Supervisor failed or returned unexpected result — default deny
audit_log "deny" "supervisor" "Supervisor failed or returned invalid response"
output_deny "Supervisor unavailable — defaulting to deny for safety"
exit 0
