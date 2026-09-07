#!/usr/bin/env python3
"""Fail-closed data and Docker operations for the one-click scripts."""

import argparse
import contextlib
import hashlib
import json
import os
import posixpath
import re
import shlex
import signal
import shutil
import sqlite3
import subprocess
import sys
import tarfile
import tempfile
import time
import uuid
from pathlib import Path, PurePosixPath


class OperationError(RuntimeError):
    pass


STACKS = ("runtime/nginx-proxy-manager", "runtime/Xboard")
PROTECTED = {"/", "/root", "/home", "/usr", "/usr/local", "/var", "/opt", "/tmp"}
ENV_KEY = re.compile(r"[A-Z][A-Z0-9_]*\Z")


def log(message):
    print("[xboard-safety] " + str(message), file=sys.stderr, flush=True)


def run(args, cwd=None, capture=False):
    result = subprocess.run(
        [str(arg) for arg in args], cwd=cwd, check=False, text=True,
        stdout=subprocess.PIPE if capture else sys.stderr,
    )
    if result.returncode:
        raise OperationError("Command failed ({}): {}".format(result.returncode, args[0]))
    return result.stdout.strip() if capture else None


def docker_json(*args):
    return json.loads(run(["docker", *args], capture=True))


def compose_args(directory):
    directory = Path(directory)
    bases = ("compose.yaml", "compose.yml", "docker-compose.yml", "docker-compose.yaml")
    base = next((name for name in bases if (directory / name).is_file()), None)
    if base is None:
        raise OperationError("Missing Compose file: " + str(directory))
    args = ["docker", "compose", "-f", base]
    for name in ("compose.override.yaml", "compose.override.yml", "docker-compose.override.yml", "docker-compose.override.yaml"):
        if (directory / name).is_file():
            args += ["-f", name]
            break
    for name in (".xb-volumes.json", ".xb-images.json"):
        if (directory / name).is_file():
            args += ["-f", name]
    return args


def compose(directory, *args, capture=False):
    return run(compose_args(directory) + list(args), cwd=directory, capture=capture)


def editable_compose(path):
    if Path(path).is_symlink():
        raise OperationError("Compose file must not be a symlink")
    path = Path(path).resolve()
    config = json.loads(run(["docker", "compose", "-f", path.name, "config", "--format", "json"], cwd=path.parent, capture=True))
    for service in config.get("services", {}).values():
        for mount in service.get("volumes", []):
            if isinstance(mount, dict) and mount.get("type") == "bind" and Path(mount.get("source", "")).is_absolute():
                mount["source"] = os.path.relpath(mount["source"], path.parent).replace(os.sep, "/")
                if not mount["source"].startswith("."):
                    mount["source"] = "./" + mount["source"]
        for entry in service.get("env_file", []):
            if isinstance(entry, dict) and Path(entry.get("path", "")).is_absolute():
                entry["path"] = os.path.relpath(entry["path"], path.parent).replace(os.sep, "/")
    return config


def set_xboard_port(path, port):
    port = int(port)
    if not 1 <= port <= 65535:
        raise OperationError("Invalid Xboard port")
    config = editable_compose(path)
    service = config.get("services", {}).get("xboard", {})
    matches = [item for item in service.get("ports", []) if isinstance(item, dict) and str(item.get("target")) == "7001" and item.get("protocol", "tcp") == "tcp"]
    if len(matches) != 1:
        raise OperationError("Expected exactly one Xboard TCP port mapping; no configuration was changed")
    matches[0]["published"] = str(port)
    write_json(path, config)


def set_npm_ports(path, http, https, admin, extra):
    config = editable_compose(path)
    service = config.get("services", {}).get("app")
    if not service:
        raise OperationError("NPM app service missing")
    old_ports = service.get("ports", [])
    desired = [(int(http), 80), (int(https), 443), (int(admin), 81)]
    desired += [(int(item), 443) for item in extra.split(",") if item]
    if any(not 1 <= published <= 65535 for published, _ in desired) or len({item[0] for item in desired}) != len(desired):
        raise OperationError("Invalid or duplicate NPM ports")
    ports = [item for item in old_ports if str(item.get("target")) not in ("80", "443", "81")]
    for published, target in desired:
        previous = next((item for item in old_ports if str(item.get("target")) == str(target)), {})
        ports.append({**previous, "target": target, "published": str(published), "protocol": "tcp"})
    service["ports"] = ports
    write_json(path, config)


def atomic_text(path, value, mode=0o600):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix="." + path.name + ".", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8", newline="\n") as handle:
            handle.write(value)
            handle.flush()
            os.fsync(handle.fileno())
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        if os.path.exists(temporary):
            os.unlink(temporary)


def write_json(path, value):
    atomic_text(path, json.dumps(value, indent=2, ensure_ascii=True) + "\n")


