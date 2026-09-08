import hashlib
import copy
from contextlib import closing
import importlib.util
import io
import json
import os
from pathlib import Path
import sqlite3
import tarfile
import tempfile
import unittest
from unittest.mock import patch


ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("operations", ROOT / "lib/operations.py")
ops = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ops)
IMAGE_ID = "sha256:" + "a" * 64
IMAGE_REF = ops.local_image_ref(IMAGE_ID)


class WorkspaceCase(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="xb-safety-test-")
        self.addCleanup(self.temporary.cleanup)
        self.addCleanup(os.chdir, Path.cwd())
        shortcut = patch.object(ops, "install_shortcut")
        shortcut.start()
        self.addCleanup(shortcut.stop)
        self.parent = Path(self.temporary.name).resolve()
        self.project = self.parent / "xboard-one-click"
        self.project.mkdir()
        for filename in ("install.sh", "menu.sh", "healthcheck.sh"):
            (self.project / filename).write_text("#!/bin/bash\nexit 0\n")
        for relative in ops.STACKS:
            directory = self.project / relative
            directory.mkdir(parents=True)
            (directory / "compose.yaml").write_text('{"services":{"app":{"image":"candidate:latest"}}}')
        self.xboard = self.project / "runtime/Xboard"
        self.database = self.xboard / ".docker/.data/database.sqlite"
        self.database.parent.mkdir(parents=True)
        self.make_database(self.database)
        (self.xboard / ".env").write_text("APP_KEY=base64:original-key\nAPP_URL=https://panel.example\nINSTALLED=true\nDB_CONNECTION=sqlite\nDB_DATABASE=.docker/.data/database.sqlite\nREDIS_HOST=/data/redis.sock\n")

    def make_database(self, path, user="existing@example.test"):
        with closing(sqlite3.connect(path)) as connection, connection:
            connection.executescript("CREATE TABLE v2_user(id INTEGER PRIMARY KEY,email TEXT); CREATE TABLE v2_server_vmess(id INTEGER PRIMARY KEY,host TEXT); CREATE TABLE v2_settings(id INTEGER PRIMARY KEY,value TEXT);")
            connection.execute("INSERT INTO v2_user VALUES(1,?)", (user,))
            connection.execute("INSERT INTO v2_server_vmess VALUES(1,'node.example')")
            connection.execute("INSERT INTO v2_settings VALUES(1,'keep-original-config')")

    def stacks(self, volume=False):
        result = []
        for index, relative in enumerate(ops.STACKS):
            name = "fixture-" + str(index)
            service = "app" if index == 0 else "xboard"
            mounts = [{"Type": "bind", "Source": str(self.project), "Destination": "/app"}]
            if volume and index == 1:
                mounts.append({"Type": "volume", "Name": "original-redis", "Destination": "/data", "RW": True})
            container = {"Id": str(index) * 64, "Image": IMAGE_ID, "State": {"Running": True}, "Mounts": mounts,
                         "Config": {"Labels": {"com.docker.compose.project": name, "com.docker.compose.service": service,
                                                "com.docker.compose.project.working_dir": str(self.project / relative),
                                                "com.docker.compose.project.config_files": str(self.project / relative / "compose.yaml")}}}
            result.append({"directory": relative, "name": name, "services": {service: container}, "config": {"name": name, "services": {service: {}}}})
        return result

    def archive(self, volume=False):
        path = self.parent / "fixture.tar.gz"
        payloads = {"images.tar": b"saved-image-placeholder"}
        if volume:
            payloads["volume-0.tar"] = b"saved-redis-placeholder"
        manifest = {"version": 2, "payloads": {name: hashlib.sha256(data).hexdigest() for name, data in payloads.items()}, "stacks": []}
        for index, relative in enumerate(ops.STACKS):
            service = {"id": IMAGE_ID, "image": IMAGE_REF, "volumes": []}
            if volume and index == 1:
                service["volumes"].append({"file": "volume-0.tar", "target": "/data", "read_only": False})
            manifest["stacks"].append({"directory": relative, "services": {"app" if index == 0 else "xboard": service}})
        payloads["manifest.json"] = json.dumps(manifest).encode()
        with tarfile.open(path, "w:gz") as handle:
            handle.add(self.project, arcname="xboard-one-click")
            for name, data in payloads.items():
                member = tarfile.TarInfo("xboard-one-click/.backup/" + name)
                member.size = len(data)
                handle.addfile(member, io.BytesIO(data))
        ops.atomic_text(str(path) + ".sha256", ops.hash_file(path) + "  /old/server/path.tar.gz\n")
        return path


