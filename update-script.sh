#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"
xb_lock "$SCRIPT_DIR"
REPO_URL="${REPO_URL:-https://github.com/sosoveooo-bit/xboard-one-click.git}" \
BRANCH="${BRANCH:-codex/fix-xboard-update-env}" \
INSTALL_DIR="$SCRIPT_DIR" bash "$SCRIPT_DIR/bootstrap.sh" --update-scripts