def read_env(path):
    values = {}
    if not Path(path).is_file():
        return values
    for line in Path(path).read_text(encoding="utf-8").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "=" not in line:
            raise OperationError("Invalid environment configuration; expected KEY=value")
        key, value = line.split("=", 1)
        if not ENV_KEY.fullmatch(key):
            raise OperationError("Invalid environment key: " + key)
        try:
            parts = shlex.split(value, comments=True)
        except ValueError as exc:
            raise OperationError("Invalid quoting in environment key: " + key) from exc
        values[key] = " ".join(parts)
    return values


def set_env(path, updates):
    path = Path(path)
    for key in updates:
        if not ENV_KEY.fullmatch(key):
            raise OperationError("Invalid environment key")
    lines = path.read_text(encoding="utf-8").splitlines() if path.exists() else []
    result, seen = [], set()
    for line in lines:
        key = line.split("=", 1)[0]
        if key in updates:
            if key not in seen:
                result.append(key + "=" + shlex.quote(updates[key]))
                seen.add(key)
        else:
            result.append(line)
    result += [key + "=" + shlex.quote(value) for key, value in updates.items() if key not in seen]
    atomic_text(path, "\n".join(result) + "\n")


def inside(child, parent):
    try:
        Path(child).resolve().relative_to(Path(parent).resolve())
        return True
    except ValueError:
        return False


def safe_project(path, exists=True):
    raw = Path(path).absolute()
    resolved = raw.resolve()
    if raw != resolved or str(resolved) in PROTECTED or resolved == Path.home().resolve():
        raise OperationError("Unsafe or symlinked project path: " + str(raw))
    if resolved.name != "xboard-one-click":
        raise OperationError("Project directory must be named xboard-one-click: " + str(resolved))
    if exists and not all((resolved / name).is_file() for name in ("install.sh", "menu.sh")):
        raise OperationError("Project markers missing: " + str(resolved))
    for relative in ("runtime", *STACKS):
        child = resolved / relative
        if child.is_symlink() or not inside(child, resolved):
            raise OperationError("Symlinked/external runtime directory is not supported: " + str(child))
    return resolved


def safe_backup_directory(path, project):
    raw = Path(path).absolute()
    path = raw.resolve()
    if raw != path or str(path) in PROTECTED or path == Path.home().resolve():
        raise OperationError("Unsafe or symlinked backup directory: " + str(raw))
    if inside(path, project) or inside(project, path):
        raise OperationError("Backup and project directories must not contain each other")
    return path


def sqlite_report(path):
    path = Path(path)
    if not path.is_file() or path.stat().st_size == 0:
        raise OperationError("Database is missing or empty; no initialization was performed")
    try:
        with contextlib.closing(sqlite3.connect(path.resolve().as_uri() + "?mode=ro", uri=True, timeout=5)) as connection:
            if connection.execute("PRAGMA quick_check").fetchone()[0] != "ok":
                raise OperationError("SQLite integrity check failed; preserve this database and restore a verified backup")
            tables = {row[0] for row in connection.execute("SELECT name FROM sqlite_master WHERE type='table'")}
            counts, identities = {}, {}
            for table in sorted(tables):
                if re.fullmatch(r"v2_[A-Za-z0-9_]+", table):
                    counts[table] = connection.execute('SELECT COUNT(*) FROM "' + table + '"').fetchone()[0]
                    if business_table(table):
                        columns = {row[1] for row in connection.execute('PRAGMA table_info("' + table + '")')}
                        if "id" in columns:
                            identities[table] = [str(row[0]) for row in connection.execute('SELECT id FROM "' + table + '" ORDER BY id')]
            env_path = path.parent.parent.parent / ".env"
            values = read_env(env_path)
            if values.get("DB_DATABASE") == "/www/.docker/.data/database.sqlite":
                values["DB_DATABASE"] = ".docker/.data/database.sqlite"
            protected = ("APP_KEY", "APP_URL", "DB_CONNECTION", "DB_DATABASE", "REDIS_HOST", "REDIS_PORT", "REDIS_PASSWORD")
            fingerprint = hashlib.sha256(json.dumps({key: values.get(key) for key in protected}, sort_keys=True).encode()).hexdigest()
            return {"tables": sorted(tables), "counts": counts, "identities": identities, "configuration": fingerprint}
    except sqlite3.Error as exc:
        raise OperationError("Cannot read SQLite safely (not evidence that it needs resetting): " + str(exc)) from exc


def business_table(table):
    return table == "v2_user" or table.startswith("v2_server") or table in ("v2_plan", "v2_order", "v2_settings", "v2_config")


