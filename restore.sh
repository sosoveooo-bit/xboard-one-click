#!/usr/bin/env bash
set -euo pipefail

PROJECT_NAME="xboard-one-click-restore"
ARCHIVE="${1:-${BACKUP_FILE:-}}"
RESTORE_PARENT_DIR="${RESTORE_PARENT_DIR:-/root}"
PROJECT_DIR_NAME="xboard-one-click"
PROJECT_DIR="${RESTORE_PARENT_DIR}/${PROJECT_DIR_NAME}"
RESTORE_OVERWRITE="${RESTORE_OVERWRITE:-}"
COMPOSE_CMD=()
NPM_HTTP_PORT=""
NPM_HTTPS_PORT=""
AUTO_RELEASE_NPM_PORTS=""

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

print_usage() {
  cat <<EOF
用法:
  ./restore.sh /root/xboard-one-click-backups/xboard-one-click-backup-YYYYmmdd-HHMMSS.tar.gz

可选环境变量:
  RESTORE_PARENT_DIR=/root       恢复到哪个父目录
  RESTORE_OVERWRITE=1            已存在 /root/xboard-one-click 时自动移走旧目录
EOF
}

init_compose() {
  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    COMPOSE_CMD=()
  fi
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

stop_existing_project() {
  [ ${#COMPOSE_CMD[@]} -gt 0 ] || return 0

  if has_compose_file "$PROJECT_DIR/runtime/nginx-proxy-manager"; then
    log "停止现有 NPM 容器"
    run_compose "$PROJECT_DIR/runtime/nginx-proxy-manager" down || true
  fi

  if has_compose_file "$PROJECT_DIR/runtime/Xboard"; then
    log "停止现有 Xboard 容器"
    run_compose "$PROJECT_DIR/runtime/Xboard" down || true
  fi
}

confirm_overwrite_if_needed() {
  local answer
  local current_dir

  [ -d "$PROJECT_DIR" ] || return 0

  current_dir="$(pwd -P)"
  if [ "$current_dir" = "$PROJECT_DIR" ]; then
    die "当前目录在旧项目目录内。请先执行 cd \"$RESTORE_PARENT_DIR\" 后再恢复。"
  fi

  case "${current_dir}/" in
    "$PROJECT_DIR"/*)
      die "当前目录在旧项目目录内。请先执行 cd \"$RESTORE_PARENT_DIR\" 后再恢复。"
      ;;
  esac

  if [ "$RESTORE_OVERWRITE" = "1" ]; then
    return 0
  fi

  if [ -t 0 ]; then
    warn "目标目录已存在: $PROJECT_DIR"
    read -r -p "是否将旧目录改名备份后继续恢复？[y/N]: " answer || true
    case "$answer" in
      y|Y) return 0 ;;
    esac
  fi

  die "已取消恢复。若确认覆盖，可使用 RESTORE_OVERWRITE=1。"
}

validate_archive() {
  local top

  [ -n "$ARCHIVE" ] || {
    print_usage
    exit 1
  }
  [ -f "$ARCHIVE" ] || die "备份包不存在: $ARCHIVE"

  top="$(tar -tzf "$ARCHIVE" | sed -n '1p' | cut -d/ -f1)"
  [ "$top" = "$PROJECT_DIR_NAME" ] || die "备份包格式不正确，顶层目录应为 ${PROJECT_DIR_NAME}，实际为: ${top:-空}"
}

move_existing_project() {
  local timestamp
  local old_dir

  [ -d "$PROJECT_DIR" ] || return 0

  timestamp="$(date +%Y%m%d-%H%M%S)"
  old_dir="${PROJECT_DIR}.before-restore-${timestamp}"
  log "保留旧目录为: $old_dir"
  mv "$PROJECT_DIR" "$old_dir"
}

install_menu_shortcut() {
  local target="/usr/local/bin/xb"

  if [ "$(id -u)" -ne 0 ]; then
    warn "当前不是 root，跳过安装快捷命令: $target"
    return 0
  fi

  cat >"$target" <<EOF
#!/usr/bin/env bash
exec bash "${PROJECT_DIR}/menu.sh" "\$@"
EOF
  chmod +x "$target"
  log "已恢复快捷命令: xb -> ${PROJECT_DIR}/menu.sh"
}

load_restored_deploy_env() {
  local env_file="$PROJECT_DIR/deploy.env"

  NPM_HTTP_PORT=80
  NPM_HTTPS_PORT=443
  AUTO_RELEASE_NPM_PORTS=1

  if [ -f "$env_file" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$env_file"
    set +a
  fi
}

list_port_listeners() {
  local port="$1"

  if command -v ss >/dev/null 2>&1; then
    ss -H -ltnp 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" {print}'
    return 0
  fi

  if command -v netstat >/dev/null 2>&1; then
    netstat -ltnp 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" {print}'
    return 0
  fi
}

release_ports_for_restored_npm() {
  [ "$AUTO_RELEASE_NPM_PORTS" = "1" ] || return 0
  command -v systemctl >/dev/null 2>&1 || return 0
  if [ "$(id -u)" -ne 0 ]; then
    warn "当前不是 root，无法自动释放 NPM 端口。若启动失败，请手动停止 nginx/apache/openresty/caddy。"
    return 0
  fi

  local ports=("$NPM_HTTP_PORT" "$NPM_HTTPS_PORT")
  local units=(nginx apache2 httpd openresty caddy)
  local port
  local unit
  local listeners

  for port in "${ports[@]}"; do
    listeners="$(list_port_listeners "$port" || true)"
    [ -n "$listeners" ] || continue

    for unit in "${units[@]}"; do
      case "$listeners" in
        *"$unit"*)
          if systemctl is-active --quiet "$unit" 2>/dev/null; then
            log "释放 NPM 端口 ${port}: 停止并禁用 $unit"
            systemctl stop "$unit"
            systemctl disable "$unit" >/dev/null 2>&1 || true
          fi
          ;;
      esac
    done
  done
}

start_restored_project() {
  [ ${#COMPOSE_CMD[@]} -gt 0 ] || {
    warn "未找到 docker compose / docker-compose，跳过启动容器。"
    return 0
  }

  if has_compose_file "$PROJECT_DIR/runtime/nginx-proxy-manager"; then
    log "启动 NPM"
    run_compose "$PROJECT_DIR/runtime/nginx-proxy-manager" up -d
  fi

  if has_compose_file "$PROJECT_DIR/runtime/Xboard"; then
    log "启动 Xboard"
    run_compose "$PROJECT_DIR/runtime/Xboard" up -d
  fi
}

run_healthcheck() {
  if [ -f "$PROJECT_DIR/healthcheck.sh" ]; then
    log "执行恢复后健康检查"
    bash "$PROJECT_DIR/healthcheck.sh" || warn "健康检查发现问题，请查看上方输出。"
  fi
}

main() {
  need_cmd tar
  need_cmd date
  validate_archive
  init_compose
  confirm_overwrite_if_needed
  stop_existing_project
  move_existing_project

  log "解压备份包到: $RESTORE_PARENT_DIR"
  mkdir -p "$RESTORE_PARENT_DIR"
  tar -xzf "$ARCHIVE" -C "$RESTORE_PARENT_DIR"
  chmod +x "$PROJECT_DIR"/*.sh 2>/dev/null || true
  load_restored_deploy_env
  release_ports_for_restored_npm
  install_menu_shortcut
  start_restored_project
  run_healthcheck
  log "恢复完成: $PROJECT_DIR"
}

main "$@"
