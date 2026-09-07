#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

main() {
  xb_require_runtime
  local archive="${1:-${BACKUP_FILE:-}}" target answer
  local args=()
  target="${RESTORE_PARENT_DIR:-$(dirname "$SCRIPT_DIR")}/xboard-one-click"
  [ -n "$archive" ] || archive="$(python3 "$SCRIPT_DIR/lib/operations.py" select-backup "$SCRIPT_DIR")"
  if [ -d "$target" ] && [ "${RESTORE_OVERWRITE:-0}" != 1 ]; then
    [ -t 0 ] || { echo '目标已存在；确认恢复请设置 RESTORE_OVERWRITE=1。' >&2; return 1; }
    read -r -p "旧目录将保留，确认从备份恢复到 $target？[y/N]: " answer
    case "$answer" in y|Y) ;; *) return 1 ;; esac
  fi
  [ ! -d "$target" ] || args+=(--overwrite)
  if [ "${ALLOW_LEGACY_RESTORE:-0}" = 1 ]; then
    echo '[WARN] 已明确允许旧格式备份：旧包可能没有镜像/Redis 数据卷，无法保证恢复到原版本。' >&2
    args+=(--allow-legacy)
  fi
  xb_lock "$target"
  python3 "$SCRIPT_DIR/lib/operations.py" restore "$archive" "$target" "${args[@]}"
  echo '[xboard-restore] 恢复成功，服务检查已通过；旧目录和原备份包均保留。'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