def install_state(directory):
    directory = Path(directory)
    env = read_env(directory / ".env")
    data_dir = directory / ".docker/.data"
    database = data_dir / "database.sqlite"
    if env.get("DB_CONNECTION") not in (None, "", "sqlite"):
        raise OperationError("Non-SQLite configuration detected; automatic installation/repair is blocked")
    evidence = data_dir.exists() and any(
        path.is_file() and path.stat().st_size > 0
        for path in data_dir.glob("*sqlite*")
    )
    installed = env.get("INSTALLED", "").lower() == "true"
    if not evidence and not installed:
        return "fresh"
    if not env.get("APP_KEY"):
        raise OperationError("Existing data found but APP_KEY/.env is missing. Restore the original .env; do not reinstall")
    if env.get("DB_CONNECTION") != "sqlite" or env.get("DB_DATABASE") not in (
        ".docker/.data/database.sqlite", "/www/.docker/.data/database.sqlite"
    ):
        raise OperationError("Existing database connection is not the supported SQLite layout; it was NOT changed")
    report = sqlite_report(database)
    if "v2_user" not in report["tables"]:
        raise OperationError("Existing database lacks v2_user. Initialization is blocked; restore or diagnose it manually")
    return "existing"


def normalize_existing_env(directory):
    directory = Path(directory)
    if install_state(directory) != "existing":
        raise OperationError("No existing database to repair")
    set_env(directory / ".env", {
        "INSTALLED": "true",
        "DB_DATABASE": ".docker/.data/database.sqlite",
        "ENABLE_AUTO_BACKUP_AND_UPDATE": "false",
    })


def check_counts(baseline, database):
    before = json.loads(Path(baseline).read_text())
    after = sqlite_report(database)
    if before.get("configuration") != after["configuration"]:
        raise OperationError("Protected application configuration changed during the operation")
    for table, count in before["counts"].items():
        if count and business_table(table):
            if after["counts"].get(table, 0) < count:
                raise OperationError("Business rows disappeared during operation: " + table)
            if not set(before.get("identities", {}).get(table, [])) <= set(after["identities"].get(table, [])):
                raise OperationError("Business row identities disappeared during operation: " + table)


def container_belongs(container, directory):
    labels = container.get("Config", {}).get("Labels") or {}
    workdir = labels.get("com.docker.compose.project.working_dir", "")
    files = labels.get("com.docker.compose.project.config_files", "").split(",")
    return bool(workdir and Path(workdir).resolve() == Path(directory).resolve() and all(
        file and inside(file, directory) for file in files
    ))


def inventory(project, require_all=False):
    stacks = []
    for relative in STACKS:
        directory = project / relative
        if not directory.exists():
            if require_all:
                raise OperationError("Missing runtime directory: " + str(directory))
            continue
        config = json.loads(compose(directory, "config", "--format", "json", capture=True))
        name = config.get("name")
        if not name:
            raise OperationError("Compose v2 JSON project name is required")
        ids = run(["docker", "ps", "-aq", "--filter", "label=com.docker.compose.project=" + name], capture=True).split()
        containers = docker_json("inspect", *ids) if ids else []
        if any(not container_belongs(item, directory) for item in containers):
            raise OperationError("Foreign Docker project shares this Compose name; refusing to touch it: " + name)
        services = {}
        for item in containers:
            service = item["Config"]["Labels"].get("com.docker.compose.service")
            if service not in config.get("services", {}):
                raise OperationError("Unknown/orphan service requires manual inspection: " + str(service))
            if service in services:
                raise OperationError("Scaled services require a separate backup workflow")
            services[service] = item
        if require_all and set(services) != set(config.get("services", {})):
            raise OperationError("Not all configured containers exist; refusing an incomplete backup")
        stacks.append({"directory": relative, "name": name, "services": services, "config": config})
    return stacks


def local_image_ref(image_id):
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        raise OperationError("Invalid image ID in Docker metadata")
    return "xboard-one-click-snapshot:" + image_id.split(":", 1)[1]


def pin_images(project):
    for stack in inventory(project, require_all=True):
        services = {}
        for service, container in stack["services"].items():
            reference = local_image_ref(container["Image"])
            run(["docker", "image", "tag", container["Image"], reference])
            services[service] = {"image": reference, "pull_policy": "never"}
        write_json(project / stack["directory"] / ".xb-images.json", {"services": services})


def unpin_images(project):
    inventory(project, require_all=True)
    for relative in STACKS:
        path = project / relative / ".xb-images.json"
        if path.is_symlink():
            raise OperationError("Image lock must not be a symlink")
        if path.is_file():
            path.unlink()


def check_running(project):
    for stack in inventory(project, require_all=True):
        for name, container in stack["services"].items():
            state = container.get("State", {})
            if not state.get("Running") or state.get("Restarting") or state.get("Health", {}).get("Status", "healthy") != "healthy":
                raise OperationError("Container is not ready: " + name)


