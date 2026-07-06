#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_NAME="xboard-one-click-update"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/runtime"
NPM_DIR="${WORK_DIR}/nginx-proxy-manager"
XBOARD_DIR="${WORK_DIR}/Xboard"
DEPLOY_ENV_FILE="${SCRIPT_DIR}/deploy.env"

DEFAULT_XBOARD_BRANCH="compose"
DEFAULT_NPM_HTTP_PORT=80
DEFAULT_NPM_HTTPS_PORT=443
DEFAULT_NPM_ADMIN_PORT=81
DEFAULT_XBOARD_PORT=7001
DEFAULT_PRE_UPDATE_BACKUP=1
DEFAULT_AUTO_ROLLBACK_ON_UPDATE_FAIL=1

INPUT_NPM_HTTP_PORT="${NPM_HTTP_PORT:-}"
INPUT_NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-}"
INPUT_NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-}"
INPUT_EXTRA_NPM_HTTPS_PORTS="${EXTRA_NPM_HTTPS_PORTS:-}"
INPUT_XBOARD_BRANCH="${XBOARD_BRANCH:-}"
INPUT_XBOARD_PORT="${XBOARD_PORT:-}"
INPUT_PRE_UPDATE_BACKUP="${PRE_UPDATE_BACKUP:-}"
INPUT_AUTO_ROLLBACK_ON_UPDATE_FAIL="${AUTO_ROLLBACK_ON_UPDATE_FAIL:-}"

NPM_HTTP_PORT="${NPM_HTTP_PORT:-}"
NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-}"
NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-}"
EXTRA_NPM_HTTPS_PORTS="${EXTRA_NPM_HTTPS_PORTS:-}"
XBOARD_BRANCH="${XBOARD_BRANCH:-}"
XBOARD_PORT="${XBOARD_PORT:-}"
PRE_UPDATE_BACKUP="${PRE_UPDATE_BACKUP:-}"
AUTO_ROLLBACK_ON_UPDATE_FAIL="${AUTO_ROLLBACK_ON_UPDATE_FAIL:-}"
COMPOSE_CMD=()
XBOARD_ENV_BACKUP_FILE=""
PRE_UPDATE_BACKUP_FILE=""
UPDATE_COMPLETED=0
ROLLBACK_RUNNING=0

log() {
  printf '[%s] %s\n' "$PROJECT_NAME" "$*"
}

die() {
  printf '[%s][WARN] %s\n' "$PROJECT_NAME" "$*" >&2
  if declare -F rollback_from_pre_update_backup >/dev/null 2>&1; then
    rollback_from_pre_update_backup || true
  fi
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "缺少命令: $1"
}

run_compose() {
  local dir="$1"
  shift
  (cd "$dir" && "${COMPOSE_CMD[@]}" "$@")
}

cleanup_env_backup() {
  if [ -n "${XBOARD_ENV_BACKUP_FILE:-}" ] && [ -f "$XBOARD_ENV_BACKUP_FILE" ]; then
    rm -f "$XBOARD_ENV_BACKUP_FILE"
  fi
}

rollback_from_pre_update_backup() {
  [ "$UPDATE_COMPLETED" = "0" ] || return 0
  [ "$ROLLBACK_RUNNING" = "0" ] || return 0
  [ "$AUTO_ROLLBACK_ON_UPDATE_FAIL" = "1" ] || {
    if [ -n "$PRE_UPDATE_BACKUP_FILE" ]; then
      log "更新失败，已保留更新前备份，可手动恢复: RESTORE_OVERWRITE=1 bash \"$SCRIPT_DIR/restore.sh\" \"$PRE_UPDATE_BACKUP_FILE\""
    fi
    return 0
  }
  [ -n "$PRE_UPDATE_BACKUP_FILE" ] || {
    log "更新失败，但未找到更新前备份，无法自动回滚。"
    return 0
  }
  [ -f "$PRE_UPDATE_BACKUP_FILE" ] || {
    log "更新失败，但备份包不存在，无法自动回滚: $PRE_UPDATE_BACKUP_FILE"
    return 0
  }
  [ -f "$SCRIPT_DIR/restore.sh" ] || {
    log "更新失败，但未找到 restore.sh，无法自动回滚。备份包: $PRE_UPDATE_BACKUP_FILE"
    return 0
  }

  ROLLBACK_RUNNING=1
  log "更新失败，开始自动回滚到更新前备份: $PRE_UPDATE_BACKUP_FILE"
  if (cd / && RESTORE_OVERWRITE=1 bash "$SCRIPT_DIR/restore.sh" "$PRE_UPDATE_BACKUP_FILE"); then
    log "自动回滚完成。"
  else
    log "自动回滚失败，请手动恢复: RESTORE_OVERWRITE=1 bash \"$SCRIPT_DIR/restore.sh\" \"$PRE_UPDATE_BACKUP_FILE\""
  fi
}

