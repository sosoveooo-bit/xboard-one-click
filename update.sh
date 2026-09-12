#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XBOARD_DIR="$SCRIPT_DIR/runtime/Xboard"
NPM_DIR="$SCRIPT_DIR/runtime/nginx-proxy-manager"
source "$SCRIPT_DIR/lib/common.sh"
PRE_UPDATE_BACKUP_FILE=""
BASELINE_FILE=""
UPDATE_COMPLETED=0
AUTO_ROLLBACK_ON_UPDATE_FAIL=1

finish_update() {
  local status="$1"
  trap - EXIT
  if [ "$status" != 0 ] && [ "$UPDATE_COMPLETED" = 0 ]; then
    if [ -z "$PRE_UPDATE_BACKUP_FILE" ]; then
      echo '[xboard-update][WARN] 更新未成功；本次没有可用的更新前备份，未执行自动回滚。请查看上方错误，不要盲目重装或删除数据。' >&2
    else
      echo "[xboard-update] 更新失败，完整备份: $PRE_UPDATE_BACKUP_FILE" >&2
    fi
    if [ -n "$PRE_UPDATE_BACKUP_FILE" ] && [ "$AUTO_ROLLBACK_ON_UPDATE_FAIL" = 1 ]; then
      if RESTORE_OVERWRITE=1 bash "$SCRIPT_DIR/restore.sh" "$PRE_UPDATE_BACKUP_FILE"; then
        echo '[xboard-update] 原镜像和数据已恢复，健康检查通过。' >&2
      else
        echo '[xboard-update][WARN] 自动回滚未通过检查，不能报告成功；备份和恢复目录均已保留。' >&2
      fi
    fi
  fi
  [ -z "$BASELINE_FILE" ] || rm -f "$BASELINE_FILE"
  exit "$status"
}

main() {
  trap 'finish_update $?' EXIT
  trap 'exit 130' INT
  trap 'exit 143' TERM
  xb_require_runtime
  xb_lock "$SCRIPT_DIR"
  if [ -f "$SCRIPT_DIR/deploy.env" ]; then source "$SCRIPT_DIR/deploy.env"; fi
  local with_backup=0
  case "${1:-}" in
    '') ;;
    --with-backup) with_backup=1 ;;
    *) echo '用法: bash update.sh [--with-backup]' >&2; return 1 ;;
  esac
  [ "$#" -le 1 ] || { echo '更新参数过多。' >&2; return 1; }
  if [ "$with_backup" = 0 ]; then
    echo '[xboard-update][WARN] 本次直接更新：不创建备份，失败不能自动恢复原数据库。旧 PRE_UPDATE_BACKUP 配置不再决定更新方式。' >&2
  fi
  [ "$(python3 "$SCRIPT_DIR/lib/operations.py" install-state "$XBOARD_DIR")" = existing ] || { echo '未找到可更新的现有数据库。' >&2; return 1; }
  python3 "$SCRIPT_DIR/lib/operations.py" inventory "$SCRIPT_DIR"
  echo '[xboard-update] 检查当前部署是否健康；已有故障请先修复。'
  xb_healthcheck "$SCRIPT_DIR"
  if [ "$with_backup" = 1 ]; then
    PRE_UPDATE_BACKUP_FILE="$(BACKUP_KEEP_STOPPED=1 BACKUP_DIR="${SCRIPT_DIR}-backups/pre-update" bash "$SCRIPT_DIR/backup.sh")"
    [ -n "$PRE_UPDATE_BACKUP_FILE" ] && [ -f "$PRE_UPDATE_BACKUP_FILE" ] || { echo '备份没有返回有效文件，已停止更新。' >&2; return 1; }
  fi
  BASELINE_FILE="$(mktemp)"
  python3 "$SCRIPT_DIR/lib/operations.py" sqlite-check "$XBOARD_DIR/.docker/.data/database.sqlite" >"$BASELINE_FILE"
  local env_changed
  local recreate=()
  env_changed="$(python3 "$SCRIPT_DIR/lib/operations.py" normalize-existing-env "$XBOARD_DIR")"
  # Atomic .env changes need a new bind mount; unchanged files keep their inode.
  [ "$env_changed" != changed ] || recreate+=(--force-recreate)
  echo '[xboard-update] 使用现有 Compose 和 .env 更新镜像，不覆盖数据库连接、端口或站点配置。'
  python3 "$SCRIPT_DIR/lib/operations.py" pull-candidate-images "$SCRIPT_DIR"
  xb_compose "$XBOARD_DIR" up -d "${recreate[@]}"
  xb_wait_redis "$XBOARD_DIR"
  xb_compose "$XBOARD_DIR" exec -T xboard php artisan xboard:update
  xb_compose "$XBOARD_DIR" exec -T xboard php artisan optimize:clear
  xb_compose "$XBOARD_DIR" restart
  xb_wait_redis "$XBOARD_DIR"
  python3 "$SCRIPT_DIR/lib/operations.py" check-counts "$BASELINE_FILE" "$XBOARD_DIR/.docker/.data/database.sqlite"
  xb_compose "$NPM_DIR" up -d
  python3 "$SCRIPT_DIR/lib/operations.py" pin-images "$SCRIPT_DIR"
  xb_healthcheck "$SCRIPT_DIR"
  UPDATE_COMPLETED=1
  if [ -n "$PRE_UPDATE_BACKUP_FILE" ]; then
    echo "[xboard-update] 更新及数据检查通过。回滚备份: $PRE_UPDATE_BACKUP_FILE"
  else
    echo '[xboard-update] 更新及数据检查通过。本次未创建备份，未删除已有备份。'
  fi
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
