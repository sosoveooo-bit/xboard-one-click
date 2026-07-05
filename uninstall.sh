#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="xboard-one-click-uninstall"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/runtime"
NPM_DIR="${WORK_DIR}/nginx-proxy-manager"
XBOARD_DIR="${WORK_DIR}/Xboard"
PURGE_DATA="${PURGE_DATA:-0}"
PURGE_ALL="${PURGE_ALL:-0}"
BACKUP_DIR="${BACKUP_DIR:-${SCRIPT_DIR}-backups}"
SHORTCUT_PATH="/usr/local/bin/xb"

COMPOSE_CMD=()

log() {
  printf '[%s] %s\n' "$PROJECT_NAME" "$*"
}

warn() {
  printf '[%s][WARN] %s\n' "$PROJECT_NAME" "$*" >&2
}

check_env() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    warn "未找到 docker compose / docker-compose，只执行文件级清理。"
  fi
}

compose_down_if_exists() {
  local dir="$1"

  if [ ${#COMPOSE_CMD[@]} -eq 0 ] || [ ! -f "$dir/compose.yaml" ]; then
    return 0
  fi

  if [ "$PURGE_ALL" = "1" ]; then
    (cd "$dir" && "${COMPOSE_CMD[@]}" down -v --remove-orphans || true)
  else
    (cd "$dir" && "${COMPOSE_CMD[@]}" down || true)
  fi
}

remove_known_containers() {
  command -v docker >/dev/null 2>&1 || return 0
  docker rm -f nginx-proxy-manager-app-1 xboard-xboard-1 2>/dev/null || true
}

remove_known_docker_resources() {
  command -v docker >/dev/null 2>&1 || return 0

  docker volume ls --format '{{.Name}}' \
    | grep -E '^(xboard|nginx-proxy-manager|xboard-one-click)_' \
    | xargs -r docker volume rm 2>/dev/null || true

  docker network ls --format '{{.Name}}' \
    | grep -E '^(xboard|nginx-proxy-manager|xboard-one-click)_' \
    | xargs -r docker network rm 2>/dev/null || true
}

remove_project_files() {
  local project_dir="$SCRIPT_DIR"

  case "$project_dir" in
    ""|"/"|"/root"|"/home"|"/usr"|"/usr/local")
      warn "项目目录安全校验失败，拒绝删除: ${project_dir:-空}"
      return 1
      ;;
  esac

  if [ "$(basename "$project_dir")" != "xboard-one-click" ]; then
    warn "项目目录名称不是 xboard-one-click，拒绝删除: $project_dir"
    return 1
  fi

  log "删除快捷命令: $SHORTCUT_PATH"
  rm -f "$SHORTCUT_PATH"

  log "删除备份目录: $BACKUP_DIR"
  rm -rf "$BACKUP_DIR"

  log "删除项目目录: $project_dir"
  cd /
  rm -rf "$project_dir"
}

main() {
  check_env
  compose_down_if_exists "$NPM_DIR"
  compose_down_if_exists "$XBOARD_DIR"

  if [ "$PURGE_ALL" = "1" ]; then
    log "PURGE_ALL=1，彻底删除容器、volume、运行数据、备份目录、快捷命令和项目脚本。"
    remove_known_containers
    remove_known_docker_resources
    rm -rf "$WORK_DIR"
    remove_project_files
  elif [ "$PURGE_DATA" = "1" ]; then
    log "PURGE_DATA=1，删除运行目录: $WORK_DIR"
    remove_known_containers
    rm -rf "$WORK_DIR"
  else
    log "已停止容器，但保留数据目录。若要删除运行数据，请执行: PURGE_DATA=1 ./uninstall.sh"
    log "若要彻底删除脚本和所有数据，请执行: PURGE_ALL=1 ./uninstall.sh"
  fi
}

main "$@"
