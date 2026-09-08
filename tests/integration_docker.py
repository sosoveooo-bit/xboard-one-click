"""Real Docker round trip; run only on a disposable Linux runner with local Docker."""
from contextlib import closing
import importlib.util
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import tempfile
import uuid
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("operations", ROOT / "lib/operations.py")
ops = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(ops)


def execute():
    if os.name != "posix" or os.geteuid() != 0 or os.environ.get("XB_DISPOSABLE_DOCKER_TEST") != "1":
        raise SystemExit("Requires root on a disposable Linux Docker runner and XB_DISPOSABLE_DOCKER_TEST=1")
    original_cwd = Path.cwd()
    namespace = "xb-ci-" + uuid.uuid4().hex[:12]
    candidate = namespace + ":candidate"
    unrelated_volume = "xboard_" + namespace + "_unrelated"
    for image in ("busybox:1.36.1", "busybox:1.37.0"):
        ops.run(["docker", "pull", image])
    original_image = ops.docker_json("image", "inspect", "busybox:1.36.1")[0]["Id"]
    ops.run(["docker", "tag", "busybox:1.36.1", candidate])
    with tempfile.TemporaryDirectory(prefix="xb-docker-test-") as temporary:
        project = Path(temporary) / "xboard-one-click"
        project.mkdir()
        (project / "lib").mkdir()
        shutil.copy2(ROOT / "lib/common.sh", project / "lib/common.sh")
        for filename in ("install.sh", "menu.sh"):
            (project / filename).write_text("#!/bin/bash\nexit 0\n")
        for index, relative in enumerate(ops.STACKS):
            directory = project / relative
            directory.mkdir(parents=True)
            service = "app" if index == 0 else "xboard"
            config = {"name": namespace + "-" + service, "services": {service: {"image": candidate,
                "command": ["sh", "-c", "test -e /data/sentinel || echo original-volume > /data/sentinel; exec sleep 3600"],
                "volumes": [{"type": "volume", "source": "state", "target": "/data"}]}}, "volumes": {"state": {}}}
            if service == "xboard":
                config["services"][service]["volumes"].append({"type": "bind", "source": "./.docker/.data", "target": "/appdata"})
            ops.write_json(directory / "compose.yaml", config)
        database = project / "runtime/Xboard/.docker/.data/database.sqlite"
        database.parent.mkdir(parents=True)
        with closing(sqlite3.connect(database)) as connection, connection:
            connection.executescript("CREATE TABLE v2_user(id INTEGER PRIMARY KEY,email TEXT); INSERT INTO v2_user VALUES(1,'admin@example.test'); CREATE TABLE v2_server(id INTEGER PRIMARY KEY,host TEXT); INSERT INTO v2_server VALUES(1,'node.example'); CREATE TABLE v2_settings(id INTEGER PRIMARY KEY,value TEXT); INSERT INTO v2_settings VALUES(1,'original-config');")
        (project / "runtime/Xboard/.env").write_text("APP_KEY=base64:fixture-key\nINSTALLED=true\nDB_CONNECTION=sqlite\nDB_DATABASE=.docker/.data/database.sqlite\n")
        (project / "healthcheck.sh").write_text('''#!/usr/bin/env bash
set -euo pipefail
base="$(cd "$(dirname "$0")" && pwd)"
source "$base/lib/common.sh"
for stack in nginx-proxy-manager Xboard; do
  service=app
  [ "$stack" != Xboard ] || service=xboard
  xb_compose "$base/runtime/$stack" exec -T "$service" cat /data/sentinel | grep -qx original-volume
done
''')
        original_volumes = set()
        unrelated_created = False
        try:
            ops.start_stacks(project)
            for stack in ops.inventory(project, require_all=True):
                for item in stack["services"].values():
                    original_volumes.update(mount["Name"] for mount in item["Mounts"] if mount["Type"] == "volume")
            original_database = database.read_bytes()
            archive = ops.backup(project, str(project) + "-backups")
            ops.validate_archive(archive)
            # Move the candidate tag and change both bind data and named-volume data.
            ops.run(["docker", "tag", "busybox:1.37.0", candidate])
            for relative in ops.STACKS:
                ops.compose(project / relative, "up", "-d", "--force-recreate")
                service = "xboard" if relative.endswith("Xboard") else "app"
                ops.compose(project / relative, "exec", "-T", service, "sh", "-c", "echo changed-volume > /data/sentinel")
            with closing(sqlite3.connect(database)) as connection, connection:
                connection.execute("DELETE FROM v2_user")
                connection.execute("UPDATE v2_settings SET value='changed-config'")
            with patch.object(ops, "install_shortcut"):
                ops.restore(archive, project, overwrite=True)
            assert database.read_bytes() == original_database, "Bind-mounted application data changed"
            for stack in ops.inventory(project, require_all=True):
                for item in stack["services"].values():
                    assert item["Image"] == original_image, "Restoration reused the moved candidate tag"
                    assert all(mount["Name"] not in original_volumes for mount in item["Mounts"] if mount["Type"] == "volume")
                    if any(mount["Type"] == "bind" for mount in item["Mounts"]):
                        assert any(mount["Source"] == str(database.parent) and mount["Destination"] == "/appdata" for mount in item["Mounts"])
            ops.healthcheck(project)
            # The pre-restore volumes must still contain their newer data, not be overwritten.
            for name in original_volumes:
                value = ops.run(["docker", "run", "--rm", "--network", "none", "--mount", "type=volume,src=" + name + ",dst=/data,readonly", "busybox:1.36.1", "cat", "/data/sentinel"], capture=True)
                assert value == "changed-volume"
            ops.run(["docker", "volume", "create", "--label", "xb-ci-test=" + namespace, unrelated_volume])
            unrelated_created = True
            ops.uninstall(project, "data")
            assert not (project / "runtime").exists()
            assert archive.is_file(), "Uninstall deleted an unselected backup"
            assert ops.docker_json("volume", "inspect", unrelated_volume), "Uninstall touched an unrelated volume"
            print("Real Docker round trip passed: exact images, SQLite users/nodes/settings, isolated named volumes, scoped uninstall")
        finally:
            if project.exists():
                try:
                    ops.stop_stacks(project, ops.inventory(project))
                except Exception as error:
                    print("Cleanup warning:", error)
            restored_volumes = ops.run(["docker", "volume", "ls", "-q", "--filter", "label=com.xboard.one-click.project=" + str(project)], capture=True).split()
            for name in sorted(original_volumes | set(restored_volumes)):
                subprocess.run(["docker", "volume", "rm", name], check=False)
            if unrelated_created:
                subprocess.run(["docker", "volume", "rm", unrelated_volume], check=False)
            subprocess.run(["docker", "image", "rm", candidate], check=False)
            os.chdir(original_cwd)


if __name__ == "__main__":
    execute()
