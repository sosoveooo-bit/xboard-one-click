#!/usr/bin/env bash
set -u

PROJECT_NAME="xboard-one-click-healthcheck"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="${SCRIPT_DIR}/runtime"
NPM_DIR="${WORK_DIR}/nginx-proxy-manager"
XBOARD_DIR="${WORK_DIR}/Xboard"
DEPLOY_ENV_FILE="${SCRIPT_DIR}/deploy.env"

DEFAULT_NPM_HTTP_PORT=80
DEFAULT_NPM_HTTPS_PORT=443
DEFAULT_NPM_ADMIN_PORT=81
DEFAULT_XBOARD_PORT=7001

NPM_HTTP_PORT="${NPM_HTTP_PORT:-}"
NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-}"
NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-}"
XBOARD_PORT="${XBOARD_PORT:-}"
XBOARD_ADMIN_PATH=""
COMPOSE_CMD=()
FAILURES=0

info() {
  printf '[%s] %s\n' "$PROJECT_NAME" "$*"
}

warn() {
  printf '[%s][WARN] %s\n' "$PROJECT_NAME" "$*" >&2
}

fail() {
  warn "$*"
  FAILURES=$((FAILURES + 1))
}

load_deploy_env() {
  if [ -f "$DEPLOY_ENV_FILE" ]; then
    set -a
    # shellcheck disable=SC1090
    . "$DEPLOY_ENV_FILE"
    set +a
  fi

  NPM_HTTP_PORT="${NPM_HTTP_PORT:-${DEFAULT_NPM_HTTP_PORT}}"
  NPM_HTTPS_PORT="${NPM_HTTPS_PORT:-${DEFAULT_NPM_HTTPS_PORT}}"
  NPM_ADMIN_PORT="${NPM_ADMIN_PORT:-${DEFAULT_NPM_ADMIN_PORT}}"
  XBOARD_PORT="${XBOARD_PORT:-${DEFAULT_XBOARD_PORT}}"
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

show_command_state() {
  local cmd="$1"
  if command -v "$cmd" >/dev/null 2>&1; then
    info "命令可用: $cmd ($(command -v "$cmd"))"
  else
    fail "缺少命令: $cmd"
  fi
}

show_port_listener() {
  local port="$1"
  local listeners=""

  if command -v ss >/dev/null 2>&1; then
    listeners="$(ss -H -ltnp 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" {print}' || true)"
  elif command -v netstat >/dev/null 2>&1; then
    listeners="$(netstat -ltnp 2>/dev/null | awk -v suffix=":${port}" '$4 ~ suffix "$" {print}' || true)"
  fi

  if [ -n "$listeners" ]; then
    info "端口 ${port} 监听中:"
    printf '%s\n' "$listeners"
  else
    warn "端口 ${port} 未监听"
  fi
}

check_compose_project() {
  local label="$1"
  local dir="$2"

  if [ ${#COMPOSE_CMD[@]} -eq 0 ]; then
    fail "无法检查 ${label}: 未找到 docker compose / docker-compose"
    return
  fi

  if ! has_compose_file "$dir"; then
    fail "无法检查 ${label}: 未找到 Compose 文件: $dir"
    return
  fi

  info "${label} Compose 状态"
  if ! run_compose "$dir" ps; then
    fail "${label} Compose 状态检查失败"
  fi
}

check_http_port() {
  local label="$1"
  local port="$2"
  local code
  local https_code

  if ! command -v curl >/dev/null 2>&1; then
    warn "未安装 curl，跳过 HTTP 检查: $label"
    return
  fi

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${port}" 2>/dev/null || true)"
  case "$code" in
    2*|3*)
      info "${label} 本机 HTTP 检查通过: http://127.0.0.1:${port} (${code})"
      ;;
    *)
      https_code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 8 "https://127.0.0.1:${port}" 2>/dev/null || true)"
      case "$https_code" in
        2*|3*)
          info "${label} 本机 HTTPS 检查通过: https://127.0.0.1:${port} (${https_code})，HTTP 返回 ${code:-no-response}"
          ;;
        *)
          fail "${label} 本机 HTTP/HTTPS 检查失败: http=${code:-no-response}, https=${https_code:-no-response}, port=${port}"
          ;;
      esac
      ;;
  esac
}

