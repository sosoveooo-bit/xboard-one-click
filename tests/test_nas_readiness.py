import json
import subprocess
from types import SimpleNamespace
from unittest.mock import patch

from test_operations import WorkspaceCase, ops, IMAGE_ID, IMAGE_REF


class RedisReadinessTests(WorkspaceCase):
    def simulate(self, ready_at=None, state="running", hang=False, seconds=600):
        clock = [0.0]
        calls = []

        def advance(value):
            clock[0] += value

        def command(args, **kwargs):
            calls.append(args)
            self.assertLessEqual(kwargs["timeout"], 5)
            if args[-1] == "ping":
                if hang:
                    advance(kwargs["timeout"])
                    raise subprocess.TimeoutExpired(args, kwargs["timeout"])
                if ready_at is not None and clock[0] >= ready_at:
                    return SimpleNamespace(returncode=0, stdout="PONG\n", stderr="")
                return SimpleNamespace(returncode=1, stdout="", stderr="No such file or directory")
            if "ps" in args:
                return SimpleNamespace(returncode=0, stdout="fixture-container\n", stderr="")
            if "inspect" in args:
                return SimpleNamespace(returncode=0, stdout=state + "\n", stderr="")
            self.fail("Unexpected command: " + repr(args))

        with patch.object(ops.time, "monotonic", side_effect=lambda: clock[0]), \
                patch.object(ops.time, "sleep", side_effect=advance), \
                patch.object(ops.subprocess, "run", side_effect=command), patch.object(ops, "log"):
            if ready_at is None:
                with self.assertRaises(ops.OperationError):
                    ops.wait_redis(self.xboard, seconds)
            else:
                ops.wait_redis(self.xboard, seconds)
        return clock[0], calls

    def test_98_second_nas_startup_no_longer_times_out(self):
        elapsed, calls = self.simulate(ready_at=98)
        self.assertEqual(elapsed, 98)
        self.assertTrue(any("inspect" in args for args in calls))

    def test_ready_redis_returns_without_sleeping(self):
        elapsed, _ = self.simulate(ready_at=0)
        self.assertEqual(elapsed, 0)

    def test_missing_redis_stops_at_the_configured_deadline(self):
        elapsed, _ = self.simulate(seconds=101)
        self.assertEqual(elapsed, 101)

    def test_hung_docker_probe_cannot_extend_the_deadline(self):
        elapsed, _ = self.simulate(seconds=17, hang=True)
        self.assertEqual(elapsed, 17)

    def test_exited_container_fails_without_waiting_ten_minutes(self):
        elapsed, _ = self.simulate(state="exited")
        self.assertEqual(elapsed, 0)

    def test_invalid_wait_limits_fail_before_contacting_docker(self):
        for value in (0, -1, 3601):
            with self.subTest(value=value), patch.object(ops.subprocess, "run") as command:
                with self.assertRaises(ops.OperationError):
                    ops.wait_redis(self.xboard, value)
                command.assert_not_called()


class CandidateImageTests(WorkspaceCase):
    def test_unchanged_env_keeps_its_bind_mount_inode(self):
        self.assertTrue(ops.normalize_existing_env(self.xboard))
        path = self.xboard / ".env"
        before = path.stat().st_ino
        content = path.read_bytes()
        self.assertFalse(ops.normalize_existing_env(self.xboard))
        self.assertEqual(before, path.stat().st_ino)
        self.assertEqual(content, path.read_bytes())

    def setup_locks(self):
        for relative in ops.STACKS:
            ops.write_json(self.project / relative / ".xb-images.json", {"services": {"app": {"image": IMAGE_REF, "pull_policy": "never"}}})

    def test_unchanged_candidate_keeps_identical_lock_content(self):
        self.setup_locks()
        original = [(self.project / relative / ".xb-images.json").read_bytes() for relative in ops.STACKS]

        def command(args, **kwargs):
            if args[:2] == ["docker", "compose"]:
                self.assertNotIn(".xb-images.json", args)
            if "config" in args:
                return json.dumps({"services": {"app": {"image": "fixture:latest"}}})
            return ""

        with patch.object(ops, "inventory", return_value=self.stacks()), patch.object(ops, "run", side_effect=command), \
                patch.object(ops, "docker_json", return_value=[{"Id": IMAGE_ID}]):
            ops.pull_candidate_images(self.project)
        self.assertEqual(original, [(self.project / relative / ".xb-images.json").read_bytes() for relative in ops.STACKS])

    def test_second_pull_failure_preserves_both_previous_locks(self):
        self.setup_locks()
        original = [(self.project / relative / ".xb-images.json").read_bytes() for relative in ops.STACKS]
        pulls = [0]

        def command(args, **kwargs):
            if "config" in args:
                return json.dumps({"services": {"app": {"image": "fixture:latest"}}})
            if args[-1] == "pull":
                pulls[0] += 1
                if pulls[0] == 2:
                    raise ops.OperationError("Pull failed")
            return ""

        with patch.object(ops, "inventory", return_value=self.stacks()), patch.object(ops, "run", side_effect=command), \
                patch.object(ops, "docker_json", return_value=[{"Id": "sha256:" + "b" * 64}]):
            with self.assertRaises(ops.OperationError):
                ops.pull_candidate_images(self.project)
        self.assertEqual(original, [(self.project / relative / ".xb-images.json").read_bytes() for relative in ops.STACKS])