handle_update_error() {
  local exit_code="${1:-1}"
  rollback_from_pre_update_backup || true
  exit "$exit_code"
}

backup_xboard_env() {
  local env_file="$XBOARD_DIR/.env"

  if [ ! -s "$env_file" ]; then
    die "Xboard .env 不存在或为空，已停止更新以避免重启后崩溃。请先恢复 $env_file 后重试。"
  fi

  XBOARD_ENV_BACKUP_FILE="$(mktemp)"
  cp "$env_file" "$XBOARD_ENV_BACKUP_FILE"
  log "已临时备份 Xboard .env"
}

restore_xboard_env() {
  local env_file="$XBOARD_DIR/.env"

  if [ -z "${XBOARD_ENV_BACKUP_FILE:-}" ] || [ ! -f "$XBOARD_ENV_BACKUP_FILE" ]; then
    die "未找到 Xboard .env 临时备份，已停止更新。"
  fi

  cp "$XBOARD_ENV_BACKUP_FILE" "$env_file"

  if [ ! -s "$env_file" ]; then
    die "Xboard .env 恢复失败，已停止更新以避免重启后崩溃。"
  fi

  log "已恢复 Xboard .env"
}

ensure_xboard_builtin_redis_config() {
  local env_file="$XBOARD_DIR/.env"

  [ -s "$env_file" ] || die "Xboard .env 不存在或为空，无法修正 SQLite/Redis 配置。"

  python3 - "$env_file" <<'PY'
from pathlib import Path
import sys

path = Path(sys.argv[1])
updates = {
    "DB_CONNECTION": "sqlite",
    "DB_DATABASE": ".docker/.data/database.sqlite",
    "REDIS_HOST": "/data/redis.sock",
    "REDIS_PORT": "0",
    "REDIS_PASSWORD": "null",
    "ENABLE_AUTO_BACKUP_AND_UPDATE": "false",
}
lines = path.read_text().splitlines()
seen = set()
out = []
for line in lines:
    if "=" in line and not line.lstrip().startswith("#"):
        key = line.split("=", 1)[0]
        if key in updates:
            out.append(f"{key}={updates[key]}")
            seen.add(key)
            continue
    out.append(line)
for key, value in updates.items():
    if key not in seen:
        out.append(f"{key}={value}")
path.write_text("\n".join(out).rstrip("\n") + "\n")
PY

  log "已修正 Xboard SQLite/Redis 配置"
}

run_pre_update_backup() {
  local backup_dir

  [ "$PRE_UPDATE_BACKUP" = "1" ] || {
    log "已跳过更新前备份（PRE_UPDATE_BACKUP=${PRE_UPDATE_BACKUP}）"
    return 0
  }

  [ -f "$SCRIPT_DIR/backup.sh" ] || die "未找到备份脚本，无法执行更新前备份: $SCRIPT_DIR/backup.sh"
  backup_dir="${SCRIPT_DIR}-backups/pre-update"
  log "开始更新前自动备份"
  BACKUP_DIR="$backup_dir" bash "$SCRIPT_DIR/backup.sh"
  PRE_UPDATE_BACKUP_FILE="$(ls -1t "$backup_dir"/*.tar.gz 2>/dev/null | head -n 1 || true)"
  [ -n "$PRE_UPDATE_BACKUP_FILE" ] && [ -f "$PRE_UPDATE_BACKUP_FILE" ] || die "更新前备份完成后未找到备份包，已停止更新。"
  log "更新前备份包: $PRE_UPDATE_BACKUP_FILE"
}

run_healthcheck() {
  [ -f "$SCRIPT_DIR/healthcheck.sh" ] || {
    log "未找到 healthcheck.sh，跳过健康检查"
    return 0
  }

  log "执行更新后健康检查"
  bash "$SCRIPT_DIR/healthcheck.sh"
}

normalize_port_csv() {
  printf '%s' "$1" | tr ', ' '\n\n' | awk 'NF && !seen[$0]++ {printf("%s%s", sep, $0); sep=","}'
}