check_xboard_http_port() {
  local port="$1"
  local code
  local https_code

  if ! command -v curl >/dev/null 2>&1; then
    warn "未安装 curl，跳过 Xboard HTTP 检查"
    return
  fi

  code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${port}" 2>/dev/null || true)"
  case "$code" in
    2*|3*)
      info "Xboard 本机 HTTP 检查通过: http://127.0.0.1:${port} (${code})"
      return
      ;;
    4*)
      info "Xboard 端口有 HTTP 响应: http://127.0.0.1:${port} (${code})；根路径返回 4xx 不视为部署失败"
      return
      ;;
  esac

  https_code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 8 "https://127.0.0.1:${port}" 2>/dev/null || true)"
  case "$https_code" in
    2*|3*)
      info "Xboard 本机 HTTPS 检查通过: https://127.0.0.1:${port} (${https_code})，HTTP 返回 ${code:-no-response}"
      ;;
    4*)
      info "Xboard 端口有 HTTPS 响应: https://127.0.0.1:${port} (${https_code})；根路径返回 4xx 不视为部署失败"
      ;;
    *)
      fail "Xboard 本机 HTTP/HTTPS 检查失败: http=${code:-no-response}, https=${https_code:-no-response}, port=${port}"
      ;;
  esac
}

resolve_xboard_admin_path() {
  XBOARD_ADMIN_PATH=""

  if [ ${#COMPOSE_CMD[@]} -eq 0 ] || ! has_compose_file "$XBOARD_DIR"; then
    return 1
  fi

  XBOARD_ADMIN_PATH="$(run_compose "$XBOARD_DIR" exec -T xboard php -r '
require "/www/vendor/autoload.php";
$app = require "/www/bootstrap/app.php";
$kernel = $app->make(Illuminate\Contracts\Console\Kernel::class);
$kernel->bootstrap();
echo admin_setting("secure_path", admin_setting("frontend_admin_path", hash("crc32b", config("app.key"))));
' 2>/dev/null | tr -d '\r' | awk 'NF {value=$0} END {print value}' || true)"

  case "$XBOARD_ADMIN_PATH" in
    *[!A-Za-z0-9_-]*|"")
      XBOARD_ADMIN_PATH=""
      return 1
      ;;
  esac

  return 0
}

check_xboard_admin_path() {
  local port="$1"
  local http_code
  local https_code

  if ! command -v curl >/dev/null 2>&1; then
    warn "未安装 curl，跳过 Xboard 管理面板路径检查"
    return
  fi

  if ! resolve_xboard_admin_path; then
    fail "无法从 Xboard 运行环境解析管理面板路径，请执行: cd $SCRIPT_DIR && ./repair.sh"
    return
  fi

  http_code="$(curl -sS -o /dev/null -w '%{http_code}' --max-time 8 "http://127.0.0.1:${port}/${XBOARD_ADMIN_PATH}" 2>/dev/null || true)"
  case "$http_code" in
    2*|3*)
      info "Xboard 管理面板 HTTP 检查通过: http://127.0.0.1:${port}/${XBOARD_ADMIN_PATH} (${http_code})"
      return
      ;;
  esac

  https_code="$(curl -ksS -o /dev/null -w '%{http_code}' --max-time 8 "https://127.0.0.1:${port}/${XBOARD_ADMIN_PATH}" 2>/dev/null || true)"
  case "$https_code" in
    2*|3*)
      info "Xboard 管理面板 HTTPS 检查通过: https://127.0.0.1:${port}/${XBOARD_ADMIN_PATH} (${https_code})；HTTP 返回 ${http_code:-no-response}"
      ;;
    *)
      if [ "$http_code" = "404" ] || [ "$https_code" = "404" ]; then
        fail "Xboard 管理面板路径返回 404: /${XBOARD_ADMIN_PATH}。请执行菜单 19 或运行: cd $SCRIPT_DIR && ./repair.sh"
        return
      fi
      fail "Xboard 管理面板路径检查失败: path=/${XBOARD_ADMIN_PATH}, http=${http_code:-no-response}, https=${https_code:-no-response}"
      ;;
  esac
}