def hash_file(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for block in iter(lambda: handle.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def validate_members(members, expected_root="xboard-one-click"):
    names, links = set(), set()
    for member in members:
        name = member.name.rstrip("/")
        parts = PurePosixPath(name).parts
        if (not parts or parts[0] != expected_root or name.startswith("/") or ".." in parts
                or "\\" in name or any(ord(char) < 32 for char in name)):
            raise OperationError("Unsafe archive path: " + repr(name))
        if name in names:
            raise OperationError("Duplicate archive member: " + name)
        names.add(name)
        if not (member.isfile() or member.isdir() or member.issym() or member.islnk()):
            raise OperationError("Special file is not allowed in backups: " + name)
        if member.issym() or member.islnk():
            target = member.linkname
            if target.startswith("/") or "\\" in target or any(ord(char) < 32 for char in target):
                raise OperationError("Unsafe archive link: " + name)
            destination = posixpath.normpath(posixpath.join(posixpath.dirname(name), target)) if member.issym() else posixpath.normpath(target)
            if destination != expected_root and not destination.startswith(expected_root + "/"):
                raise OperationError("Archive link escapes project: " + name)
            links.add(name)
    for name in names:
        if any(str(parent) in links for parent in PurePosixPath(name).parents):
            raise OperationError("Archive member is nested under a link: " + name)


def verify_checksum(archive, allow_legacy=False):
    sidecar = Path(str(archive) + ".sha256")
    if not sidecar.is_file():
        if allow_legacy:
            log("WARNING: legacy archive has no SHA-256 file; explicit unverified restore requested")
            return
        raise OperationError("Missing .sha256 file. Copy it with the backup; legacy restore requires --allow-legacy")
    lines = sidecar.read_text(encoding="utf-8").strip().splitlines()
    if len(lines) != 1 or not re.match(r"^[0-9a-fA-F]{64}(\s|$)", lines[0]):
        raise OperationError("Malformed SHA-256 file")
    if hash_file(archive) != lines[0][:64].lower():
        raise OperationError("Backup checksum mismatch; live services were not stopped")


def validate_archive(archive, allow_legacy=False):
    verify_checksum(archive, allow_legacy)
    try:
        with tarfile.open(archive, "r:gz") as handle:
            members = handle.getmembers()
            validate_members(members)
            names = {member.name.rstrip("/") for member in members}
            required = {"xboard-one-click/install.sh", "xboard-one-click/menu.sh", "xboard-one-click/healthcheck.sh"}
            if not required <= names:
                raise OperationError("Incomplete project backup")
            marker = "xboard-one-click/.backup/manifest.json"
            if marker not in names:
                if not allow_legacy:
                    raise OperationError("Legacy backup has no saved images/volumes; explicit --allow-legacy is required")
                return None
            manifest = json.load(handle.extractfile(marker))
            validate_manifest(manifest)
            for name, expected in manifest.get("payloads", {}).items():
                if not re.fullmatch(r"(?:images|volume-[0-9]+)\.tar", name):
                    raise OperationError("Invalid backup payload name")
                data = handle.extractfile("xboard-one-click/.backup/" + name)
                if data is None:
                    raise OperationError("Missing backup payload")
                digest = hashlib.sha256()
                for block in iter(lambda: data.read(1024 * 1024), b""):
                    digest.update(block)
                if digest.hexdigest() != expected:
                    raise OperationError("Backup payload checksum mismatch: " + name)
            if "images.tar" not in manifest.get("payloads", {}):
                raise OperationError("Backup does not contain images")
            return manifest
    except (tarfile.TarError, OSError, ValueError, KeyError, TypeError) as exc:
        raise OperationError("Invalid backup: " + str(exc)) from exc


def backup(project, backup_dir, output=None, keep_stopped=False):
    project = safe_project(project)
    backup_dir = safe_backup_directory(backup_dir, project)
    backup_dir.mkdir(parents=True, exist_ok=True, mode=0o700)
    owner_file = backup_dir / ".xboard-backup-owner"
    if owner_file.exists() and owner_file.read_text().strip() != str(project):
        raise OperationError("Backup directory belongs to another project")
    atomic_text(owner_file, str(project) + "\n")
    output = Path(output).absolute() if output else backup_dir / ("xboard-one-click-backup-" + time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6] + ".tar.gz")
    if output.parent.resolve() != backup_dir or output.exists() or output.is_symlink():
        raise OperationError("Backup output must be a new file directly inside the backup directory")
    stacks = inventory(project, require_all=True)
    all_ids = {item["Id"] for stack in stacks for item in stack["services"].values()}
    images, volumes, manifest_stacks, running = {}, {}, [], []
    for stack in stacks:
        saved = {"directory": stack["directory"], "services": {}}
        for service, container in stack["services"].items():
            image_id = container["Image"]
            reference = local_image_ref(image_id)
            images[reference] = image_id
            saved_service = {"image": reference, "id": image_id, "volumes": [], "binds": []}
            for mount in container.get("Mounts", []):
                if mount["Type"] == "bind" and not inside(mount["Source"], project):
                    raise OperationError("External bind mount would not be backed up: " + mount["Source"])
                if mount["Type"] == "bind":
                    saved_service["binds"].append({"source": Path(mount["Source"]).resolve().relative_to(project).as_posix(), "target": mount["Destination"], "read_only": not mount.get("RW", True)})
                if mount["Type"] == "volume":
                    name = mount["Name"]
                    users = set(run(["docker", "ps", "-aq", "--no-trunc", "--filter", "volume=" + name], capture=True).split())
                    if users - all_ids:
                        raise OperationError("Volume is shared with another project: " + name)
                    if name not in volumes:
                        volumes[name] = {"file": "volume-{}.tar".format(len(volumes)), "image": reference}
                    saved_service["volumes"].append({"file": volumes[name]["file"], "target": mount["Destination"], "read_only": not mount.get("RW", True)})
            saved["services"][service] = saved_service
            if container.get("State", {}).get("Running"):
                running.append(container["Id"])
        manifest_stacks.append(saved)
    size = sum(item.stat().st_size for item in project.rglob("*") if item.is_file() and not item.is_symlink())
    size += sum(docker_json("image", "inspect", image_id)[0].get("Size", 0) for image_id in set(images.values()))
    for name in volumes:
        mountpoint = Path(docker_json("volume", "inspect", name)[0]["Mountpoint"])
        if not mountpoint.is_dir():
            raise OperationError("Backup requires a local Docker daemon and readable named-volume mountpoints")
        size += sum(item.stat().st_size for item in mountpoint.rglob("*") if item.is_file() and not item.is_symlink())
    if shutil.disk_usage(backup_dir).free < size * 2 + 256 * 1024 * 1024:
        raise OperationError("Not enough free disk for a full backup (images and volumes included)")
    partial = Path(str(output) + ".partial")
    stopped, backup_error = [], None
    try:
        with tempfile.TemporaryDirectory(prefix=".xb-backup-", dir=backup_dir) as temporary:
            payload_dir = Path(temporary)
            for reference, image_id in images.items():
                run(["docker", "image", "tag", image_id, reference])
            log("Saving exact container images before maintenance downtime")
            run(["docker", "image", "save", "-o", payload_dir / "images.tar", *images])
            for container_id in running:
                stopped.append(container_id)
                run(["docker", "stop", container_id])
            for name, volume in volumes.items():
                run(["docker", "run", "--rm", "--network", "none", "--user", "0", "--entrypoint", "tar",
                     "--mount", "type=volume,src=" + name + ",dst=/source,readonly",
                     "--mount", "type=bind,src=" + str(payload_dir) + ",dst=/backup",
                     volume["image"], "-C", "/source", "-cf", "/backup/" + volume["file"], "."])
            manifest = {"version": 2, "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z"), "stacks": manifest_stacks,
                        "payloads": {item.name: hash_file(item) for item in payload_dir.glob("*.tar")}}
            write_json(payload_dir / "manifest.json", manifest)
            def archive_filter(member):
                if member.name == project.name + "/.backup" or member.name.startswith(project.name + "/.backup/"):
                    return None
                return member
            with tarfile.open(partial, "w:gz", dereference=False) as handle:
                handle.add(project, arcname=project.name, filter=archive_filter)
                handle.add(payload_dir, arcname=project.name + "/.backup")
            os.chmod(partial, 0o600)
            os.replace(partial, output)
            atomic_text(str(output) + ".sha256", hash_file(output) + "  " + output.name + "\n")
            write_json(str(output) + ".info", {"created_at": manifest["created_at"], "project": str(project), "bytes": output.stat().st_size, "version": 2})
            validate_archive(output)
    except BaseException as exc:
        backup_error = exc
    restart_errors = []
    for container_id in stopped if backup_error or not keep_stopped else []:
        try:
            run(["docker", "start", container_id])
        except OperationError as exc:
            restart_errors.append(str(exc))
    if partial.exists():
        partial.unlink()
    if backup_error:
        raise backup_error
    if restart_errors:
        raise OperationError("Backup saved at {} but restarting original containers failed".format(output))
    log("Verified full backup saved: " + str(output))
    return output