class DatabaseTests(WorkspaceCase):
    def test_missing_plugin_table_does_not_turn_existing_database_into_fresh_install(self):
        before = self.database.read_bytes()
        self.assertEqual(ops.install_state(self.xboard), "existing")
        self.assertEqual(self.database.read_bytes(), before)

    def test_false_install_flag_with_real_data_is_existing(self):
        ops.set_env(self.xboard / ".env", {"INSTALLED": "false"})
        self.assertEqual(ops.install_state(self.xboard), "existing")

    def test_missing_env_with_existing_data_is_blocked(self):
        before = self.database.read_bytes()
        (self.xboard / ".env").unlink()
        with self.assertRaisesRegex(ops.OperationError, "APP_KEY"):
            ops.install_state(self.xboard)
        self.assertEqual(before, self.database.read_bytes())

    def test_corrupt_database_is_not_moved_or_replaced(self):
        self.database.write_bytes(b"damaged fixture, preserve me")
        with self.assertRaises(ops.OperationError):
            ops.install_state(self.xboard)
        self.assertEqual(self.database.read_bytes(), b"damaged fixture, preserve me")

    def test_archived_database_is_evidence_of_an_existing_install(self):
        self.database.rename(self.database.with_suffix(".sqlite.broken-20260701"))
        (self.xboard / ".env").unlink()
        with self.assertRaises(ops.OperationError):
            ops.install_state(self.xboard)

    def test_missing_db_probe_does_not_create_a_file(self):
        path = self.parent / "absent.sqlite"
        with self.assertRaises(ops.OperationError):
            ops.sqlite_report(path)
        self.assertFalse(path.exists())

    def test_mysql_is_never_silently_changed_to_sqlite(self):
        ops.set_env(self.xboard / ".env", {"DB_CONNECTION": "mysql", "INSTALLED": "false"})
        self.database.unlink()
        with self.assertRaisesRegex(ops.OperationError, "Non-SQLite"):
            ops.install_state(self.xboard)

    def test_normalization_preserves_key_url_and_all_business_rows(self):
        before = self.database.read_bytes()
        ops.set_env(self.xboard / ".env", {"INSTALLED": "false", "DB_DATABASE": "/www/.docker/.data/database.sqlite"})
        ops.normalize_existing_env(self.xboard)
        values = ops.read_env(self.xboard / ".env")
        self.assertEqual(values["APP_KEY"], "base64:original-key")
        self.assertEqual(values["APP_URL"], "https://panel.example")
        self.assertEqual(values["INSTALLED"], "true")
        self.assertEqual(self.database.read_bytes(), before)

    def test_row_loss_after_migration_is_reported(self):
        baseline = self.parent / "before.json"
        ops.write_json(baseline, ops.sqlite_report(self.database))
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("DELETE FROM v2_server_vmess")
        with self.assertRaisesRegex(ops.OperationError, "v2_server"):
            ops.check_counts(baseline, self.database)

    def test_saved_password_quotes_round_trip_without_execution(self):
        path = self.project / "deploy.env"
        secret = "spaces ' $() ; # not-a-command"
        ops.set_env(path, {"XBOARD_ADMIN_PASSWORD": secret})
        self.assertEqual(ops.read_env(path)["XBOARD_ADMIN_PASSWORD"], secret)
        if os.name == "posix":
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_row_replacement_with_same_count_is_detected(self):
        baseline = self.parent / "before.json"
        ops.write_json(baseline, ops.sqlite_report(self.database))
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("UPDATE v2_user SET id=999")
        with self.assertRaisesRegex(ops.OperationError, "identities"):
            ops.check_counts(baseline, self.database)

    def test_changed_app_key_is_detected(self):
        baseline = self.parent / "before.json"
        ops.write_json(baseline, ops.sqlite_report(self.database))
        ops.set_env(self.xboard / ".env", {"APP_KEY": "unexpected-replacement"})
        with self.assertRaisesRegex(ops.OperationError, "configuration"):
            ops.check_counts(baseline, self.database)