extra_https_ports_to_array() {
  local normalized
  normalized="$(normalize_port_csv "$EXTRA_NPM_HTTPS_PORTS")"
  EXTRA_NPM_HTTPS_PORTS="$normalized"

  if [ -n "$normalized" ]; then
    IFS=',' read -r -a EXTRA_HTTPS_PORTS_ARRAY <<< "$normalized"
  else
    EXTRA_HTTPS_PORTS_ARRAY=()
  fi
}

install_menu_shortcut() {
  local target="/usr/local/bin/xb"

  if [ ! -f "$SCRIPT_DIR/menu.sh" ]; then
    log "未找到 menu.sh，跳过安装 xb 快捷命令"
    return 0
  fi

  cat >"$target" <<EOF
#!/usr/bin/env bash
exec bash "${SCRIPT_DIR}/menu.sh" "\$@"
EOF
  chmod +x "$target"

  log "已安装快捷命令: xb -> ${SCRIPT_DIR}/menu.sh"
}

load_deploy_env() {
  if [ -f "$DEPLOY_ENV_FILE" ]; then
    log "加载本地配置文件: $DEPLOY_ENV_FILE"
    set -a
    # shellcheck disable=SC1090
    . "$DEPLOY_ENV_FILE"
    set +a
  fi

  [ -z "$INPUT_NPM_HTTP_PORT" ] || NPM_HTTP_PORT="$INPUT_NPM_HTTP_PORT"
  [ -z "$INPUT_NPM_HTTPS_PORT" ] || NPM_HTTPS_PORT="$INPUT_NPM_HTTPS_PORT"
  [ -z "$INPUT_NPM_ADMIN_PORT" ] || NPM_ADMIN_PORT="$INPUT_NPM_ADMIN_PORT"
  [ -z "$INPUT_EXTRA_NPM_HTTPS_PORTS" ] || EXTRA_NPM_HTTPS_PORTS="$INPUT_EXTRA_NPM_HTTPS_PORTS"
  [ -z "$INPUT_XBOARD_BRANCH" ] || XBOARD_BRANCH="$INPUT_XBOARD_BRANCH"
  [ -z "$INPUT_XBOARD_PORT" ] || XBOARD_PORT="$INPUT_XBOARD_PORT"
  [ -z "$INPUT_PRE_UPDATE_BACKUP" ] || PRE_UPDATE_BACKUP="$INPUT_PRE_UPDATE_BACKUP"
  [ -z "$INPUT_AUTO_ROLLBACK_ON_UPDATE_FAIL" ] || AUTO_ROLLBACK_ON_UPDATE_FAIL="$INPUT_AUTO_ROLLBACK_ON_UPDATE_FAIL"
}

apply_defaults() {
  NPM_HTTP_PORT="${NPM_HTTP_PORT:-${DEFAULT_NPM_HTTP_PORT}}"
  NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-${DEFAULT_NPM_HTTPS_PORT}}"
  NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-${DEFAULT_NPM_ADMIN_PORT}}"
  EXTRA_NPM_HTTPS_PORTS="${EXTRA_NPM_HTTPS_PORTS:-}"
  XBOARD_BRANCH="${XBOARD_BRANCH:-${DEFAULT_XBOARD_BRANCH}}"
  XBOARD_PORT="${XBOARD_PORT:-${DEFAULT_XBOARD_PORT}}"
  PRE_UPDATE_BACKUP="${PRE_UPDATE_BACKUP:-${DEFAULT_PRE_UPDATE_BACKUP}}"
  AUTO_ROLLBACK_ON_UPDATE_FAIL="${AUTO_ROLLBACK_ON_UPDATE_FAIL:-${DEFAULT_AUTO_ROLLBACK_ON_UPDATE_FAIL}}"
}