def validate_manifest(manifest):
    if not isinstance(manifest, dict) or manifest.get("version") != 2:
        raise OperationError("Unsupported backup manifest")
    stacks = manifest.get("stacks", [])
    if len(stacks) != len(STACKS) or {stack.get("directory") for stack in stacks} != set(STACKS):
        raise OperationError("Invalid runtime paths in backup manifest")
    for stack in stacks:
        if not stack.get("services"):
            raise OperationError("No services in backup manifest")
        for name, service in stack["services"].items():
            if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_-]*", name):
                raise OperationError("Invalid service name in backup")
            if service.get("image") != local_image_ref(service.get("id", "")):
                raise OperationError("Image does not match recorded image ID")
            for volume in service.get("volumes", []):
                if volume.get("file") not in manifest.get("payloads", {}) or not re.fullmatch(r"volume-[0-9]+\.tar", volume["file"]):
                    raise OperationError("Missing named volume payload")
                target = volume.get("target", "")
                if not target.startswith("/") or ".." in PurePosixPath(target).parts or target == "/":
                    raise OperationError("Invalid container volume target")
            for mount in service.get("binds", []):
                source, target = mount.get("source", ""), mount.get("target", "")
                if not source or source.startswith("/") or ".." in PurePosixPath(source).parts or "\\" in source:
                    raise OperationError("Invalid project-relative bind mount")
                if not target.startswith("/") or ".." in PurePosixPath(target).parts or target == "/":
                    raise OperationError("Invalid bind mount target")


