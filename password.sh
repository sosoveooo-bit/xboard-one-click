#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/lib/common.sh"

password_operation() {
  export XBOARD_PASSWORD_ACTION XBOARD_ADMIN_EMAIL XBOARD_ADMIN_PASSWORD
  xb_compose "$SCRIPT_DIR/runtime/Xboard" exec -T --user www \
    -e XBOARD_PASSWORD_ACTION -e XBOARD_ADMIN_EMAIL -e XBOARD_ADMIN_PASSWORD xboard php <<'PHP'
<?php
require '/www/vendor/autoload.php';
$app = require '/www/bootstrap/app.php';
$app->make(Illuminate\Contracts\Console\Kernel::class)->bootstrap();
$action = getenv('XBOARD_PASSWORD_ACTION');
$email = strtolower(trim((string)getenv('XBOARD_ADMIN_EMAIL')));
$password = (string)getenv('XBOARD_ADMIN_PASSWORD');
if ($action === 'list') {
    foreach (App\Models\User::where('is_admin', 1)->get(['email', 'banned']) as $admin) {
        echo $admin->email . ($admin->banned ? ' [banned]' : '') . PHP_EOL;
    }
    exit(0);
}
if (!filter_var($email, FILTER_VALIDATE_EMAIL)) { fwrite(STDERR, "Invalid email\n"); exit(1); }
$user = App\Models\User::byEmail($email)->first();
if ($action === 'verify') {
    exit($user && $user->is_admin && !$user->banned && password_verify($password, $user->password) ? 0 : 1);
}
if (strlen($password) < 12) { fwrite(STDERR, "Password must be at least 12 characters\n"); exit(1); }
if ($action === 'create') {
    if ($user || App\Models\User::where('is_admin', 1)->exists()) {
        fwrite(STDERR, "Account/admin already exists; use explicit reset for an existing administrator\n"); exit(1);
    }
    $user = new App\Models\User();
    $user->email = $email;
    $user->uuid = App\Utils\Helper::guid(true);
    $user->token = App\Utils\Helper::guid();
    $user->is_admin = 1;
} elseif ($action !== 'reset' || !$user || !$user->is_admin || $user->banned) {
    fwrite(STDERR, "Active administrator email not found; no account was created or promoted\n"); exit(1);
}
$user->password = password_hash($password, PASSWORD_DEFAULT);
$user->password_algo = null;
$user->password_salt = null;
$user->save();
echo "Administrator credential changed: " . $email . PHP_EOL;
PHP
}

main() {
  xb_require_runtime
  xb_lock "$SCRIPT_DIR"
  XBOARD_ADMIN_EMAIL=""
  XBOARD_ADMIN_PASSWORD=""
  [ ! -f "$SCRIPT_DIR/deploy.env" ] || source "$SCRIPT_DIR/deploy.env"
  local action="${1:---menu}" email="${2:-}" choice answer
  if [ "$action" = --menu ]; then
    printf '%s\n' '1. 列出实际管理员邮箱' '2. 验证并展示已保存密码' '3. 重置已有管理员密码' '4. 无管理员时创建账号（需单独确认）' '0. 返回'
    read -r -p '请输入选项: ' choice
    case "$choice" in 1) action=--list ;; 2) action=--show ;; 3) action=--reset ;; 4) action=--create-admin ;; *) return 0 ;; esac
  fi
  case "$action" in
    --list)
      XBOARD_PASSWORD_ACTION=list
      password_operation
      ;;
    --show)
      [ -n "$XBOARD_ADMIN_PASSWORD" ] || { echo '没有保存密码，原密码无法反查；可从独立重置入口设置新密码。'; return 1; }
      XBOARD_PASSWORD_ACTION=verify
      password_operation || { echo '已保存密码已过期或账号不匹配，不会展示为有效密码，也不会自动重置。'; return 1; }
      printf '管理员邮箱: %s\n当前有效密码: %s\n' "$XBOARD_ADMIN_EMAIL" "$XBOARD_ADMIN_PASSWORD"
      ;;
    --reset|--create-admin)
      if [ -z "$email" ]; then
        XBOARD_PASSWORD_ACTION=list
        password_operation
        read -r -p '请输入要操作的管理员邮箱: ' email
      fi
      if [ "${PASSWORD_CONFIRM:-}" != CHANGE_PASSWORD ]; then
        [ -t 0 ] || { echo '非交互重置需 PASSWORD_CONFIRM=CHANGE_PASSWORD。' >&2; return 1; }
        read -r -p "确认修改 $email 的凭据？输入 CHANGE_PASSWORD: " answer
        [ "$answer" = CHANGE_PASSWORD ] || return 1
      fi
      if [ "$action" = --create-admin ]; then
        if [ "${CREATE_ADMIN_CONFIRM:-}" != CREATE_ADMIN ]; then
          [ -t 0 ] || { echo '创建管理员还需 CREATE_ADMIN_CONFIRM=CREATE_ADMIN。' >&2; return 1; }
          read -r -p '此操作仅限数据库中完全没有管理员的情况，输入 CREATE_ADMIN: ' answer
          [ "$answer" = CREATE_ADMIN ] || return 1
        fi
        XBOARD_PASSWORD_ACTION=create
      else
        XBOARD_PASSWORD_ACTION=reset
      fi
      XBOARD_ADMIN_EMAIL="$email"
      XBOARD_ADMIN_PASSWORD="$(python3 -c 'import secrets; print(secrets.token_urlsafe(24))')"
      password_operation
      python3 "$SCRIPT_DIR/lib/operations.py" save-credentials "$SCRIPT_DIR/deploy.env"
      echo '新密码已随机生成并保存，文件权限为 600。请使用“验证并展示已保存密码”查看。'
      ;;
    *) echo '用法: bash password.sh [--list|--show|--reset 邮箱|--create-admin 邮箱]' >&2; return 1 ;;
  esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
