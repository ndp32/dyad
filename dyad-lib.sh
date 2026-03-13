#!/bin/bash
# dyad-lib.sh — shared constants and utility functions for Dyad sandbox scripts
#
# Sourced by dyad-sandbox-setup.sh, dyad-sandbox-run.sh, dyad-sandbox-teardown.sh.
# Not executable on its own.

# --- Shared constants ---
SANDBOX_USER="dyad-sandbox"
WORKSPACE="/opt/dyad-workspace"
DYAD_INSTALL="/opt/dyad"
SANDBOX_BIN="${WORKSPACE}/.bin"

# --- Platform detection ---
detect_platform() {
  case "$(uname -s)" in
    Darwin) echo "macos" ;;
    Linux)  echo "linux" ;;
    *)      echo "unsupported" ;;
  esac
}

# --- Root group (macOS: wheel, Linux: root) ---
# Set after detect_platform is called and PLATFORM is assigned.
resolve_root_group() {
  if [[ "$1" == "macos" ]]; then
    echo "wheel"
  else
    echo "root"
  fi
}

# --- Dry-run-aware sudo wrapper ---
# Requires DRY_RUN to be set by the sourcing script.
run_sudo() {
  if [[ "${DRY_RUN:-false}" == "true" ]]; then
    echo "[dry-run] sudo $*"
  else
    sudo "$@"
  fi
}

# --- Session lock (prevents concurrent sandbox runs) ---
SANDBOX_LOCK="${WORKSPACE}/.dyad-session.lock"

acquire_session_lock() {
  if [[ -f "$SANDBOX_LOCK" ]]; then
    local lock_pid
    lock_pid=$(cat "$SANDBOX_LOCK" 2>/dev/null) || true
    # Check if the locking process is still alive
    if [[ -n "$lock_pid" ]] && kill -0 "$lock_pid" 2>/dev/null; then
      echo "Error: Another sandbox session is running (PID $lock_pid)." >&2
      echo "  If this is stale, remove $SANDBOX_LOCK and retry." >&2
      return 1
    fi
    # Stale lock — previous session crashed without cleanup
    echo "Warning: Removing stale lock (PID $lock_pid no longer running)."
  fi
  echo "$$" | sudo tee "$SANDBOX_LOCK" > /dev/null
  sudo chmod 644 "$SANDBOX_LOCK"
}

release_session_lock() {
  sudo rm -f "$SANDBOX_LOCK" 2>/dev/null || true
}
