#!/usr/bin/env bash
set -euo pipefail

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

INPUT_NPM_HTTP_PORT="${NPM_HTTP_PORT:-}"
INPUT_NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-}"
INPUT_NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-}"
INPUT_EXTRA_NPM_HTTPS_PORTS="${EXTRA_NPM_HTTPS_PORTS:-}"
INPUT_XBOARD_BRANCH="${XBOARD_BRANCH:-}"
INPUT_XBOARD_PORT="${XBOARD_PORT:-}"
INPUT_PRE_UPDATE_BACKUP="${PRE_UPDATE_BACKUP:-}"

NPM_HTTP_PORT="${NPM_HTTP_PORT:-}"
NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-}"
NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-}"
EXTRA_NPM_HTTPS_PORTS="${EXTRA_NPM_HTTPS_PORTS:-}"
XBOARD_BRANCH="${XBOARD_BRANCH:-}"
XBOARD_PORT="${XBOARD_PORT:-}"
PRE_UPDATE_BACKUP="${PRE_UPDATE_BACKUP:-}"
COMPOSE_CMD=()
XBOARD_ENV_BACKUP_FILE=""

log() {
  printf '[%s] %s\n' "$PROJECT_NAME" "$*"
}

die() {
  printf '[%s][WARN] %s\n' "$PROJECT_NAME" "$*" >&2
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
  [ "$PRE_UPDATE_BACKUP" = "1" ] || {
    log "已跳过更新前备份（PRE_UPDATE_BACKUP=${PRE_UPDATE_BACKUP}）"
    return 0
  }

  [ -f "$SCRIPT_DIR/backup.sh" ] || die "未找到备份脚本，无法执行更新前备份: $SCRIPT_DIR/backup.sh"
  log "开始更新前自动备份"
  BACKUP_DIR="${SCRIPT_DIR}-backups/pre-update" bash "$SCRIPT_DIR/backup.sh"
}

run_healthcheck() {
  [ -f "$SCRIPT_DIR/healthcheck.sh" ] || {
    log "未找到 healthcheck.sh，跳过健康检查"
    return 0
  }

  log "执行更新后健康检查"
  bash "$SCRIPT_DIR/healthcheck.sh" || log "健康检查发现问题，请查看上方日志。"
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
}

apply_defaults() {
  NPM_HTTP_PORT="${NPM_HTTP_PORT:-${DEFAULT_NPM_HTTP_PORT}}"
  NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-${DEFAULT_NPM_HTTPS_PORT}}"
  NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-${DEFAULT_NPM_ADMIN_PORT}}"
  EXTRA_NPM_HTTPS_PORTS="${EXTRA_NPM_HTTPS_PORTS:-}"
  XBOARD_BRANCH="${XBOARD_BRANCH:-${DEFAULT_XBOARD_BRANCH}}"
  XBOARD_PORT="${XBOARD_PORT:-${DEFAULT_XBOARD_PORT}}"
  PRE_UPDATE_BACKUP="${PRE_UPDATE_BACKUP:-${DEFAULT_PRE_UPDATE_BACKUP}}"
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

main() {
  trap cleanup_env_backup EXIT

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
  git -C "$XBOARD_DIR" checkout "$XBOARD_BRANCH"
  git -C "$XBOARD_DIR" reset --hard "origin/$XBOARD_BRANCH"
  restore_xboard_env
  ensure_xboard_builtin_redis_config
  ensure_xboard_port_mapping

  log "更新 Xboard 镜像并重建容器"
  run_compose "$XBOARD_DIR" pull
  run_compose "$XBOARD_DIR" up -d
  run_compose "$XBOARD_DIR" port xboard 7001

  install_menu_shortcut
  run_healthcheck

  log "更新完成（当前 Xboard 对外端口: $XBOARD_PORT）"
}

main "$@"