def healthcheck(project):
    script = project / "healthcheck.sh"
    if not script.is_file():
        raise OperationError("Missing healthcheck.sh; restoration cannot be verified")
    for attempt in range(6):
        result = subprocess.run(["bash", str(script)], env={**os.environ, "HEALTHCHECK_BRIEF": "1"}, stdout=sys.stderr)
        if result.returncode == 0:
            return
        if attempt < 5:
            time.sleep(5)
    raise OperationError("Readiness checks failed; operation did NOT succeed")


def install_shortcut(project):
    if os.name != "posix" or os.geteuid() != 0:
        log("Shortcut requires root; use bash " + str(project / "menu.sh"))
        return
    shortcut = Path("/usr/local/bin/xb")
    if shortcut.is_symlink() or (shortcut.exists() and (not shortcut.is_file() or str(project / "menu.sh") not in shortcut.read_text())):
        log("Existing unrelated xb shortcut preserved; use bash " + str(project / "menu.sh"))
        return
    atomic_text(shortcut, "#!/usr/bin/env bash\nexec bash " + shlex.quote(str(project / "menu.sh")) + ' "$@"\n', mode=0o755)


def stop_stacks(project, stacks):
    for stack in stacks:
        compose(project / stack["directory"], "down")


def start_stacks(project):
    for relative in reversed(STACKS):
        compose(project / relative, "up", "-d")


def restore(archive, destination, overwrite=False, allow_legacy=False):
    archive = Path(archive).resolve(strict=True)
    destination = safe_project(destination, exists=Path(destination).exists())
    if destination.exists() and not overwrite:
        raise OperationError("Destination exists; explicit --overwrite is required")
    # All archive validation and payload preparation precede service interruption.
    manifest = validate_archive(archive, allow_legacy)
    if manifest:
        validate_manifest(manifest)
    else:
        log("WARNING: legacy restore cannot recover the original images or Redis volumes")
    run(["docker", "info"], capture=True)
    old_stacks = inventory(destination) if destination.exists() else []
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tarfile.open(archive, "r:gz") as handle:
        unpacked_size = sum(member.size for member in handle.getmembers())
    if shutil.disk_usage(destination.parent).free < unpacked_size * 2 + 256 * 1024 * 1024:
        raise OperationError("Not enough free disk to stage restoration while retaining current data")
    previous = destination.with_name(destination.name + ".before-restore-" + time.strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:6])
    created_volumes, activated, stopped = [], False, False
    with tempfile.TemporaryDirectory(prefix=".xb-restore-", dir=destination.parent) as temporary:
        staging = Path(temporary)
        with tarfile.open(archive, "r:gz") as handle:
            validate_members(handle.getmembers())
            # Members were checked above, including link ancestors and special files.
            if sys.version_info >= (3, 12):
                handle.extractall(staging, filter="fully_trusted")
            else:
                handle.extractall(staging)
        restored = staging / "xboard-one-click"
        try:
            if manifest:
                run(["docker", "image", "load", "-i", restored / ".backup/images.tar"])
                mappings = {}
                for stack in manifest["stacks"]:
                    image_services, volume_services, definitions = {}, {}, {}
                    for service, data in stack["services"].items():
                        if docker_json("image", "inspect", data["image"])[0]["Id"] != data["id"]:
                            raise OperationError("Loaded image does not match backup manifest")
                        image_services[service] = {"image": data["image"], "pull_policy": "never"}
                        service_mounts = [{"type": "bind", "source": str(destination / mount["source"]), "target": mount["target"], "read_only": bool(mount.get("read_only"))} for mount in data.get("binds", [])]
                        for mount in data.get("volumes", []):
                            filename = mount["file"]
                            if filename not in mappings:
                                actual = "xboard-restore-" + uuid.uuid4().hex
                                run(["docker", "volume", "create", "--label", "com.xboard.one-click.project=" + str(destination), actual])
                                created_volumes.append(actual)
                                run(["docker", "run", "--rm", "--network", "none", "--user", "0", "--entrypoint", "tar",
                                     "--mount", "type=volume,src=" + actual + ",dst=/restore",
                                     "--mount", "type=bind,src=" + str(restored / ".backup") + ",dst=/backup,readonly",
                                     data["image"], "-C", "/restore", "-xf", "/backup/" + filename])
                                mappings[filename] = actual
                            key = "xb_restored_" + filename.replace("-", "_").replace(".", "_")
                            definitions[key] = {"external": True, "name": mappings[filename]}
                            service_mounts.append({"type": "volume", "source": key, "target": mount["target"], "read_only": bool(mount.get("read_only"))})
                        if service_mounts:
                            volume_services[service] = {"volumes": service_mounts}
                    directory = restored / stack["directory"]
                    write_json(directory / ".xb-images.json", {"services": image_services})
                    # Each restore gets fresh volumes; existing volumes remain recoverable.
                    write_json(directory / ".xb-volumes.json", {"services": volume_services, "volumes": definitions})
                    compose(directory, "config", "--quiet")
            else:
                for relative in STACKS:
                    compose(restored / relative, "config", "--quiet")
            os.chdir(destination.parent)
            stopped = True
            stop_stacks(destination, old_stacks)
            if destination.exists():
                destination.rename(previous)
            restored.rename(destination)
            activated = True
            start_stacks(destination)
            healthcheck(destination)
            install_shortcut(destination)
        except BaseException:
            if activated:
                failed = destination.with_name(destination.name + ".failed-restore-" + uuid.uuid4().hex[:8])
                try:
                    stop_stacks(destination, inventory(destination))
                    destination.rename(failed)
                    log("Failed restoration retained at: " + str(failed))
                except Exception as exc:
                    log("Unable to stop failed restoration; all directories retained: " + str(exc))
            if previous.exists() and not destination.exists():
                previous.rename(destination)
            if stopped and destination.exists():
                try:
                    start_stacks(destination)
                except Exception as exc:
                    log("Previous services need manual attention: " + str(exc))
            # Do not remove volumes after activation: they are part of retained recovery data.
            if not activated:
                for volume in created_volumes:
                    try:
                        run(["docker", "volume", "rm", volume])
                    except OperationError:
                        log("Unused staged volume retained: " + volume)
            raise
    if manifest:
        payload_directory = destination / ".backup"
        if not payload_directory.is_symlink() and payload_directory.resolve() == payload_directory.absolute():
            for filename in manifest["payloads"]:
                payload = payload_directory / filename
                if payload.is_file() and not payload.is_symlink():
                    try:
                        payload.unlink()
                    except OSError:
                        log("Staged payload could not be removed: " + str(payload))
    log("Restore verified. Previous data retained at: " + str(previous))
    return destination


