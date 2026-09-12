import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[1]
BASH = str(Path("C:/Program Files/Git/bin/bash.exe")) if os.name == "nt" else shutil.which("bash")


@unittest.skipUnless(BASH and Path(BASH).is_file(), "Bash unavailable")
class ShellWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="xb-shell-test-")
        self.addCleanup(self.temporary.cleanup)
        self.project = Path(self.temporary.name).resolve() / "xboard-one-click"
        self.project.mkdir()
        (self.project / "lib").mkdir()
        for path in ROOT.glob("*.sh"):
            shutil.copy2(path, self.project / path.name)
        shutil.copy2(ROOT / "lib/common.sh", self.project / "lib/common.sh")

    def bash(self, code, **environment):
        env = {**os.environ, "PYTHONUTF8": "1", **environment}
        return subprocess.run([BASH, "--noprofile", "--norc", "-s", "--", self.project.as_posix()], input=code,
                              text=True, encoding="utf-8", errors="replace", stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                              cwd=ROOT, env=env, timeout=20)

    def test_all_shell_files_have_valid_syntax(self):
        for script in [*ROOT.glob("*.sh"), *ROOT.glob("lib/*.sh"), *ROOT.glob("tests/*.sh")]:
            with self.subTest(script=script.name):
                result = subprocess.run([BASH, "-n", script.as_posix()], capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)

    def test_existing_install_never_calls_initialization_or_resets_password(self):
        result = self.bash('''
source "$1/install.sh"
INSTALL_STATE=existing
XBOARD_ADMIN_PASSWORD=''
clone_or_update_xboard() { echo UNEXPECTED_CLONE; return 1; }
prepare_xboard_env() { echo UNEXPECTED_ENV_WRITE; return 1; }
set_xboard_admin_password() { echo UNEXPECTED_PASSWORD_RESET; return 1; }
xboard_sqlite_has_required_tables() { return 1; }
ensure_xboard_port_mapping() { :; }
python3() { :; }
run_compose() { printf 'COMMAND %s\\n' "$*"; }
wait_for_xboard_redis() { :; }
refresh_xboard_runtime() { :; }
install_xboard
''')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("UNEXPECTED_", result.stdout)
        self.assertNotIn("php artisan xboard:install", result.stdout)

    def test_shared_healthcheck_failure_is_nonzero(self):
        result = self.bash('''
source "$1/lib/common.sh"
bash() { return 42; }
sleep() { :; }
xb_healthcheck "$1"
''')
        self.assertNotEqual(result.returncode, 0)

    def test_stale_password_is_never_displayed_as_current(self):
        secret = "stale-synthetic-password-123"
        (self.project / "deploy.env").write_text("XBOARD_ADMIN_EMAIL=admin@example.test\nXBOARD_ADMIN_PASSWORD=" + secret + "\n")
        result = self.bash('''
source "$1/password.sh"
xb_require_runtime() { :; }
xb_lock() { :; }
password_operation() { return 1; }
main --show
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn(secret, result.stdout + result.stderr)

    def test_missing_saved_password_does_not_trigger_reset(self):
        result = self.bash('''
source "$1/password.sh"
xb_require_runtime() { :; }
xb_lock() { :; }
password_operation() { echo UNEXPECTED_PASSWORD_OPERATION; return 1; }
main --show
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("UNEXPECTED_", result.stdout)

    def test_noninteractive_password_reset_needs_confirmation(self):
        result = self.bash('''
source "$1/password.sh"
xb_require_runtime() { :; }
xb_lock() { :; }
password_operation() { echo UNEXPECTED_PASSWORD_OPERATION; }
unset PASSWORD_CONFIRM
main --reset admin@example.test
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("UNEXPECTED_", result.stdout)

    def test_noninteractive_uninstall_needs_its_own_confirmation(self):
        result = self.bash('''
source "$1/uninstall.sh"
xb_require_runtime() { :; }
xb_lock() { :; }
python3() { echo UNEXPECTED_DELETE; }
PURGE_ALL=1
unset UNINSTALL_CONFIRM
main
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("UNEXPECTED_", result.stdout)

    def test_deleting_backups_requires_a_second_confirmation(self):
        result = self.bash('''
source "$1/uninstall.sh"
xb_require_runtime() { :; }
xb_lock() { :; }
python3() { echo UNEXPECTED_DELETE; }
PURGE_ALL=1
UNINSTALL_CONFIRM=DELETE
PURGE_BACKUPS=1
unset PURGE_BACKUPS_CONFIRM
main
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("UNEXPECTED_", result.stdout)

    def test_restore_failure_does_not_print_success(self):
        result = self.bash('''
source "$1/restore.sh"
xb_require_runtime() { :; }
xb_lock() { :; }
python3() { return 42; }
RESTORE_OVERWRITE=1
main /not-used-fixture.tar.gz
''')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertNotIn("恢复成功", result.stdout)

    def test_update_failure_keeps_nonzero_status_even_if_rollback_succeeds(self):
        result = self.bash('''
source "$1/update.sh"
PRE_UPDATE_BACKUP_FILE=/synthetic-backup.tar.gz
BASELINE_FILE=''
bash() { echo ROLLBACK_CALLED; return 0; }
finish_update 42
''')
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("ROLLBACK_CALLED", result.stdout)

    def test_bootstrap_defaults_to_user_fork_and_protects_modified_scripts(self):
        (self.project / ".git").mkdir()
        result = self.bash('''
source "$1/bootstrap.sh"
INSTALL_DIR="$1"
run_privileged() { return 1; }
printf '%s\\n' "$REPO_URL"
prepare_repo
''')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("sosoveooo-bit/xboard-one-click", result.stdout)
        self.assertNotIn("slobys", result.stdout)

    def update_fixture(self, argument="", **environment):
        (self.project / "snapshot.tar.gz").write_bytes(b"existing-backup-must-survive")
        (self.project / "deploy.env").write_text("PRE_UPDATE_BACKUP=1\nAUTO_ROLLBACK_ON_UPDATE_FAIL=1\n")
        return self.bash('''
source "$1/update.sh"
xb_require_runtime() { :; }
xb_lock() { :; }
checks=0
xb_healthcheck() {
  checks=$((checks + 1))
  echo "HEALTH $checks" >&2
  if [ "${MOCK_HEALTH_FAIL:-0}" = "$checks" ]; then return 77; fi
}
xb_wait_redis() { :; }
python3() {
  echo "PYTHON $2" >&2
  case "$2" in
    install-state) echo existing ;;
    sqlite-check) echo '{}' ;;
    check-counts) return "${MOCK_COUNTS_STATUS:-0}" ;;
  esac
}
xb_compose() {
  echo "COMPOSE $*" >&2
  case " $* " in
    *' pull '*) return "${MOCK_PULL_STATUS:-0}" ;;
    *' php artisan xboard:update '*) return "${MOCK_MIGRATION_STATUS:-0}" ;;
  esac
}
bash() {
  case "$1" in
    */backup.sh)
      echo BACKUP_CALLED >&2
      [ "${MOCK_BACKUP_STATUS:-0}" = 0 ] || return "$MOCK_BACKUP_STATUS"
      echo "$SCRIPT_DIR/snapshot.tar.gz"
      ;;
    */restore.sh) echo RESTORE_CALLED >&2 ;;
    *) echo UNEXPECTED_SCRIPT >&2; return 99 ;;
  esac
}
if [ -n "${UPDATE_ARGUMENT:-}" ]; then main "$UPDATE_ARGUMENT"; else main; fi
''', UPDATE_ARGUMENT=argument, **environment)

    def test_direct_update_ignores_legacy_backup_setting_and_never_calls_backup(self):
        result = self.update_fixture(MOCK_BACKUP_STATUS="66")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertNotIn("BACKUP_CALLED", result.stderr)
        self.assertNotIn("RESTORE_CALLED", result.stderr)
        self.assertIn("php artisan xboard:update", result.stderr)
        self.assertIn("HEALTH 2", result.stderr)
        self.assertIn("PYTHON check-counts", result.stderr)
        self.assertIn("本次未创建备份", result.stdout)
        self.assertEqual((self.project / "snapshot.tar.gz").read_bytes(), b"existing-backup-must-survive")

    def test_direct_update_failure_never_restores_an_old_backup(self):
        for settings in ({"MOCK_PULL_STATUS": "41"}, {"MOCK_MIGRATION_STATUS": "42"},
                         {"MOCK_HEALTH_FAIL": "2"}, {"MOCK_COUNTS_STATUS": "43"}):
            with self.subTest(settings=settings):
                result = self.update_fixture(**settings)
                self.assertNotEqual(result.returncode, 0)
                self.assertNotIn("BACKUP_CALLED", result.stderr)
                self.assertNotIn("RESTORE_CALLED", result.stderr)
                self.assertIn("未执行自动回滚", result.stderr)
                self.assertNotIn("更新及数据检查通过", result.stdout)

    def test_explicit_backup_mode_still_supports_rollback(self):
        result = self.update_fixture("--with-backup", MOCK_MIGRATION_STATUS="42")
        self.assertEqual(result.returncode, 42, result.stderr)
        self.assertIn("BACKUP_CALLED", result.stderr)
        self.assertIn("RESTORE_CALLED", result.stderr)

    def test_explicit_backup_failure_never_falls_back_to_direct_update(self):
        result = self.update_fixture("--with-backup", MOCK_BACKUP_STATUS="66")
        self.assertEqual(result.returncode, 66, result.stderr)
        self.assertIn("BACKUP_CALLED", result.stderr)
        self.assertNotIn("COMPOSE", result.stderr)
        self.assertNotIn("RESTORE_CALLED", result.stderr)

    def test_preflight_failure_blocks_direct_update(self):
        result = self.update_fixture(MOCK_HEALTH_FAIL="1")
        self.assertEqual(result.returncode, 77, result.stderr)
        self.assertNotIn("COMPOSE", result.stderr)
        self.assertNotIn("BACKUP_CALLED", result.stderr)

    def test_invalid_update_flag_is_rejected(self):
        result = self.update_fixture("--with-bakcup")
        self.assertNotEqual(result.returncode, 0)
        self.assertNotIn("COMPOSE", result.stderr)
        self.assertNotIn("BACKUP_CALLED", result.stderr)


if __name__ == "__main__":
    unittest.main()
