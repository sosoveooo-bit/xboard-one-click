#!/usr/bin/env bash

xb_lock() {
  local path="${1}.operation.lock"
  if [ "${XB_LOCK_PATH:-}" = "$path" ] && (true >&9) 2>/dev/null && flock -n 9; then
    return 0
  fi
  command -v flock >/dev/null 2>&1 || { echo '缺少 flock，请安装 util-linux。' >&2; return 1; }
  [ ! -L "$path" ] || { echo '操作锁路径是符号链接，已拒绝打开。' >&2; return 1; }
  [ ! -e "$path" ] || [ -f "$path" ] || { echo '操作锁不是普通文件。' >&2; return 1; }
  umask 077
  exec 9>>"$path"
  flock -n 9 || { echo '另一个安装、更新、备份或恢复任务正在运行，请等待它完成。' >&2; return 1; }
  XB_LOCK_PATH="$path"
  export XB_LOCK_PATH
}

xb_compose() {
  local dir="$1" file base=""
  shift
  local files=()
  for file in compose.yaml compose.yml docker-compose.yml docker-compose.yaml; do
    if [ -f "$dir/$file" ]; then base="$file"; break; fi
  done
  [ -n "$base" ] || { echo "未找到 Compose 文件: $dir" >&2; return 1; }
  files=(-f "$base")
  for file in compose.override.yaml compose.override.yml docker-compose.override.yml docker-compose.override.yaml; do
    if [ -f "$dir/$file" ]; then files+=(-f "$file"); break; fi
  done
  for file in .xb-volumes.json .xb-images.json; do
    [ ! -f "$dir/$file" ] || files+=(-f "$file")
  done
  (cd "$dir" && docker compose "${files[@]}" "$@")
}

xb_require_runtime() {
  command -v python3 >/dev/null 2>&1 || { echo '缺少 python3。' >&2; return 1; }
  docker compose version >/dev/null 2>&1 || { echo '需要 Docker Compose v2（docker compose）。' >&2; return 1; }
  docker info >/dev/null 2>&1 || { echo '无法连接 Docker daemon。' >&2; return 1; }
}

xb_wait_redis() {
  local dir="$1" attempt
  for attempt in $(seq 1 30); do
    if xb_compose "$dir" exec -T xboard redis-cli -s /data/redis.sock ping 2>/dev/null | grep -qx PONG; then return 0; fi
    sleep 2
  done
  echo 'Redis 未就绪；不会重新初始化数据库。' >&2
  return 1
}

xb_healthcheck() {
  local project="$1" attempt
  [ -f "$project/healthcheck.sh" ] || { echo '缺少 healthcheck.sh，不能确认服务已恢复。' >&2; return 1; }
  for attempt in 1 2 3 4 5 6; do
    if HEALTHCHECK_BRIEF=1 bash "$project/healthcheck.sh"; then return 0; fi
    [ "$attempt" = 6 ] || sleep 5
  done
  echo '服务就绪检查失败，操作未成功。' >&2
  return 1
}