class ComposeTests(WorkspaceCase):
    def test_default_custom_and_localhost_ports_keep_other_configuration(self):
        config = {"services": {"xboard": {"image": "original:stable", "environment": {"KEEP": "yes"}, "ports": [{"target": 7001, "published": "7001", "host_ip": "127.0.0.1", "protocol": "tcp"}]}}}
        path = self.xboard / "compose.yaml"
        for port in (7001, 35613):
            with patch.object(ops, "editable_compose", return_value=copy.deepcopy(config)):
                ops.set_xboard_port(path, port)
            result = json.loads(path.read_text())["services"]["xboard"]
            self.assertEqual(result["ports"][0]["published"], str(port))
            self.assertEqual(result["ports"][0]["host_ip"], "127.0.0.1")
            self.assertEqual(result["environment"], {"KEEP": "yes"})
            self.assertEqual(result["image"], "original:stable")

    def test_unsupported_ports_do_not_change_the_file(self):
        path = self.xboard / "compose.yaml"
        before = path.read_bytes()
        with patch.object(ops, "editable_compose", return_value={"services": {"xboard": {"ports": []}}}):
            with self.assertRaises(ops.OperationError):
                ops.set_xboard_port(path, 7001)
        self.assertEqual(before, path.read_bytes())

    def test_npm_ports_preserve_custom_environment_and_volumes(self):
        config = {"services": {"app": {"image": "original:stable", "environment": {"PUID": "1000"}, "volumes": [{"type": "bind", "source": "./certs", "target": "/certs"}], "ports": [{"target": 81, "published": "81", "host_ip": "127.0.0.1"}]}}}
        path = self.project / ops.STACKS[0] / "compose.yaml"
        with patch.object(ops, "editable_compose", return_value=copy.deepcopy(config)):
            ops.set_npm_ports(path, 80, 443, 35612, "36333")
        result = json.loads(path.read_text())["services"]["app"]
        self.assertEqual(result["environment"], config["services"]["app"]["environment"])
        self.assertEqual(result["volumes"], config["services"]["app"]["volumes"])
        self.assertEqual([port["published"] for port in result["ports"]], ["80", "443", "35612", "36333"])


class HttpResponseTests(WorkspaceCase):
    def test_xboard_api_requires_nonempty_configuration(self):
        path = self.parent / "response.json"
        for data in ('{"error":"failed"}', '{"data":[]}', '{"data":{}}', 'not-json'):
            path.write_text(data)
            self.assertFalse(ops.check_response(path, "json"))
        path.write_text('{"data":{"captcha_type":"recaptcha"}}')
        self.assertTrue(ops.check_response(path, "json"))

    def test_npm_requires_its_backend_health_response(self):
        path = self.parent / "response.json"
        path.write_text('{"status":"OK","version":{"major":2},"setup":false}')
        self.assertTrue(ops.check_response(path, "npm-json"))
        path.write_text('{"status":"error","version":{"major":2}}')
        self.assertFalse(ops.check_response(path, "npm-json"))

    def test_html_error_text_or_json_is_not_a_panel_page(self):
        path = self.parent / "response.html"
        for data in ('<html><body>Bad request</body></html>', '{}', ''):
            path.write_text(data)
            self.assertFalse(ops.check_response(path, "html"))
        path.write_text('<!doctype html><html><script src="app.js"></script></html>')
        self.assertTrue(ops.check_response(path, "html"))


class ArchiveTests(WorkspaceCase):
    def test_checksum_uses_digest_not_the_old_server_filename(self):
        self.assertEqual(ops.validate_archive(self.archive())["version"], 2)

    def test_modified_archive_rejected_before_docker_is_used(self):
        archive = self.archive()
        with archive.open("ab") as handle:
            handle.write(b"changed")
        with patch.object(ops, "run") as docker:
            with self.assertRaisesRegex(ops.OperationError, "checksum"):
                ops.restore(archive, self.project, overwrite=True)
            docker.assert_not_called()

    def test_missing_checksum_requires_explicit_legacy_flag(self):
        archive = self.archive()
        Path(str(archive) + ".sha256").unlink()
        with self.assertRaisesRegex(ops.OperationError, "Missing"):
            ops.validate_archive(archive)
        self.assertEqual(ops.validate_archive(archive, allow_legacy=True)["version"], 2)

    def test_reject_traversal_absolute_and_special_files(self):
        for name in ("xboard-one-click/../elsewhere", "/etc/passwd", "other/target", "xboard-one-click/a\\b"):
            with self.subTest(name=name), self.assertRaises(ops.OperationError):
                ops.validate_members([tarfile.TarInfo(name)])
        member = tarfile.TarInfo("xboard-one-click/fifo")
        member.type = tarfile.FIFOTYPE
        with self.assertRaises(ops.OperationError):
            ops.validate_members([member])

    def test_reject_escape_links_and_link_ancestors(self):
        link = tarfile.TarInfo("xboard-one-click/link")
        link.type = tarfile.SYMTYPE
        link.linkname = "../../outside"
        with self.assertRaises(ops.OperationError):
            ops.validate_members([link])
        link.linkname = "safe"
        with self.assertRaises(ops.OperationError):
            ops.validate_members([link, tarfile.TarInfo("xboard-one-click/link/child")])

    def test_certificate_relative_symlinks_are_supported(self):
        link = tarfile.TarInfo("xboard-one-click/runtime/npm/letsencrypt/live/domain/cert.pem")
        link.type = tarfile.SYMTYPE
        link.linkname = "../../archive/domain/cert1.pem"
        ops.validate_members([link])

    def test_manifest_cannot_choose_another_directory(self):
        manifest = ops.validate_archive(self.archive())
        manifest["stacks"][0]["directory"] = "../../other"
        with self.assertRaises(ops.OperationError):
            ops.validate_manifest(manifest)

    def test_backup_choice_accepts_number_or_unique_basename(self):
        archive = self.archive()
        backups = Path(str(self.project) + "-backups")
        backups.mkdir()
        selected = backups / archive.name
        archive.rename(selected)
        for value in ("1\n", selected.name + "\n"):
            with patch("sys.stdin", io.StringIO(value)):
                self.assertEqual(ops.select_backup(self.project), selected)


