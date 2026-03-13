#!/bin/bash
set -euo pipefail

# dyad-sandbox-setup.sh — create a sandboxed environment for running Dyad
#
# Creates a dedicated unprivileged user (dyad-sandbox) with minimal privileges,
# copies the project into an isolated workspace, and installs Dyad scripts to
# a root-owned location. Cross-platform (macOS + Linux).
#
# Usage:
#   dyad-sandbox-setup.sh [OPTIONS] <project-path>
#
# Options:
#   --tools <list>    Comma-separated extra binaries to add to sandbox PATH
#   --dry-run         Print what would be executed without running
#   --help            Show this help message

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# --- Shared library ---
# shellcheck source=dyad-lib.sh
source "${SCRIPT_DIR}/dyad-lib.sh"

# --- Argument parsing ---
DRY_RUN=false
EXTRA_TOOLS=""
PROJECT_SRC=""

usage() {
  cat <<'EOF'
Usage: dyad-sandbox-setup.sh [OPTIONS] <project-path>

Create a sandboxed environment for running Dyad.

Options:
  --tools <list>    Comma-separated extra binaries to add to sandbox PATH
                    (e.g., --tools "ruby,rake,bundle")
  --dry-run         Print what would be executed without running
  --help            Show this help message

Examples:
  dyad-sandbox-setup.sh /path/to/project
  dyad-sandbox-setup.sh --tools "ruby,rake" /path/to/project
  dyad-sandbox-setup.sh --dry-run /path/to/project
EOF
  exit 0
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tools)
      [[ $# -lt 2 ]] && { echo "Error: --tools requires a comma-separated list." >&2; exit 1; }
      EXTRA_TOOLS="$2"
      shift 2
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
      echo "Run 'dyad-sandbox-setup.sh --help' for usage." >&2
      exit 1
      ;;
    *)
      if [[ -z "$PROJECT_SRC" ]]; then
        PROJECT_SRC="$1"
      else
        echo "Error: unexpected argument: $1" >&2
        exit 1
      fi
      shift
      ;;
  esac
done

if [[ -z "$PROJECT_SRC" ]]; then
  echo "Error: No project path provided." >&2
  echo "Run 'dyad-sandbox-setup.sh --help' for usage." >&2
  exit 1
fi

if [[ ! -d "$PROJECT_SRC" ]]; then
  echo "Error: Project path is not a directory: $PROJECT_SRC" >&2
  exit 1
fi

# Resolve to absolute path
PROJECT_SRC="$(cd "$PROJECT_SRC" && pwd)"

# --- Utility functions ---

# Execute or print command depending on dry-run mode
run() {
  if [[ "$DRY_RUN" == "true" ]]; then
    echo "[dry-run] $*"
  else
    "$@"
  fi
}

PLATFORM=$(detect_platform)
if [[ "$PLATFORM" == "unsupported" ]]; then
  echo "Error: Unsupported platform: $(uname -s). Only macOS and Linux are supported." >&2
  exit 1
fi

echo "dyad-sandbox-setup: platform=$PLATFORM project=$PROJECT_SRC"
[[ "$DRY_RUN" == "true" ]] && echo "dyad-sandbox-setup: *** DRY RUN — no changes will be made ***"

# --- Dependency validation ---
echo ""
echo "# --- Dependency validation ---"

MISSING_DEPS=false
for cmd in claude jq git; do
  REAL_PATH="$(command -v "$cmd" 2>/dev/null)" || true
  if [[ -n "$REAL_PATH" ]]; then
    echo "  $cmd: $REAL_PATH"
  else
    echo "  $cmd: NOT FOUND" >&2
    MISSING_DEPS=true
  fi
done

if [[ "$MISSING_DEPS" == "true" ]]; then
  echo "" >&2
  echo "Error: Missing required dependencies." >&2
  echo "  Install with: brew install jq (macOS) or sudo apt install jq (Linux)" >&2
  echo "  Claude Code: https://claude.ai/download" >&2
  exit 1
fi

# Test sudo access
if [[ "$DRY_RUN" != "true" ]]; then
  if ! sudo -n true 2>/dev/null; then
    echo ""
    echo "sudo access required. You may be prompted for your password."
    sudo true || { echo "Error: sudo access denied." >&2; exit 1; }
  fi
fi

# --- Create sandbox user ---
echo ""
echo "# --- Create sandbox user ---"

ROOT_GROUP=$(resolve_root_group "$PLATFORM")

if [[ "$PLATFORM" == "macos" ]]; then
  if dscl . -read /Users/$SANDBOX_USER &>/dev/null; then
    echo "  $SANDBOX_USER user already exists, skipping creation"
  else
    # Find an available UID in the 400-499 service account range (hidden from login window)
    NEXT_UID=$(dscl . -list /Users UniqueID | awk '{print $2}' | sort -n | awk '$1 >= 400 && $1 < 500 {last=$1} END {print (last ? last+1 : 400)}')
    if [[ "$NEXT_UID" -ge 500 ]]; then
      echo "Error: no available UID in range 400-499" >&2
      exit 1
    fi
    echo "  Creating user $SANDBOX_USER with UID $NEXT_UID"
    run_sudo dscl . -create /Users/$SANDBOX_USER
    run_sudo dscl . -create /Users/$SANDBOX_USER UserShell /usr/bin/false
    run_sudo dscl . -create /Users/$SANDBOX_USER UniqueID "$NEXT_UID"
    run_sudo dscl . -create /Users/$SANDBOX_USER PrimaryGroupID 20
    run_sudo dscl . -create /Users/$SANDBOX_USER NFSHomeDirectory "$WORKSPACE"
    run_sudo dscl . -create /Users/$SANDBOX_USER RealName "Dyad Sandbox"
    run_sudo dscl . -create /Users/$SANDBOX_USER Password "*"
  fi
else
  if id $SANDBOX_USER &>/dev/null; then
    echo "  $SANDBOX_USER user already exists, skipping creation"
  else
    echo "  Creating system user $SANDBOX_USER"
    run_sudo useradd --system --shell /usr/sbin/nologin --home-dir "$WORKSPACE" --no-create-home $SANDBOX_USER
  fi
fi

# --- Create workspace ---
echo ""
echo "# --- Create workspace ---"

run_sudo mkdir -p "$WORKSPACE"
run_sudo chmod 700 "$WORKSPACE"
run_sudo chown ${SANDBOX_USER}: "$WORKSPACE"

# Workspace marker for safe teardown
if [[ "$DRY_RUN" != "true" ]]; then
  echo "dyad-sandbox-workspace" | sudo tee "$WORKSPACE/.dyad-workspace-marker" > /dev/null
else
  echo "[dry-run] echo 'dyad-sandbox-workspace' > $WORKSPACE/.dyad-workspace-marker"
fi

# Isolated TMPDIR (not shared /tmp)
run_sudo -u $SANDBOX_USER mkdir -p "$WORKSPACE/.tmp"

echo "  Workspace: $WORKSPACE (chmod 700)"
echo "  Marker: $WORKSPACE/.dyad-workspace-marker"
echo "  TMPDIR: $WORKSPACE/.tmp"

# --- Create narrow PATH directory (root-owned) ---
echo ""
echo "# --- Create narrow PATH directory ---"

run_sudo mkdir -p "$SANDBOX_BIN"
run_sudo chown ${ROOT_GROUP}:${ROOT_GROUP} "$SANDBOX_BIN" 2>/dev/null || run_sudo chown root:${ROOT_GROUP} "$SANDBOX_BIN"
run_sudo chmod 755 "$SANDBOX_BIN"

# Always-needed binaries
for cmd in claude jq git; do
  REAL_PATH="$(command -v "$cmd")"
  run_sudo ln -sf "$REAL_PATH" "$SANDBOX_BIN/$cmd"
  echo "  $cmd -> $REAL_PATH"
done

# User-specified extra tools
if [[ -n "$EXTRA_TOOLS" ]]; then
  IFS=',' read -ra TOOLS <<< "$EXTRA_TOOLS"
  for cmd in "${TOOLS[@]}"; do
    cmd="$(echo "$cmd" | xargs)"  # trim whitespace
    REAL_PATH="$(command -v "$cmd" 2>/dev/null)" || true
    if [[ -n "$REAL_PATH" ]]; then
      run_sudo ln -sf "$REAL_PATH" "$SANDBOX_BIN/$cmd"
      echo "  $cmd -> $REAL_PATH (--tools)"
    else
      echo "  Warning: $cmd not found on PATH, skipping" >&2
    fi
  done
fi

# --- Copy project into workspace ---
echo ""
echo "# --- Copy project into workspace ---"

PROJECT_DEST="${WORKSPACE}/project"

# Clean any stale workspace first (symlink-safe)
if [[ "$DRY_RUN" != "true" ]]; then
  if [[ -d "$PROJECT_DEST" ]] && [[ ! -L "$PROJECT_DEST" ]]; then
    echo "  Cleaning stale project directory..."
    sudo -u $SANDBOX_USER find "$PROJECT_DEST" -mindepth 1 -delete 2>/dev/null || true
  fi
else
  echo "[dry-run] Clean stale project directory if exists"
fi
run_sudo -u $SANDBOX_USER mkdir -p "$PROJECT_DEST"

if [[ -d "$PROJECT_SRC/.git" ]]; then
  FILE_COUNT=$(git -C "$PROJECT_SRC" ls-files | wc -l | xargs)

  # Warn about uncommitted changes
  DIRTY=$(git -C "$PROJECT_SRC" status --porcelain 2>/dev/null) || true
  if [[ -n "$DIRTY" ]]; then
    echo "  Warning: project has uncommitted changes that will NOT be included in the sandbox."
    echo "  Commit or stash changes first, or they won't be visible to the sandbox."
  fi

  echo "  Copying via git archive ($FILE_COUNT tracked files)..."
  if [[ "$DRY_RUN" != "true" ]]; then
    git -C "$PROJECT_SRC" archive HEAD | sudo -u $SANDBOX_USER tar -x -C "$PROJECT_DEST"
    # Initialize fresh git repo for the diff-based sync workflow
    sudo -u $SANDBOX_USER bash -c "
      cd '$PROJECT_DEST' &&
      git -c core.compression=0 init &&
      git -c core.compression=0 add -A &&
      git -c core.compression=0 commit -m 'Initial sandbox copy'
    " >/dev/null 2>&1
  else
    echo "[dry-run] git archive HEAD | tar -x -C $PROJECT_DEST"
    echo "[dry-run] git init + add + commit in $PROJECT_DEST"
  fi
else
  echo "  Copying via rsync (non-git project)..."
  if [[ "$DRY_RUN" != "true" ]]; then
    sudo rsync -a \
      --exclude='.git' --exclude='.env' --exclude='.env.*' \
      --exclude='node_modules' --exclude='.npmrc' \
      --exclude='.ssh' --exclude='.aws' --exclude='.docker' \
      --exclude='*.pem' --exclude='*.key' --exclude='credentials.json' \
      --exclude='.gcloud' --exclude='.azure' --exclude='.kube' \
      --exclude='*.p12' --exclude='*.pfx' --exclude='*.jks' --exclude='*.keystore' \
      --exclude='.netrc' --exclude='.pgpass' --exclude='.htpasswd' \
      --exclude='.terraform' --exclude='terraform.tfstate' --exclude='terraform.tfstate.backup' \
      "$PROJECT_SRC/" "$PROJECT_DEST/"
    sudo chown -R ${SANDBOX_USER}: "$PROJECT_DEST"
    # Strip any setuid/setgid bits from copied files
    sudo find "$PROJECT_DEST" -perm /6000 -exec chmod ug-s {} + 2>/dev/null || true
    sudo -u $SANDBOX_USER bash -c "
      cd '$PROJECT_DEST' &&
      git -c core.compression=0 init &&
      git -c core.compression=0 add -A &&
      git -c core.compression=0 commit -m 'Initial sandbox copy'
    " >/dev/null 2>&1
  else
    echo "[dry-run] rsync -a (with exclusions) $PROJECT_SRC/ $PROJECT_DEST/"
    echo "[dry-run] chown + strip setuid + git init"
  fi
fi

echo "  Project copied to: $PROJECT_DEST"

# --- Install Dyad scripts (root-owned, read-only) ---
echo ""
echo "# --- Install Dyad scripts ---"

run_sudo mkdir -p "$DYAD_INSTALL"
run_sudo cp "$SCRIPT_DIR/dyad.sh" "$SCRIPT_DIR/dyad-hook.sh" "$SCRIPT_DIR/dyad-lib.sh" "$SCRIPT_DIR/dyad-rules.json" "$DYAD_INSTALL/"
run_sudo chmod 755 "$DYAD_INSTALL/dyad.sh" "$DYAD_INSTALL/dyad-hook.sh"
run_sudo chmod 644 "$DYAD_INSTALL/dyad-lib.sh" "$DYAD_INSTALL/dyad-rules.json"
run_sudo chown -R root:${ROOT_GROUP} "$DYAD_INSTALL"

echo "  Installed to: $DYAD_INSTALL"
echo "  dyad.sh, dyad-hook.sh (755), dyad-rules.json (644)"

# --- Configure Claude Code ---
echo ""
echo "# --- Configure Claude Code ---"

run_sudo -u $SANDBOX_USER mkdir -p "$WORKSPACE/.claude"
if [[ "$DRY_RUN" != "true" ]]; then
  echo '{}' | sudo -u $SANDBOX_USER tee "$WORKSPACE/.claude/settings.json" > /dev/null
else
  echo "[dry-run] echo '{}' > $WORKSPACE/.claude/settings.json"
fi

echo "  Claude config: $WORKSPACE/.claude/settings.json"

# --- Configure git identity ---
echo ""
echo "# --- Configure git identity ---"

if [[ "$DRY_RUN" != "true" ]]; then
  sudo -u $SANDBOX_USER git config --global user.name "dyad-sandbox"
  sudo -u $SANDBOX_USER git config --global user.email "sandbox@dyad.local"
else
  echo "[dry-run] git config --global user.name 'dyad-sandbox'"
  echo "[dry-run] git config --global user.email 'sandbox@dyad.local'"
fi

echo "  Git identity: dyad-sandbox <sandbox@dyad.local>"

# --- Summary ---
echo ""
echo "========================================="
echo "  Sandbox setup complete!"
echo ""
echo "  User:      $SANDBOX_USER"
echo "  Workspace: $WORKSPACE"
echo "  Project:   $PROJECT_DEST"
echo "  Scripts:   $DYAD_INSTALL"
echo "  PATH dir:  $SANDBOX_BIN"
echo ""
echo "  Next: dyad-sandbox-run.sh \"your task here\""
echo "========================================="
