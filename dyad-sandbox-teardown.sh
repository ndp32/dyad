#!/bin/bash
set -euo pipefail

# dyad-sandbox-teardown.sh — remove the Dyad sandbox environment
#
# Removes the sandbox user, workspace, and Dyad script installation.
# Verifies workspace marker before deletion to prevent accidental removal
# of wrong directories.
#
# Usage:
#   dyad-sandbox-teardown.sh [OPTIONS]
#
# Options:
#   --dry-run    Print what would be executed without running
#   --help       Show this help message

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Shared library ---
# shellcheck source=dyad-lib.sh
source "${SCRIPT_DIR}/dyad-lib.sh"

# --- Argument parsing ---
DRY_RUN=false

usage() {
  cat <<'EOF'
Usage: dyad-sandbox-teardown.sh [OPTIONS]

Remove the Dyad sandbox environment completely.

Options:
  --dry-run    Print what would be executed without running
  --help       Show this help message

This removes:
  - The dyad-sandbox user account
  - The workspace at /opt/dyad-workspace
  - The Dyad script installation at /opt/dyad

EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --help|-h)
      usage
      ;;
    -*)
      echo "Unknown option: $1" >&2
      echo "Run 'dyad-sandbox-teardown.sh --help' for usage." >&2
      exit 1
      ;;
    *)
      echo "Error: unexpected argument: $1" >&2
      exit 1
      ;;
  esac
done

PLATFORM=$(detect_platform)
if [[ "$PLATFORM" == "unsupported" ]]; then
  echo "Error: Unsupported platform: $(uname -s)." >&2
  exit 1
fi

echo "dyad-sandbox-teardown: platform=$PLATFORM"
[[ "$DRY_RUN" == "true" ]] && echo "dyad-sandbox-teardown: *** DRY RUN — no changes will be made ***"

# Test sudo access
if [[ "$DRY_RUN" != "true" ]]; then
  if ! sudo -n true 2>/dev/null; then
    echo ""
    echo "sudo access required. You may be prompted for your password."
    sudo true || { echo "Error: sudo access denied." >&2; exit 1; }
  fi
fi

# --- Kill any running sandbox processes ---
echo ""
echo "# --- Kill sandbox processes ---"

if id $SANDBOX_USER &>/dev/null; then
  release_session_lock
  run_sudo pkill -u $SANDBOX_USER 2>/dev/null || true
  if [[ "$DRY_RUN" != "true" ]]; then
    sleep 1
  fi
  echo "  Killed any running $SANDBOX_USER processes"
else
  echo "  User $SANDBOX_USER does not exist, skipping process cleanup"
fi

# --- Remove workspace ---
echo ""
echo "# --- Remove workspace ---"

if [[ -d "$WORKSPACE" ]]; then
  if [[ -L "$WORKSPACE" ]]; then
    echo "Error: $WORKSPACE is a symlink. Refusing to delete." >&2
    exit 1
  fi

  # Verify workspace marker
  if [[ -f "$WORKSPACE/.dyad-workspace-marker" ]]; then
    MARKER_CONTENT=""
    if [[ "$DRY_RUN" != "true" ]]; then
      MARKER_CONTENT=$(cat "$WORKSPACE/.dyad-workspace-marker" 2>/dev/null) || true
    else
      MARKER_CONTENT="dyad-sandbox-workspace"
      echo "[dry-run] Would read $WORKSPACE/.dyad-workspace-marker"
    fi

    if [[ "$MARKER_CONTENT" == "dyad-sandbox-workspace" ]]; then
      run_sudo rm -rf "$WORKSPACE"
      echo "  Removed: $WORKSPACE"
    else
      echo "Error: $WORKSPACE has unexpected marker content. Refusing to delete." >&2
      exit 1
    fi
  else
    echo "Error: $WORKSPACE does not have a .dyad-workspace-marker file. Refusing to delete." >&2
    echo "  If this is a legitimate dyad workspace, remove it manually: sudo rm -rf $WORKSPACE" >&2
    exit 1
  fi
else
  echo "  $WORKSPACE does not exist, skipping"
fi

# --- Remove Dyad scripts ---
echo ""
echo "# --- Remove Dyad scripts ---"

if [[ -d "$DYAD_INSTALL" ]]; then
  if [[ -L "$DYAD_INSTALL" ]]; then
    echo "Error: $DYAD_INSTALL is a symlink. Refusing to delete." >&2
    exit 1
  fi
  run_sudo rm -rf "$DYAD_INSTALL"
  echo "  Removed: $DYAD_INSTALL"
else
  echo "  $DYAD_INSTALL does not exist, skipping"
fi

# --- Remove user ---
echo ""
echo "# --- Remove sandbox user ---"

if [[ "$PLATFORM" == "macos" ]]; then
  if dscl . -read /Users/$SANDBOX_USER &>/dev/null; then
    run_sudo dscl . -delete /Users/$SANDBOX_USER
    echo "  Removed user: $SANDBOX_USER"
  else
    echo "  User $SANDBOX_USER does not exist, skipping"
  fi
else
  if id $SANDBOX_USER &>/dev/null; then
    run_sudo userdel $SANDBOX_USER 2>/dev/null || true
    echo "  Removed user: $SANDBOX_USER"
  else
    echo "  User $SANDBOX_USER does not exist, skipping"
  fi
fi

echo ""
echo "========================================="
echo "  Sandbox removed."
echo "========================================="