class OwnershipTests(WorkspaceCase):
    def test_container_name_alone_is_not_ownership(self):
        item = self.stacks()[0]["services"]["app"]
        self.assertTrue(ops.container_belongs(item, self.project / ops.STACKS[0]))
        item["Config"]["Labels"]["com.docker.compose.project.working_dir"] = str(self.parent / "another-project")
        self.assertFalse(ops.container_belongs(item, self.project / ops.STACKS[0]))

    def test_config_files_must_also_be_inside_the_stack(self):
        item = self.stacks()[0]["services"]["app"]
        item["Config"]["Labels"]["com.docker.compose.project.config_files"] = str(self.parent / "other.yaml")
        self.assertFalse(ops.container_belongs(item, self.project / ops.STACKS[0]))

    def test_backup_directory_cannot_be_an_ancestor_or_project_child(self):
        for target in (self.parent, self.project, self.project / "backups"):
            with self.subTest(target=target), self.assertRaises(ops.OperationError):
                ops.safe_backup_directory(target, self.project)

    def test_custom_backup_deletion_requires_ownership_marker(self):
        other = self.parent / "personal-files"
        other.mkdir()
        with patch.object(ops, "inventory") as inspect:
            with self.assertRaisesRegex(ops.OperationError, "ownership"):
                ops.uninstall(self.project, "all", True, other)
            inspect.assert_not_called()

    def test_backup_does_not_claim_a_directory_with_personal_files(self):
        directory = self.parent / "personal"
        directory.mkdir()
        document = directory / "notes.txt"
        document.write_text("must remain untouched")
        with patch.object(ops, "inventory") as inspect:
            with self.assertRaisesRegex(ops.OperationError, "Unrecognized file"):
                ops.backup(self.project, directory)
            inspect.assert_not_called()
        self.assertEqual(document.read_text(), "must remain untouched")
        self.assertFalse((directory / ".xboard-backup-owner").exists())

    def test_purge_refuses_mixed_files_even_with_an_ownership_marker(self):
        directory = Path(str(self.project) + "-backups")
        directory.mkdir()
        (directory / ".xboard-backup-owner").write_text(str(self.project))
        (directory / "personal-photo.jpg").write_bytes(b"unrelated")
        with patch.object(ops, "inventory") as inspect:
            with self.assertRaisesRegex(ops.OperationError, "Unrecognized file"):
                ops.uninstall(self.project, "all", purge_backups=True)
            inspect.assert_not_called()
        self.assertTrue(self.database.exists())
        self.assertEqual((directory / "personal-photo.jpg").read_bytes(), b"unrelated")

    def test_custom_named_archive_is_recognized_by_its_own_metadata(self):
        directory = Path(str(self.project) + "-backups")
        directory.mkdir()
        (directory / "migration.tar.gz").write_bytes(b"fixture")
        ops.write_json(directory / "migration.tar.gz.info", {"version": 2, "project": str(self.project)})
        (directory / "migration.tar.gz.sha256").write_text("fixture checksum")
        ops.validate_backup_contents(directory, self.project)

    def test_existing_partial_backup_is_not_overwritten(self):
        directory = Path(str(self.project) + "-backups")
        directory.mkdir()
        output = directory / "xboard-one-click-backup-20260908-100000.tar.gz"
        partial = Path(str(output) + ".partial")
        partial.write_bytes(b"previous interrupted backup")
        with patch.object(ops, "inventory") as inspect:
            with self.assertRaisesRegex(ops.OperationError, "already exists"):
                ops.backup(self.project, directory, output=output)
            inspect.assert_not_called()
        self.assertEqual(partial.read_bytes(), b"previous interrupted backup")