check_xboard_env() {
  local env_file="$XBOARD_DIR/.env"
  local db_connection=""
  local db_database=""
  local redis_host=""
  local redis_port=""

  if [ ! -s "$env_file" ]; then
    fail "Xboard .env 不存在或为空: $env_file"
    return
  fi

  info "Xboard .env 存在且非空"
  grep -q '^APP_KEY=.' "$env_file" || fail "Xboard .env 缺少 APP_KEY 或 APP_KEY 为空"
  grep -q '^DB_CONNECTION=.' "$env_file" || fail "Xboard .env 缺少 DB_CONNECTION"
  grep -q '^DB_DATABASE=.' "$env_file" || fail "Xboard .env 缺少 DB_DATABASE"
  grep -q '^REDIS_HOST=.' "$env_file" || fail "Xboard .env 缺少 REDIS_HOST"

  db_connection="$(awk -F= '$1=="DB_CONNECTION" {print $2; exit}' "$env_file")"
  db_database="$(awk -F= '$1=="DB_DATABASE" {print $2; exit}' "$env_file")"
  if [ "$db_connection" != "sqlite" ] || [ "$db_database" != ".docker/.data/database.sqlite" ]; then
    fail "Xboard SQLite 配置应为 DB_CONNECTION=sqlite 且 DB_DATABASE=.docker/.data/database.sqlite，当前为 DB_CONNECTION=${db_connection:-空}, DB_DATABASE=${db_database:-空}"
  fi

  redis_host="$(awk -F= '$1=="REDIS_HOST" {print $2; exit}' "$env_file")"
  redis_port="$(awk -F= '$1=="REDIS_PORT" {print $2; exit}' "$env_file")"
  if [ "$redis_host" != "/data/redis.sock" ] || [ "$redis_port" != "0" ]; then
    fail "Xboard 内置 Redis 配置应为 REDIS_HOST=/data/redis.sock 且 REDIS_PORT=0，当前为 REDIS_HOST=${redis_host:-空}, REDIS_PORT=${redis_port:-空}"
  fi
}

check_xboard_database_tables() {
  if [ ${#COMPOSE_CMD[@]} -eq 0 ] || ! has_compose_file "$XBOARD_DIR"; then
    return
  fi

  if run_compose "$XBOARD_DIR" exec -T xboard php -r '
$db = "/www/.docker/.data/database.sqlite";
if (!is_file($db) || filesize($db) === 0) {
    exit(1);
}
try {
    $pdo = new PDO("sqlite:" . $db);
    $stmt = $pdo->query("SELECT name FROM sqlite_master WHERE type = '\''table'\'' AND name = '\''v2_plugins'\''");
    exit($stmt && $stmt->fetchColumn() ? 0 : 2);
} catch (Throwable $e) {
    exit(3);
}
' >/dev/null 2>&1; then
    info "Xboard SQLite 必要表检查通过"
  else
    fail "Xboard SQLite 缺少必要表或数据库损坏，请执行: cd $SCRIPT_DIR && ./repair.sh"
  fi
}

show_recent_logs() {
  local label="$1"
  local dir="$2"
  local service="$3"

  [ ${#COMPOSE_CMD[@]} -gt 0 ] || return
  has_compose_file "$dir" || return

  info "${label} 最近日志"
  run_compose "$dir" logs --tail=80 "$service" || true
}

main() {
  load_deploy_env
  init_compose

  info "项目目录: $SCRIPT_DIR"
  info "NPM 端口: HTTP=${NPM_HTTP_PORT}, HTTPS=${NPM_HTTPS_PORT}, 管理=${NPM_ADMIN_PORT}"
  info "Xboard 端口: ${XBOARD_PORT}"

  show_command_state docker
  show_command_state git
  show_command_state python3
  command -v curl >/dev/null 2>&1 && show_command_state curl || warn "未安装 curl，HTTP 检查会跳过"

  if command -v docker >/dev/null 2>&1; then
    docker info >/dev/null 2>&1 || fail "当前用户无法访问 Docker daemon"
  fi

  check_xboard_env
  check_compose_project "NPM" "$NPM_DIR"
  check_compose_project "Xboard" "$XBOARD_DIR"
  check_xboard_database_tables

  show_port_listener "$NPM_HTTP_PORT"
  show_port_listener "$NPM_HTTPS_PORT"
  show_port_listener "$NPM_ADMIN_PORT"
  show_port_listener "$XBOARD_PORT"

  check_http_port "NPM 管理后台" "$NPM_ADMIN_PORT"
  check_xboard_http_port "$XBOARD_PORT"
  check_xboard_admin_path "$XBOARD_PORT"

  if [ "$FAILURES" -gt 0 ]; then
    warn "健康检查发现 ${FAILURES} 个问题，下面输出最近日志辅助排查。"
    show_recent_logs "NPM" "$NPM_DIR" app
    show_recent_logs "Xboard" "$XBOARD_DIR" xboard
    exit 1
  fi

  info "健康检查通过"
}

main "$@"