write_npm_compose() {
  extra_https_ports_to_array

  {
    cat <<EOF
services:
  app:
    image: jc21/nginx-proxy-manager:latest
    restart: unless-stopped
    ports:
      - "${NPM_HTTP_PORT}:80"
      - "${NPM_HTTPS_PORT}:443"
      - "${NPM_ADMIN_PORT}:81"
EOF

    if [ ${#EXTRA_HTTPS_PORTS_ARRAY[@]} -gt 0 ]; then
      local port
      for port in "${EXTRA_HTTPS_PORTS_ARRAY[@]}"; do
        printf '      - "%s:443"\n' "$port"
      done
    fi

    cat <<EOF
    volumes:
      - ./data:/data
      - ./letsencrypt:/etc/letsencrypt
EOF
  } >"$NPM_DIR/compose.yaml"
}

check_env() {
  need_cmd git
  need_cmd docker
  need_cmd python3

  if docker compose version >/dev/null 2>&1; then
    COMPOSE_CMD=(docker compose)
  elif command -v docker-compose >/dev/null 2>&1; then
    COMPOSE_CMD=(docker-compose)
  else
    die "未找到 docker compose / docker-compose"
  fi

  docker info >/dev/null 2>&1 || die "当前用户无法访问 Docker daemon。"
}

ensure_xboard_port_mapping() {
  python3 - "$XBOARD_DIR/compose.yaml" "$XBOARD_PORT" <<'PY'
from pathlib import Path
import re
import sys
path = Path(sys.argv[1])
port = sys.argv[2]
text = path.read_text()
text_new = text.replace('"7001:7001"', f'"{port}:7001"', 1)
if text_new == text:
    text_new = re.sub(r'-\s*"\d+:7001"', f'- "{port}:7001"', text, count=1)
if text_new == text:
    raise SystemExit('未在 compose.yaml 中找到可替换的 Xboard 端口映射，已停止以避免误改。')
path.write_text(text_new)
PY

  if ! grep -Fq "\"${XBOARD_PORT}:7001\"" "$XBOARD_DIR/compose.yaml"; then
    die "compose.yaml 端口映射校验失败，未发现 ${XBOARD_PORT}:7001"
  fi

  log "compose.yaml 端口映射已更新为 ${XBOARD_PORT}:7001"
}

wait_for_xboard_redis() {
  local attempt=1
  local max_attempts=30

  while [ "$attempt" -le "$max_attempts" ]; do
    if run_compose "$XBOARD_DIR" exec -T xboard sh -lc 'test -S /data/redis.sock'; then
      log "检测到 Xboard 内置 Redis 已就绪"
      return 0
    fi

    sleep 2
    attempt=$((attempt + 1))
  done

  run_compose "$XBOARD_DIR" logs --tail=120 xboard || true
  die "Xboard 内置 Redis 未能及时启动，更新失败。"
}

refresh_xboard_runtime() {
  log "清理 Xboard 缓存并重启容器"
  run_compose "$XBOARD_DIR" exec -T xboard php artisan optimize:clear || true
  run_compose "$XBOARD_DIR" restart xboard
  wait_for_xboard_redis
}

run_xboard_post_update() {
  log "执行 Xboard 数据库迁移和插件更新"
  wait_for_xboard_redis
  run_compose "$XBOARD_DIR" exec -T xboard php artisan optimize:clear || true
  run_compose "$XBOARD_DIR" exec -T xboard php artisan xboard:update
  refresh_xboard_runtime
}

main() {
  trap cleanup_env_backup EXIT
  trap 'handle_update_error $?' ERR

  load_deploy_env
  apply_defaults
  check_env

  [ -f "$NPM_DIR/compose.yaml" ] || die "未找到 NPM 部署目录，请先执行 ./install.sh"
  [ -d "$XBOARD_DIR/.git" ] || die "未找到 Xboard 运行目录，请先执行 ./install.sh"
  run_pre_update_backup
  backup_xboard_env

  log "按 deploy.env 重写 Nginx Proxy Manager compose 配置"
  write_npm_compose

  log "更新 Nginx Proxy Manager 镜像"
  run_compose "$NPM_DIR" pull
  run_compose "$NPM_DIR" up -d

  log "更新 Xboard 仓库代码"
  git -C "$XBOARD_DIR" fetch origin "$XBOARD_BRANCH" --depth 1
  git -C "$XBOARD_DIR" checkout -B "$XBOARD_BRANCH" "origin/$XBOARD_BRANCH"
  git -C "$XBOARD_DIR" reset --hard "origin/$XBOARD_BRANCH"
  restore_xboard_env
  ensure_xboard_builtin_redis_config
  ensure_xboard_port_mapping

  log "更新 Xboard 镜像并重建容器"
  run_compose "$XBOARD_DIR" pull
  run_compose "$XBOARD_DIR" up -d
  run_compose "$XBOARD_DIR" port xboard 7001
  run_xboard_post_update

  install_menu_shortcut
  run_healthcheck

  UPDATE_COMPLETED=1
  log "更新完成（当前 Xboard 对外端口: $XBOARD_PORT）"
}

main "$@"