class RecoveryTests(WorkspaceCase):
    def fake_image_inspect(self, *args):
        return [{"Id": IMAGE_ID, "Size": 0}]

    def test_restore_loads_exact_images_and_uses_new_redis_volume(self):
        original = self.database.read_bytes()
        archive = self.archive(volume=True)
        with closing(sqlite3.connect(self.database)) as connection, connection:
            connection.execute("UPDATE v2_user SET email='changed-after-backup@example.test'")
        with patch.object(ops, "inventory", return_value=self.stacks()), patch.object(ops, "run", return_value="") as docker, \
                patch.object(ops, "docker_json", side_effect=self.fake_image_inspect), patch.object(ops, "compose"), patch.object(ops, "healthcheck"):
            ops.restore(archive, self.project, overwrite=True)
        self.assertEqual(self.database.read_bytes(), original)
        lock = json.loads((self.xboard / ".xb-images.json").read_text())
        self.assertEqual(lock["services"]["xboard"]["image"], IMAGE_REF)
        volumes = json.loads((self.xboard / ".xb-volumes.json").read_text())
        self.assertTrue(all(value["name"].startswith("xboard-restore-") for value in volumes["volumes"].values()))
        self.assertTrue(list(self.parent.glob("xboard-one-click.before-restore-*")))
        self.assertTrue(any(call.args[0][:3] == ["docker", "image", "load"] for call in docker.call_args_list))

    def test_failed_healthcheck_restores_previous_directory_and_reports_failure(self):
        archive = self.archive()
        marker = self.project / "current-only.txt"
        marker.write_text("must survive failed restoration")
        original = self.database.read_bytes()
        with patch.object(ops, "inventory", return_value=self.stacks()), patch.object(ops, "run", return_value=""), \
                patch.object(ops, "docker_json", side_effect=self.fake_image_inspect), patch.object(ops, "compose"), \
                patch.object(ops, "healthcheck", side_effect=ops.OperationError("HTTP 500")):
            with self.assertRaisesRegex(ops.OperationError, "HTTP 500"):
                ops.restore(archive, self.project, overwrite=True)
        self.assertEqual(marker.read_text(), "must survive failed restoration")
        self.assertEqual(self.database.read_bytes(), original)
        self.assertTrue(list(self.parent.glob("xboard-one-click.failed-restore-*")))

    def test_bad_staged_compose_does_not_stop_the_existing_project(self):
        archive = self.archive()
        with patch.object(ops, "inventory", return_value=self.stacks()), patch.object(ops, "run", return_value=""), \
                patch.object(ops, "docker_json", side_effect=self.fake_image_inspect), \
                patch.object(ops, "compose", side_effect=ops.OperationError("invalid compose")), patch.object(ops, "stop_stacks") as stop:
            with self.assertRaises(ops.OperationError):
                ops.restore(archive, self.project, overwrite=True)
            stop.assert_not_called()

    def test_healthcheck_nonzero_is_never_reported_as_success(self):
        with patch.object(ops.subprocess, "run") as command, patch.object(ops.time, "sleep"):
            command.return_value.returncode = 42
            command.return_value.stdout = "synthetic failure\n"
            with self.assertRaisesRegex(ops.OperationError, "did NOT succeed"):
                ops.healthcheck(self.project)
            self.assertEqual(command.call_count, 6)

    def test_backup_failure_restarts_original_containers(self):
        volume_dir = self.parent / "redis-volume"
        volume_dir.mkdir()
        def metadata(*args):
            if args[:2] == ("volume", "inspect"):
                return [{"Mountpoint": str(volume_dir)}]
            return [{"Size": 0, "Id": IMAGE_ID}]
        def command(args, **kwargs):
            if args[:3] == ["docker", "image", "save"]:
                Path(args[4]).write_bytes(b"image")
            if args[:2] == ["docker", "run"]:
                raise ops.OperationError("volume export failed")
            return ""
        with patch.object(ops, "inventory", return_value=self.stacks(volume=True)), patch.object(ops, "docker_json", side_effect=metadata), \
                patch.object(ops, "run", side_effect=command) as docker:
            with self.assertRaisesRegex(ops.OperationError, "volume export"):
                ops.backup(self.project, str(self.project) + "-backups")
        starts = [call.args[0] for call in docker.call_args_list if call.args[0][:2] == ["docker", "start"]]
        self.assertEqual(len(starts), 2)
        self.assertTrue(self.database.exists())


if __name__ == "__main__":
    unittest.main()
