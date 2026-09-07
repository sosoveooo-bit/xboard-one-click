#!/usr/bin/env bash
set -euo pipefail

REPO_URL="${REPO_URL:-https://github.com/sosoveooo-bit/xboard-one-click.git}"
BRANCH="${BRANCH:-codex/fix-xboard-update-env}"
INSTALL_DIR="${INSTALL_DIR:-/root/xboard-one-click}"
SCRIPT_ONLY=0
SUDO_CMD=()

log() {
  printf '[xboard-one-click-bootstrap] %s\n' "$*"
}

die() {
  printf '[xboard-one-click-bootstrap][WARN] %s\n' "$*" >&2
  exit 1
}

init_privilege_helper() {
  if [ "$(id -u)" -eq 0 ]; then
    SUDO_CMD=()
    return
  fi

  if command -v sudo >/dev/null 2>&1; then
    SUDO_CMD=(sudo)
    return
  fi

  die "请使用 root 运行，或先安装 sudo。"
}

run_privileged() {
  "${SUDO_CMD[@]}" "$@"
}

ensure_git() {
  command -v git >/dev/null 2>&1 && return 0

  if command -v apt-get >/dev/null 2>&1; then
    log "未检测到 git，尝试自动安装"
    run_privileged apt-get update
    run_privileged apt-get install -y git
    command -v git >/dev/null 2>&1 && return 0
  fi

  die "缺少 git，请先手动安装后重试。"
}

prepare_repo() {
  [ "$(basename "$INSTALL_DIR")" = xboard-one-click ] || die "安装目录名称必须为 xboard-one-click。"
  [ ! -L "$INSTALL_DIR" ] || die "安装目录不能是符号链接。"
  if [ -d "$INSTALL_DIR/.git" ]; then
    log "检测到已有目录，更新到最新代码: $INSTALL_DIR"
    run_privileged git -c core.filemode=false -C "$INSTALL_DIR" diff --quiet || die "本地脚本存在内容修改，已停止更新以保护修改；请先保存或提交这些修改。"
    run_privileged git -C "$INSTALL_DIR" diff --cached --quiet || die "暂存区有修改，已停止更新。"
    run_privileged git -C "$INSTALL_DIR" fetch "$REPO_URL" "$BRANCH"
    run_privileged git -C "$INSTALL_DIR" update-ref refs/xboard-one-click/previous HEAD
    run_privileged git -c core.filemode=false -C "$INSTALL_DIR" checkout --detach FETCH_HEAD
    if run_privileged git -C "$INSTALL_DIR" remote get-url origin >/dev/null 2>&1; then
      run_privileged git -C "$INSTALL_DIR" remote set-url origin "$REPO_URL"
    else
      run_privileged git -C "$INSTALL_DIR" remote add origin "$REPO_URL"
    fi
    return 0
  fi

  if [ -e "$INSTALL_DIR" ] && [ ! -d "$INSTALL_DIR/.git" ]; then
    die "目标目录已存在但不是 git 仓库: $INSTALL_DIR"
  fi

  log "克隆项目到: $INSTALL_DIR"
  run_privileged mkdir -p "$(dirname "$INSTALL_DIR")"
  run_privileged git clone --depth 1 -b "$BRANCH" "$REPO_URL" "$INSTALL_DIR"
}

main() {
  case "${1:-}" in
    --update-scripts) SCRIPT_ONLY=1 ;;
    "") ;;
    *) die "用法: bootstrap.sh [--update-scripts]" ;;
  esac
  init_privilege_helper
  ensure_git
  if [ "$(id -u)" -ne 0 ]; then
    die "请先执行 sudo -i，再运行安装/更新命令。"
  fi
  command -v flock >/dev/null 2>&1 || die "缺少 flock，请安装 util-linux。"
  [ "$(basename "$INSTALL_DIR")" = xboard-one-click ] || die "安装目录名称必须为 xboard-one-click。"
  case "$INSTALL_DIR" in /*) ;; *) die "INSTALL_DIR 必须是绝对路径。" ;; esac
  [ "$(realpath -m "$INSTALL_DIR")" = "$INSTALL_DIR" ] || die "安装目录不能包含符号链接、尾部斜杠或相对路径段。"
  [ ! -L "${INSTALL_DIR}.operation.lock" ] || die "操作锁不能是符号链接。"
  mkdir -p "$(dirname "$INSTALL_DIR")"
  if [ "${XB_LOCK_PATH:-}" != "${INSTALL_DIR}.operation.lock" ] || ! (true >&9) 2>/dev/null; then
    umask 077
    exec 9>>"${INSTALL_DIR}.operation.lock"
    flock -n 9 || die "另一个项目操作正在运行。"
    XB_LOCK_PATH="${INSTALL_DIR}.operation.lock"
    export XB_LOCK_PATH
  fi
  prepare_repo

  log "当前管理脚本提交: $(git -C "$INSTALL_DIR" rev-parse --short HEAD)"
  if [ "$SCRIPT_ONLY" = 1 ]; then
    log "仅管理脚本已更新；未执行安装、更新镜像、重置密码或修改运行数据。"
    return 0
  fi
  if [ -d "$INSTALL_DIR/runtime" ]; then
    log "检测到已有部署目录，进入菜单；不会自动重新安装。"
    flock -u 9
    exec 9>&-
    unset XB_LOCK_PATH
    exec bash "$INSTALL_DIR/menu.sh"
  fi
  log "开始执行交互式安装"
  exec bash "$INSTALL_DIR/install.sh" --interactive
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then main "$@"; fi