def uninstall(project, mode, purge_backups=False, backup_dir=None):
    project = safe_project(project)
    backups = safe_backup_directory(backup_dir or str(project) + "-backups", project)
    if purge_backups and backups.exists() and backups != Path(str(project) + "-backups"):
        marker = backups / ".xboard-backup-owner"
        if not marker.is_file() or marker.read_text().strip() != str(project):
            raise OperationError("Custom backup directory ownership cannot be verified")
    runtime = project / "runtime"
    if runtime.is_symlink() or not inside(runtime, project):
        raise OperationError("Unsafe runtime directory")
    stacks = inventory(project)
    ids = {item["Id"] for stack in stacks for item in stack["services"].values()}
    volumes = set()
    for stack in stacks:
        for item in stack["services"].values():
            for mount in item.get("Mounts", []):
                if mount["Type"] != "volume":
                    continue
                name = mount["Name"]
                detail = docker_json("volume", "inspect", name)[0]
                labels = detail.get("Labels") or {}
                owned = labels.get("com.xboard.one-click.project") == str(project) or labels.get("com.docker.compose.project") == stack["name"]
                users = set(run(["docker", "ps", "-aq", "--no-trunc", "--filter", "volume=" + name], capture=True).split())
                if owned and not (users - ids):
                    volumes.add(name)
                else:
                    log("External/shared volume will be preserved: " + name)
    log("Containers selected by exact Compose working-directory ownership: " + ", ".join(sorted(ids)))
    log("Data path: " + str(runtime))
    if mode != "stop":
        log("Owned volumes selected: " + ", ".join(sorted(volumes)))
    if purge_backups:
        log("Backup deletion selected: " + str(backups))
    stop_stacks(project, stacks)
    if mode == "stop":
        return
    for volume in volumes:
        run(["docker", "volume", "rm", volume])
    if runtime.exists():
        shutil.rmtree(runtime)
    if mode == "all":
        shortcut = Path("/usr/local/bin/xb")
        if shortcut.is_file() and not shortcut.is_symlink() and str(project / "menu.sh") in shortcut.read_text():
            shortcut.unlink()
        if purge_backups and backups.exists():
            shutil.rmtree(backups)
        os.chdir(project.parent)
        shutil.rmtree(project)
    log("Requested data removed permanently. Unselected backups and previous restore directories were retained")


