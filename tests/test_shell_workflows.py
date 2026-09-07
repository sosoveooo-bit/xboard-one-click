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


if __name__ == "__main__":
    unittest.main()
