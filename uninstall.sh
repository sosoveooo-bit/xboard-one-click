#!/usr/bin/env bash
set -Eeuo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

main() {
  xb_require_runtime
  xb_lock "$SCRIPT_DIR"
  local mode=stop answer
  local args=()
  [ "${PURGE_DATA:-0}" != 1 ] || mode=data
  [ "${PURGE_ALL:-0}" != 1 ] || mode=all
  if [ "$mode" != stop ] && [ "${UNINSTALL_CONFIRM:-}" != DELETE ]; then
    [ -t 0 ] || { echo '删除数据需要显式设置 UNINSTALL_CONFIRM=DELETE。' >&2; return 1; }
    read -r -p "即将永久删除本项目运行数据（$SCRIPT_DIR/runtime），输入 DELETE 确认: " answer
    [ "$answer" = DELETE ] || return 1
  fi
  if [ "${PURGE_BACKUPS:-0}" = 1 ]; then
    [ "$mode" = all ] || { echo '删除备份仅可用于彻底卸载。' >&2; return 1; }
    if [ "${PURGE_BACKUPS_CONFIRM:-}" != DELETE_BACKUPS ]; then
      [ -t 0 ] || { echo '删除备份还需 PURGE_BACKUPS_CONFIRM=DELETE_BACKUPS。' >&2; return 1; }
      read -r -p "同时永久删除备份目录 ${BACKUP_DIR:-${SCRIPT_DIR}-backups}？输入 DELETE_BACKUPS 确认: " answer
      [ "$answer" = DELETE_BACKUPS ] || return 1
    fi
    args+=(--purge-backups)
  fi
  [ -z "${BACKUP_DIR:-}" ] || args+=(--backup-dir "$BACKUP_DIR")
  python3 "$SCRIPT_DIR/lib/operations.py" uninstall "$SCRIPT_DIR" "$mode" "${args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
