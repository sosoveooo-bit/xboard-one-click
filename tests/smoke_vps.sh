#!/usr/bin/env bash
set -Eeuo pipefail
[[ "$(id -u)" = 0 && "${XB_DISPOSABLE_DOCKER_TEST:-}" = 1 ]] || { echo 'Disposable root Docker runner only.' >&2; exit 1; }
TEST_ROOT="$(mktemp -d /tmp/xb-vps-smoke-XXXXXX)"
TEST_PROJECT="$TEST_ROOT/xboard-one-click"
SOURCE_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
mkdir -p "$TEST_PROJECT"
cp -a "$SOURCE_ROOT/." "$TEST_PROJECT/"

cleanup() {
  local status=$?
  trap - EXIT
  if [ -f "$TEST_PROJECT/lib/common.sh" ]; then
    source "$TEST_PROJECT/lib/common.sh"
    for dir in "$TEST_PROJECT/runtime/Xboard" "$TEST_PROJECT/runtime/nginx-proxy-manager"; do
      if [ -f "$dir/compose.yaml" ]; then xb_compose "$dir" down || true; fi
    done
  fi
  echo "Disposable fixture retained for runner cleanup: $TEST_ROOT"
  exit "$status"
}
trap cleanup EXIT

SERVER_IP=127.0.0.1 NPM_HTTP_PORT=38080 NPM_HTTPS_PORT=38443 NPM_ADMIN_PORT=38181 XBOARD_PORT=37001 \
XBOARD_ADMIN_EMAIL=ci-admin@example.invalid AUTO_INSTALL_DEPS=0 AUTO_RELEASE_NPM_PORTS=0 ENABLE_FIREWALL_OPEN=0 \
bash "$TEST_PROJECT/install.sh" --non-interactive
bash "$TEST_PROJECT/healthcheck.sh"

python3 - "$TEST_PROJECT" <<'PY'
import sqlite3
import sys
from contextlib import closing
from pathlib import Path
db = Path(sys.argv[1]) / 'runtime/Xboard/.docker/.data/database.sqlite'
with closing(sqlite3.connect(db)) as connection, connection:
    connection.execute('CREATE TABLE xb_ci_sentinel (name TEXT PRIMARY KEY, value TEXT)')
    connection.execute("INSERT INTO xb_ci_sentinel VALUES ('node-config', 'must-survive-repair-and-rollback')")
PY
bash "$TEST_PROJECT/repair.sh"

DOCKER_BINARY="$(command -v docker)"
mkdir "$TEST_ROOT/bin"
cat >"$TEST_ROOT/bin/docker" <<EOF
#!/usr/bin/env bash
case " \$* " in
  *' exec -T xboard php artisan xboard:update '*) echo 'Injected post-update failure' >&2; exit 42 ;;
esac
exec "$DOCKER_BINARY" "\$@"
EOF
chmod +x "$TEST_ROOT/bin/docker"
if PATH="$TEST_ROOT/bin:$PATH" bash "$TEST_PROJECT/update.sh" 2>&1 | tee "$TEST_ROOT/update.log"; then
  echo 'Expected update failure was incorrectly reported as success.' >&2
  exit 1
else
  update_status=$?
fi
[ "$update_status" = 42 ] || { echo "Unexpected failure before injection: $update_status" >&2; exit 1; }
grep -q 'Injected post-update failure' "$TEST_ROOT/update.log"
test -f "$TEST_PROJECT/runtime/Xboard/.xb-volumes.json"
bash "$TEST_PROJECT/healthcheck.sh"
python3 - "$TEST_PROJECT" <<'PY'
import sqlite3
import sys
from contextlib import closing
from pathlib import Path
db = Path(sys.argv[1]) / 'runtime/Xboard/.docker/.data/database.sqlite'
with closing(sqlite3.connect(db)) as connection:
    assert connection.execute("SELECT value FROM xb_ci_sentinel WHERE name='node-config'").fetchone()[0] == 'must-survive-repair-and-rollback'
    assert connection.execute('SELECT COUNT(*) FROM v2_user WHERE is_admin=1').fetchone()[0] > 0
print('Real Xboard install, repair, forced update failure, and rollback passed.')
PY
