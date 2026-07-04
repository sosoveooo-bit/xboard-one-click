#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="xboard-one-click-backup"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR_NAME="$(basename "$SCRIPT_DIR")"
PROJECT_PARENT_DIR="$(dirname "$SCRIPT_DIR")"
WORK_DIR="${SCRIPT_DIR}/runtime"
NPM_DIR="${WORK_DIR}/nginx-proxy-manager"
XBOARD_DIR="${WORK_DIR}/Xboard"
BACKUP_DIR="${BACKUP_DIR:-${PROJECT_PARENT_DIR}/${PROJECT_DIR_NAME}-backups}"
BACKUP_FILE="${BACKUP_FILE:-}"
COMPOSE_CMD=()
STOPPED_NPM=0
STOPPED_XBOARD=0

log() {
  printf '[%s] %s\n' "$PROJECT_NAME" "$*"
}

warn() {
  printf '[%s][WARN] %s\n' "$PROJECT_NAME" "$*" >&2
}

die() {
  warn "$*"
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

has_compose_file() {
  local dir="$1"
  [ -f "$dir/compose.yaml" ] || [ -f "$dir/docker-compose.yml" ] || [ -f "$dir/docker-compose.yaml" ]
}

run_compose() {
  local dir="$1"
  shift
  (cd "$dir" && "${COMPOSE_CMD[@]}" "$@")
}

check_env() {
  need_cmd tar
  need_cmd date

  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    warn "未找到 docker compose / docker-compose，将只打包文件，不尝试停止容器。"
    COMPOSE_CMD=()
  fi
}

is_compose_service_running() {
  local dir="$1"
  local service="$2"
  local ids

  [ ${#COMPOSE_CMD[@]} -gt 0 ] || return 1
  has_compose_file "$dir" || return 1

  ids="$(run_compose "$dir" ps -q "$service" 2>/dev/null || true)"
  [ -n "$ids" ]
}

stop_compose_project_for_backup() {
  local label="$1"
  local dir="$2"
  local service="$3"

  [ ${#COMPOSE_CMD[@]} -gt 0 ] || return 0
  has_compose_file "$dir" || return 0

  if is_compose_service_running "$dir" "$service"; then
    log "停止 ${label} 容器，确保备份一致"
    run_compose "$dir" down
    case "$label" in
      NPM) STOPPED_NPM=1 ;;
      Xboard) STOPPED_XBOARD=1 ;;
    esac
  else
    log "${label} 未运行，跳过停止"
  fi
}

restart_stopped_projects() {
  if [ "$STOPPED_NPM" = "1" ] && has_compose_file "$NPM_DIR"; then
    log "恢复启动 NPM"
    run_compose "$NPM_DIR" up -d || warn "NPM 恢复启动失败，请稍后手动执行 docker compose up -d"
  fi

  if [ "$STOPPED_XBOARD" = "1" ] && has_compose_file "$XBOARD_DIR"; then
    log "恢复启动 Xboard"
    run_compose "$XBOARD_DIR" up -d || warn "Xboard 恢复启动失败，请稍后手动执行 docker compose up -d"
  fi
}

backup_size() {
  local file="$1"

  if command -v du >/dev/null 2>&1; then
    du -h "$file" | awk '{print $1}'
  else
    wc -c <"$file"
  fi
}

create_backup() {
  local timestamp
  local output_file

  [ -d "$SCRIPT_DIR" ] || die "项目目录不存在: $SCRIPT_DIR"
  [ -d "$WORK_DIR" ] || die "运行目录不存在: $WORK_DIR。请先完成部署后再备份。"

  mkdir -p "$BACKUP_DIR"
  timestamp="$(date +%Y%m%d-%H%M%S)"
  output_file="${BACKUP_FILE:-${BACKUP_DIR}/${PROJECT_DIR_NAME}-backup-${timestamp}.tar.gz}"

  log "开始打包迁移备份: $output_file"
  tar \
    --exclude="${PROJECT_DIR_NAME}-backups" \
    -czf "$output_file" \
    -C "$PROJECT_PARENT_DIR" \
    "$PROJECT_DIR_NAME"

  log "备份完成: $output_file"
  log "备份大小: $(backup_size "$output_file")"
  log "迁移到新服务器后执行: tar -xzf $(basename "$output_file") -C /root"
}

main() {
  trap restart_stopped_projects EXIT

  check_env
  stop_compose_project_for_backup "NPM" "$NPM_DIR" app
  stop_compose_project_for_backup "Xboard" "$XBOARD_DIR" xboard
  create_backup
}

main "$@"
