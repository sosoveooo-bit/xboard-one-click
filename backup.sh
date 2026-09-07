#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

main() {
  xb_require_runtime
  xb_lock "$SCRIPT_DIR"
  local args=()
  [ -z "${BACKUP_FILE:-}" ] || args+=(--output "$BACKUP_FILE")
  [ "${BACKUP_KEEP_STOPPED:-0}" != 1 ] || args+=(--keep-stopped)
  echo '[xboard-backup] 完整备份包含配置、数据库、证书、准确镜像和命名数据卷；打包期间会暂停服务。' >&2
  python3 "$SCRIPT_DIR/lib/operations.py" backup "$SCRIPT_DIR" "${BACKUP_DIR:-${SCRIPT_DIR}-backups}" "${args[@]}"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
