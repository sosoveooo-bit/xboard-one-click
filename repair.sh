#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XBOARD_DIR="$SCRIPT_DIR/runtime/Xboard"
source "$SCRIPT_DIR/lib/common.sh"
REPAIR_BACKUP=""
REPAIR_COMPLETE=0
BASELINE_FILE=""

finish_repair() {
  local status="$1"
  trap - EXIT
  if [ "$status" != 0 ] && [ "$REPAIR_COMPLETE" = 0 ] && [ -n "$REPAIR_BACKUP" ]; then
    echo "[xboard-repair] 修复未成功，恢复修复前快照: $REPAIR_BACKUP" >&2
    RESTORE_OVERWRITE=1 bash "$SCRIPT_DIR/restore.sh" "$REPAIR_BACKUP" || echo '[WARN] 原部署本身可能已不健康；恢复未通过检查，备份和原数据仍然保留。' >&2
  fi
  [ -z "$BASELINE_FILE" ] || rm -f "$BASELINE_FILE"
  exit "$status"
}

main() {
  trap 'finish_repair $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  xb_require_runtime
  xb_lock "$SCRIPT_DIR"
  [ "$(python3 "$SCRIPT_DIR/lib/operations.py" install-state "$XBOARD_DIR")" = existing ] || { echo '没有可修复的现有数据库，请使用安装入口；不会自动初始化。' >&2; return 1; }
  echo '[xboard-repair] 保留原库、APP_KEY、用户和节点；不拉取新镜像、不修改管理员密码。'
  REPAIR_BACKUP="$(BACKUP_KEEP_STOPPED=1 BACKUP_DIR="${SCRIPT_DIR}-backups/pre-repair" bash "$SCRIPT_DIR/backup.sh")"
  BASELINE_FILE="$(mktemp)"
  python3 "$SCRIPT_DIR/lib/operations.py" sqlite-check "$XBOARD_DIR/.docker/.data/database.sqlite" >"$BASELINE_FILE"
  python3 "$SCRIPT_DIR/lib/operations.py" pin-images "$SCRIPT_DIR"
  python3 "$SCRIPT_DIR/lib/operations.py" normalize-existing-env "$XBOARD_DIR"
  xb_compose "$XBOARD_DIR" up -d --force-recreate
  xb_wait_redis "$XBOARD_DIR"
  xb_compose "$XBOARD_DIR" exec -T xboard php artisan migrate --force
  xb_compose "$XBOARD_DIR" exec -T xboard php artisan optimize:clear
  xb_compose "$XBOARD_DIR" restart
  xb_wait_redis "$XBOARD_DIR"
  python3 "$SCRIPT_DIR/lib/operations.py" check-counts "$BASELINE_FILE" "$XBOARD_DIR/.docker/.data/database.sqlite"
  xb_compose "$SCRIPT_DIR/runtime/nginx-proxy-manager" up -d
  xb_healthcheck "$SCRIPT_DIR"
  REPAIR_COMPLETE=1
  echo '[xboard-repair] 修复完成，数据检查和服务检查通过。'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
