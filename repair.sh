#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="xboard-one-click-repair"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log() {
  printf '[%s] %s\n' "$PROJECT_NAME" "$*"
}

die() {
  printf '[%s][WARN] %s\n' "$PROJECT_NAME" "$*" >&2
  exit 1
}

main() {
  [ -f "$SCRIPT_DIR/install.sh" ] || die "未找到 install.sh: $SCRIPT_DIR/install.sh"

  log "开始修复 Xboard 运行环境"
  log "将复用 deploy.env 中的端口配置；若 SQLite 缺表或损坏，会先备份旧库再重新初始化"

  AUTO_WRITE_DEPLOY_ENV=0 bash "$SCRIPT_DIR/install.sh" --non-interactive

  if [ -f "$SCRIPT_DIR/healthcheck.sh" ]; then
    log "执行修复后健康检查"
    bash "$SCRIPT_DIR/healthcheck.sh"
  fi

  log "修复完成"
}

main "$@"
