#!/usr/bin/env bash
set -u
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
XBOARD_DIR="$SCRIPT_DIR/runtime/Xboard"
source "$SCRIPT_DIR/lib/common.sh"
FAILURES=0
CHECK_TMP=""

info() { printf '[xboard-healthcheck] %s\n' "$*"; }
fail() { printf '[xboard-healthcheck][FAIL] %s\n' "$*" >&2; FAILURES=$((FAILURES + 1)); }

check_url() {
  local url="$1" kind="$2" body="$3"
  curl -ksS --fail --location --max-redirs 3 --proto '=http,https' --proto-redir '=http,https' --max-time 8 "$url" -o "$body" 2>/dev/null || return 1
  python3 - "$body" "$kind" <<'PY'
import json
import sys
from pathlib import Path
body = Path(sys.argv[1]).read_text(errors='replace')
if sys.argv[2] == 'json':
    try:
        value = json.loads(body)
        valid = isinstance(value, dict) and isinstance(value.get('data'), (dict, list))
    except ValueError:
        valid = False
else:
    valid = '<html' in body.lower() and ('<script' in body.lower() or '<form' in body.lower())
sys.exit(0 if valid else 1)
PY
}

check_endpoints() {
  local admin_path api_path base successful=0
  admin_path="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["admin"])' "$CHECK_TMP/app.json")" || return 1
  api_path="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["api"])' "$CHECK_TMP/app.json")" || return 1
  [[ "$admin_path" =~ ^[A-Za-z0-9_-]+(/[A-Za-z0-9_-]+)*$ ]] || { fail '后台路径不合法，未发出请求。'; return 1; }
  [[ "$api_path" =~ ^[A-Za-z0-9_/-]+$ ]] || { fail '公开接口路径不合法。'; return 1; }
  for base in "http://127.0.0.1:$XBOARD_PORT" "https://127.0.0.1:$XBOARD_PORT"; do
    if check_url "$base/$admin_path" html "$CHECK_TMP/admin.html" && check_url "$base/$api_path" json "$CHECK_TMP/api.json"; then
      info "Xboard 后台页面与公开配置接口检查通过: $base/$admin_path"
      successful=1
      break
    fi
  done
  [ "$successful" = 1 ] || fail 'Xboard 后台或公开配置接口检查失败；400/404、空响应、错误页面不算就绪。'
  successful=0
  for base in "http://127.0.0.1:$NPM_ADMIN_PORT" "https://127.0.0.1:$NPM_ADMIN_PORT"; do
    if check_url "$base" html "$CHECK_TMP/npm.html"; then successful=1; break; fi
  done
  [ "$successful" = 1 ] || fail 'NPM 管理页面检查失败。'
}

check_application() {
  xb_compose "$XBOARD_DIR" exec -T --user www xboard php -r '
require "/www/vendor/autoload.php";
$app = require "/www/bootstrap/app.php";
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
if (config("database.default") !== "sqlite") { fwrite(STDERR, "Unexpected database driver\n"); exit(1); }
Illuminate\Support\Facades\DB::connection()->getPdo();
foreach (["v2_user", "v2_plugins"] as $table) {
    if (!Illuminate\Support\Facades\Schema::hasTable($table)) { fwrite(STDERR, "Required table missing\n"); exit(1); }
}
if (!App\Models\User::where("is_admin", 1)->where("banned", 0)->exists()) {
    fwrite(STDERR, "No active administrator; use the explicit password/account recovery workflow\n"); exit(1);
}
Illuminate\Support\Facades\Redis::connection()->ping();
$api = "";
foreach ($app["router"]->getRoutes() as $route) {
    if (in_array("GET", $route->methods(), true) && preg_match("~/guest/comm/config$~", $route->uri())) { $api = $route->uri(); break; }
}
if ($api === "") { fwrite(STDERR, "Public configuration route not found\n"); exit(1); }
$admin = trim((string)admin_setting("secure_path", admin_setting("frontend_admin_path", hash("crc32b", config("app.key")))), "/");
echo json_encode(["admin" => $admin, "api" => $api]);
' >"$CHECK_TMP/app.json"
}

main() {
  local command_name state
  FAILURES=0
  for command_name in python3 docker curl; do
    command -v "$command_name" >/dev/null 2>&1 || fail "缺少命令: $command_name"
  done
  [ "$FAILURES" = 0 ] || return 1
  NPM_ADMIN_PORT=81
  XBOARD_PORT=7001
  if [ -f "$SCRIPT_DIR/deploy.env" ]; then source "$SCRIPT_DIR/deploy.env"; fi
  [[ "$NPM_ADMIN_PORT" =~ ^[0-9]+$ && "$XBOARD_PORT" =~ ^[0-9]+$ ]] || { fail '端口配置不是数字。'; return 1; }
  info "项目目录: $SCRIPT_DIR"
  xb_require_runtime || { fail 'Docker 环境不可用。'; return 1; }
  python3 "$SCRIPT_DIR/lib/operations.py" check-running "$SCRIPT_DIR" || { fail '容器未就绪或资源归属不匹配。'; return 1; }
  state="$(python3 "$SCRIPT_DIR/lib/operations.py" install-state "$XBOARD_DIR")" || { fail '数据库或配置检查未通过；不会自动初始化。'; return 1; }
  [ "$state" = existing ] || { fail '数据库尚未初始化。'; return 1; }
  CHECK_TMP="$(mktemp -d)" || return 1
  trap 'rm -f "$CHECK_TMP/app.json" "$CHECK_TMP/admin.html" "$CHECK_TMP/api.json" "$CHECK_TMP/npm.html"; rmdir "$CHECK_TMP" 2>/dev/null || true' EXIT
  if check_application; then
    info '应用身份下的数据库、Redis、必要表和管理员检查通过。'
    check_endpoints || fail 'HTTP 检查执行失败。'
  else
    fail '应用检查失败；管理员缺失不会触发重建数据库或自动创建账号。'
  fi
  if [ "$FAILURES" -gt 0 ]; then
    info '检查未通过。请从菜单查看日志；本次未修改数据。'
    return 1
  fi
  info '健康检查通过（本机应用就绪；公网 DNS、安全组和证书还需另行确认）。'
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