def select_backup(project):
    base = Path(str(Path(project).resolve()) + "-backups")
    choices = sorted(base.rglob("*.tar.gz"), key=lambda path: path.stat().st_mtime, reverse=True) if base.is_dir() else []
    for number, path in enumerate(choices, 1):
        log("{}. {}  {:.1f} MiB  {}".format(number, time.strftime("%Y-%m-%d %H:%M", time.localtime(path.stat().st_mtime)), path.stat().st_size / (1024 * 1024), path))
    print("请输入备份编号或完整路径: ", end="", file=sys.stderr, flush=True)
    choice = sys.stdin.readline().strip()
    if not choice:
        raise OperationError("No backup selected")
    if choice.isdigit() and 1 <= int(choice) <= len(choices):
        return choices[int(choice) - 1].resolve()
    path = Path(choice).expanduser()
    if not path.is_file():
        matches = [item for item in choices if item.name == choice]
        if len(matches) == 1:
            return matches[0].resolve()
        raise OperationError("Backup not found; use the numbered list or an absolute path")
    return path.resolve()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    for name in ("install-state", "sqlite-check", "pin-images", "unpin-images", "check-running", "inventory", "validate-project", "select-backup", "normalize-existing-env", "save-credentials"):
        commands.add_parser(name).add_argument("path")
    item = commands.add_parser("check-counts")
    item.add_argument("baseline")
    item.add_argument("database")
    item = commands.add_parser("env-get")
    item.add_argument("path")
    item.add_argument("key")
    item = commands.add_parser("env-set")
    item.add_argument("path")
    item.add_argument("key")
    item.add_argument("value")
    item = commands.add_parser("save-env-from-process")
    item.add_argument("path")
    item.add_argument("keys", nargs="+")
    item = commands.add_parser("set-xboard-port")
    item.add_argument("path")
    item.add_argument("port")
    item = commands.add_parser("set-npm-ports")
    item.add_argument("path")
    item.add_argument("http")
    item.add_argument("https")
    item.add_argument("admin")
    item.add_argument("extra")
    item = commands.add_parser("backup")
    item.add_argument("project")
    item.add_argument("backup_dir")
    item.add_argument("--output")
    item.add_argument("--keep-stopped", action="store_true")
    item = commands.add_parser("restore")
    item.add_argument("archive")
    item.add_argument("destination")
    item.add_argument("--overwrite", action="store_true")
    item.add_argument("--allow-legacy", action="store_true")
    item = commands.add_parser("uninstall")
    item.add_argument("project")
    item.add_argument("mode", choices=("stop", "data", "all"))
    item.add_argument("--purge-backups", action="store_true")
    item.add_argument("--backup-dir")
    args = parser.parse_args(argv)
    os.umask(0o077)
    if args.command == "install-state":
        print(install_state(args.path))
    elif args.command == "sqlite-check":
        print(json.dumps(sqlite_report(args.path)))
    elif args.command == "env-get":
        print(read_env(args.path).get(args.key, ""))
    elif args.command == "env-set":
        set_env(args.path, {args.key: args.value})
    elif args.command == "save-env-from-process":
        set_env(args.path, {key: os.environ[key] for key in args.keys})
    elif args.command == "set-xboard-port":
        set_xboard_port(args.path, args.port)
    elif args.command == "set-npm-ports":
        set_npm_ports(args.path, args.http, args.https, args.admin, args.extra)
    elif args.command == "pin-images":
        pin_images(safe_project(args.path))
    elif args.command == "unpin-images":
        unpin_images(safe_project(args.path))
    elif args.command == "check-running":
        check_running(safe_project(args.path))
    elif args.command == "normalize-existing-env":
        normalize_existing_env(args.path)
    elif args.command == "save-credentials":
        credentials = {key: os.environ[key] for key in ("XBOARD_ADMIN_EMAIL", "XBOARD_ADMIN_PASSWORD")}
        if not credentials["XBOARD_ADMIN_EMAIL"] or len(credentials["XBOARD_ADMIN_PASSWORD"]) < 12:
            raise OperationError("Invalid credentials")
        set_env(args.path, credentials)
    elif args.command == "check-counts":
        check_counts(args.baseline, args.database)
    elif args.command == "inventory":
        inventory(safe_project(args.path))
    elif args.command == "validate-project":
        safe_project(args.path)
    elif args.command == "select-backup":
        print(select_backup(args.path))
    elif args.command == "backup":
        print(backup(args.project, args.backup_dir, args.output, args.keep_stopped))
    elif args.command == "restore":
        print(restore(args.archive, args.destination, args.overwrite, args.allow_legacy))
    elif args.command == "uninstall":
        uninstall(args.project, args.mode, args.purge_backups, args.backup_dir)


if __name__ == "__main__":
    def interrupted(signum, frame):
        raise OperationError("Interrupted by signal " + str(signum))
    signal.signal(signal.SIGTERM, interrupted)
    try:
        main()
    except (OperationError, OSError, ValueError) as error:
        log("FAILED: " + str(error))
        sys.exit(1)
